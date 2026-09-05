# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module OpenGeographies
  # See lib/tasks/open_geographies_tasks.rake.
  class TenancyProbe
    Tenant = Struct.new(:key, :user, :project, :site, :collection, :job, :place, :token, keyword_init: true)

    # Creates and removes the two tenants' rows. Everything is namespaced
    # "og-tenancy-probe" so a crashed run can be cleaned up by hand.
    class Fixtures
      attr_reader :a, :b

      def self.build!(password:)
        new.tap { |fixtures| fixtures.build!(password:) }
      end

      def build!(password:)
        @a = build_tenant('a', password:, discoverable: true)
        @b = build_tenant('b', password:, discoverable: false)
      end

      def teardown!
        [a, b].compact.each do |tenant|
          tenant.job&.destroy
          tenant.site&.destroy
          tenant.collection&.destroy
          tenant.project&.destroy
          tenant.user&.destroy
        end
      end

      private

      def build_tenant(key, password:, discoverable:)
        email = "og-tenancy-probe-#{key}@example.test"

        # Leftovers from a KEEP=1 or crashed run.
        ::CoreDataConnector::Site.where(slug: ["og-tenancy-probe-#{key}", 'og-tenancy-probe-bare', 'og-tenancy-probe-foreign', 'og-tenancy-probe-borrowed']).destroy_all
        ::CoreDataConnector::SearchCollection.where(name: "og_tenancy_probe_#{key}").destroy_all
        ::CoreDataConnector::Project.where(name: "OG Tenancy Probe #{key.upcase}").destroy_all
        ::CoreDataConnector::User.where(email:).destroy_all

        # skip_invitation + last_sign_in_at: both the User and UserProject
        # after-create invitations regenerate the password (and email it),
        # which would lock the probe out of its own users. A user who has
        # signed in before is never re-invited.
        user = ::CoreDataConnector::User.create!(
          name: "Tenancy Probe #{key.upcase}", email:, password:, password_confirmation: password,
          role: ::CoreDataConnector::User::ROLE_MEMBER, require_password_change: false,
          skip_invitation: true, last_sign_in_at: Time.now.utc
        )

        project = ::CoreDataConnector::Project.create!(name: "OG Tenancy Probe #{key.upcase}", discoverable:)
        ::CoreDataConnector::UserProject.create!(project:, user:, role: ::CoreDataConnector::UserProject::ROLE_OWNER)

        model = ::CoreDataConnector::ProjectModel.create!(project:, name: 'Places', model_class: 'CoreDataConnector::Place', order: 0)
        place = ::CoreDataConnector::Place.create!(project_model: model, place_names_attributes: [{ name: "Probe Place #{key.upcase}", primary: true }])

        collection = ::CoreDataConnector::SearchCollection.create!(
          project:, name: "og_tenancy_probe_#{key}", project_model_ids: [model.id], auto_index: false, polygons: false
        )

        site = ::CoreDataConnector::Site.create!(
          project:, name: "OG Tenancy Probe #{key.upcase}", slug: "og-tenancy-probe-#{key}",
          config: { 'search' => [{ 'name' => 'places', 'route' => '/places', 'search_collection_id' => collection.id }] }
        )

        job = ::CoreDataConnector::Job.create!(project_id: project.id, user_id: user.id, job_type: ::CoreDataConnector::Job::JOB_TYPE_REINDEX, extra: { probe: true })

        Tenant.new(key:, user:, project:, site:, collection:, job:, place:)
      end
    end

    attr_reader :checks, :failures

    def initialize(host:, fixtures:, password:)
      @host = host
      @fixtures = fixtures
      @password = password
      @checks = 0
      @failures = []
    end

    def run!
      a = @fixtures.a
      b = @fixtures.b

      a.token = login(a.user.email)
      b.token = login(b.user.email)

      group 'public atlas-by-slug' do
        res = get("/core_data/public/v1/atlases/#{a.site.slug}")
        status 'discoverable atlas resolves', res, '200'
        check 'and carries only its own project id', body(res).dig('atlas', 'config', 'core_data', 'project_ids') == [a.project.id.to_s]
        status 'non-discoverable atlas is 404', get("/core_data/public/v1/atlases/#{b.site.slug}"), '404'
        status 'unknown slug is 404', get('/core_data/public/v1/atlases/no-such-atlas'), '404'
        status 'slug lookup ignores a smuggled id', get("/core_data/public/v1/atlases/#{b.site.id}"), '404'
      end

      group 'anonymous is refused everywhere' do
        status 'sites index', get('/core_data/sites'), '401'
        status 'site config', get("/core_data/sites/#{a.site.id}/config"), '401'
        status 'job', get("/core_data/jobs/#{a.job.id}"), '401'
        status 'search collections', get('/core_data/search_collections'), '401'
        status 'import preview', post("/core_data/projects/#{a.project.id}/place_imports/preview", { place_import: {} }), '401'
        status 'admin_children', get('/core_data/place_imports/admin_children?geoname_id=6295630'), '401'
        status 'atlas create', post('/core_data/atlases', { atlas: { name: 'x' } }), '401'
        status 'wizard page itself is public html', request(Net::HTTP::Get, '/wizard', nil, nil, accept: 'text/html'), '200'
      end

      group "tenant B cannot read tenant A" do
        refused 'site config', get("/core_data/sites/#{a.site.id}/config", b.token)
        refused 'site record', get("/core_data/sites/#{a.site.id}", b.token)
        refused 'job', get("/core_data/jobs/#{a.job.id}", b.token)
        refused 'search collection', get("/core_data/search_collections/#{a.collection.id}", b.token)

        sites = body(get('/core_data/sites', b.token))['sites'] || []
        check 'sites index is scoped', sites.map { |s| s['id'] } == [b.site.id]

        collections = body(get('/core_data/search_collections', b.token))['search_collections'] || []
        check 'search collections index is scoped', collections.map { |c| c['id'] } == [b.collection.id]

        jobs = body(get('/core_data/jobs', b.token))['jobs'] || []
        check 'jobs index is scoped', jobs.map { |j| j['project_id'] }.uniq == [b.project.id]
      end

      group "tenant B cannot write to or run jobs against tenant A" do
        refused 'update site', patch("/core_data/sites/#{a.site.id}", { site: { name: 'pwned' } }, b.token)
        refused 'delete site', delete("/core_data/sites/#{a.site.id}", b.token)
        refused 'reindex collection', post("/core_data/search_collections/#{a.collection.id}/reindex", {}, b.token)
        refused 'build tiles', post("/core_data/sites/#{a.site.id}/build_tiles", {}, b.token)
        refused 'import preview', post("/core_data/projects/#{a.project.id}/place_imports/preview", { place_import: { source: 'geonames', area: {}, filters: {} } }, b.token)
        refused 'import', post("/core_data/projects/#{a.project.id}/place_imports", { place_import: { source: 'geonames', area: {}, filters: {} } }, b.token)
        refused 'admin_children scoped to project', get("/core_data/projects/#{a.project.id}/place_imports/admin_children?geoname_id=6295630", b.token)
      end

      group 'cross-tenant references are rejected' do
        res = post('/core_data/sites', { site: { project_id: b.project.id, name: 'Foreign', slug: 'og-tenancy-probe-foreign' } }, a.token)
        refused 'A cannot create a site on B\'s project', res

        res = post('/core_data/sites', { site: { project_id: a.project.id, name: 'Borrowed', slug: 'og-tenancy-probe-borrowed',
                                                  config: { search: [{ name: 'places', search_collection_id: b.collection.id }] } } }, a.token)
        status 'A\'s site cannot reference B\'s search collection', res, %w[400 422]
        ::CoreDataConnector::Site.where(slug: %w[og-tenancy-probe-foreign og-tenancy-probe-borrowed]).destroy_all

        res = patch("/core_data/sites/#{a.site.id}", { site: { project_id: b.project.id } }, a.token)
        a.site.reload
        # project_id is dropped from update bodies (attr_readonly), so the request
        # succeeds as a no-op; what matters is that the row didn't move.
        check 'A cannot move its site onto B\'s project', a.site.project_id == a.project.id, "project_id now #{a.site.project_id} (#{res.code})"

        # The same with a site whose config references nothing, so config
        # validation can't be what stops it.
        bare = ::CoreDataConnector::Site.create!(project: a.project, name: 'OG Tenancy Probe Bare', slug: 'og-tenancy-probe-bare', config: {})
        res = patch("/core_data/sites/#{bare.id}", { site: { project_id: b.project.id } }, a.token)
        bare.reload
        check 'nor a config-less site', bare.project_id == a.project.id, "project_id now #{bare.project_id} (#{res.code})"
        bare.destroy

        res = patch("/core_data/search_collections/#{a.collection.id}", { search_collection: { project_id: b.project.id } }, a.token)
        a.collection.reload
        check 'A cannot move its search collection onto B\'s project', a.collection.project_id == a.project.id, "project_id now #{a.collection.project_id} (#{res.code})"

        res = post('/core_data/search_collections', { search_collection: { project_id: a.project.id, name: 'og_tenancy_probe_x', project_model_ids: [b.place.project_model_id] } }, a.token)
        status 'A\'s collection cannot include B\'s model', res, %w[400 422]
        ::CoreDataConnector::SearchCollection.where(name: 'og_tenancy_probe_x').destroy_all
      end

      group 'tenant A can still do its own work' do
        res = get("/core_data/sites/#{a.site.id}/config", a.token)
        status 'own site config', res, '200'
        check 'own config names only own project', body(res).dig('core_data', 'project_ids') == [a.project.id.to_s], res.body.to_s[0, 200]
        status 'own job', get("/core_data/jobs/#{a.job.id}", a.token), '200'
        status 'own site update', patch("/core_data/sites/#{a.site.id}", { site: { name: 'OG Tenancy Probe A (renamed)' } }, a.token), '200'
      end
    end

    private

    def group(title)
      puts "\n#{title}"
      before = @failures.size
      yield
      abort_group if @failures.size > before && ENV['FAIL_FAST'] == '1'
    end

    def abort_group
      raise 'aborting on first failing group'
    end

    def check(label, ok, detail = nil)
      @checks += 1
      puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}#{detail && !ok ? " (#{detail})" : ''}"
      @failures << label unless ok
    end

    # A refused request. The host answers a policy denial with 401 (its
    # resource controller's convention, kept for consistency with the rest of
    # FairData), or 404 when the policy scope hides the record entirely. Both
    # keep the tenant boundary; 404 additionally avoids confirming the record
    # exists. A 422 or 500 is not a refusal — it means the request got past
    # authorization into the action.
    REFUSED = %w[401 403 404].freeze

    def refused(label, res)
      check(label, REFUSED.include?(res.code), "got #{res.code}: #{res.body.to_s[0, 120]}")
    end

    def status(label, res, expected)
      check(label, Array(expected).include?(res.code), "got #{res.code}: #{res.body.to_s[0, 160]}")
    end

    def login(email)
      res = post('/auth/login', { email:, password: @password })
      raise "login failed for #{email}: #{res.code} #{res.body[0, 200]}" unless res.code == '200'

      JSON.parse(res.body)['token']
    end

    def body(res)
      JSON.parse(res.body)
    rescue JSON::ParserError
      {}
    end

    def get(path, token = nil) = request(Net::HTTP::Get, path, nil, token)
    def post(path, payload, token = nil) = request(Net::HTTP::Post, path, payload, token)
    def patch(path, payload, token = nil) = request(Net::HTTP::Patch, path, payload, token)
    def delete(path, token = nil) = request(Net::HTTP::Delete, path, nil, token)

    def request(klass, path, payload, token, accept: 'application/json')
      uri = URI.join(@host, path)
      req = klass.new(uri)
      req['Accept'] = accept
      req['Authorization'] = token if token

      if payload
        req['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
    end
  end
end
