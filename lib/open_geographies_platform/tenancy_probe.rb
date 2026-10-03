# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'json'
require 'securerandom'
require 'stringio'
require 'uri'

module OpenGeographiesPlatform
  # See lib/tasks/open_geographies_tasks.rake.
  class TenancyProbe
    Tenant = Struct.new(:key, :user, :project, :site, :collection, :job, :place, :asset_key, :job_file_key, :token, keyword_init: true)

    # A 1x1 PNG: the uploaded-image fixture.
    PNG = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')

    # Creates and removes the two tenants' rows. Everything is namespaced
    # "og-tenancy-probe" so a crashed run can be cleaned up by hand.
    class Fixtures
      attr_reader :a, :b, :editor

      EDITOR_EMAIL = 'og-tenancy-probe-e@example.test'
      ADMIN_EMAIL = 'og-tenancy-probe-admin@example.test'

      def self.build!(password:)
        new.tap { |fixtures| fixtures.build!(password:) }
      end

      def build!(password:)
        remove_editor
        @a = build_tenant('a', password:, discoverable: true)
        @b = build_tenant('b', password:, discoverable: false)
        @editor = build_editor(@a, password:)
      end

      def teardown!
        remove_editor
        remove_admin
        remove_feedback([a&.user&.id, b&.user&.id])
        [a, b].compact.each do |tenant|
          tenant.job&.destroy
          tenant.site&.destroy
          tenant.collection&.destroy
          tenant.project&.destroy
          tenant.user&.destroy
        end
      end

      private

      # A curator invited to A's project as an editor (FairData's project
      # role; an invited account is a "guest").
      def build_editor(tenant, password:)
        user = ::CoreDataConnector::User.create!(
          name: 'Tenancy Probe Editor', email: EDITOR_EMAIL, password:, password_confirmation: password,
          role: ::CoreDataConnector::User::ROLE_GUEST, require_password_change: false,
          skip_invitation: true, last_sign_in_at: Time.now.utc
        )
        ::CoreDataConnector::UserProject.create!(project: tenant.project, user:, role: ::CoreDataConnector::UserProject::ROLE_EDITOR)

        user
      end

      # An administrator of the platform, made only for the feedback checks
      # (admins read every report) and removed with the fixtures.
      def build_admin(password:)
        remove_admin
        ::CoreDataConnector::User.create!(
          name: 'Tenancy Probe Admin', email: ADMIN_EMAIL, password:, password_confirmation: password,
          role: ::CoreDataConnector::User::ROLE_ADMIN, require_password_change: false,
          skip_invitation: true, last_sign_in_at: Time.now.utc
        )
      end

      def remove_admin
        ::CoreDataConnector::User.where(email: ADMIN_EMAIL).find_each do |user|
          remove_feedback([user.id])
          user.destroy
        end
      end

      # Reports the probe's users sent, with their screenshots.
      def remove_feedback(user_ids)
        ::CoreDataConnector::FeedbackReport.where(user_id: user_ids.compact).find_each do |report|
          report.screenshot.purge if report.screenshot.attached?
          report.destroy
        end
      end

      def remove_editor
        ::CoreDataConnector::User.where(email: EDITOR_EMAIL).find_each do |user|
          remove_feedback([user.id])
          ::CoreDataConnector::Job.where(user_id: user.id).delete_all
          ::CoreDataConnector::UserProject.where(user_id: user.id).delete_all
          user.destroy
        end
      end

      def build_tenant(key, password:, discoverable:)
        email = "og-tenancy-probe-#{key}@example.test"
        remove_feedback(::CoreDataConnector::User.where(email:).pluck(:id))

        # Leftovers from a KEEP=1 or crashed run.
        ::CoreDataConnector::Site.where(slug: ["og-tenancy-probe-#{key}", 'og-tenancy-probe-bare', 'og-tenancy-probe-foreign', 'og-tenancy-probe-borrowed', 'og-tenancy-probe-doomed']).destroy_all
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
          project:, name: "OG Tenancy Probe #{key.upcase}", slug: "og-tenancy-probe-#{key}", published: true,
          config: { 'search' => [{ 'name' => 'places', 'route' => '/places', 'search_collection_id' => collection.id }] }
        )

        job = ::CoreDataConnector::Job.create!(project_id: project.id, user_id: user.id, job_type: ::CoreDataConnector::Job::JOB_TYPE_REINDEX, extra: { probe: true })

        # An uploaded image on the site, and a file on the job (what a dataset
        # upload or an export leaves behind): the public asset route must
        # serve the first and never the second.
        site.assets.attach(io: StringIO.new(PNG), filename: 'probe.png', content_type: 'image/png')
        job.file.attach(io: StringIO.new("name\nProbe\n"), filename: 'probe.csv', content_type: 'text/csv')

        Tenant.new(key:, user:, project:, site:, collection:, job:, place:,
                   asset_key: site.assets_attachments.last.blob.key, job_file_key: job.file.blob.key)
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
        check 'and carries its home page', body(res).dig('atlas', 'content', 'home', 'sections').is_a?(Array)
        check 'but never its preview token', !res.body.to_s.include?(a.site.preview_token.to_s)
      end

      group 'a draft atlas is private' do
        a.site.update!(published: false)
        path = "/core_data/public/v1/atlases/#{a.site.slug}"
        status 'unpublished atlas is 404', get(path), '404'
        status 'with a wrong preview token too', get(path, nil, preview: 'x' * 32), '404'
        status 'with another atlas\'s token too', get(path, nil, preview: b.site.preview_token), '404'
        res = get(path, nil, preview: a.site.preview_token)
        status 'its preview token shows it', res, '200'
        check 'marked as a preview, not to be cached', body(res).dig('atlas', 'preview') == true && res['Cache-Control'].to_s.include?('no-store'),
              "#{body(res).dig('atlas', 'preview').inspect} #{res['Cache-Control']}"

        status 'anonymous can\'t make a new preview link', post("/core_data/sites/#{a.site.id}/preview_token", {}), '401'
        status 'nor another tenant', post("/core_data/sites/#{a.site.id}/preview_token", {}, b.token), %w[401 404]
        old_token = a.site.preview_token
        res = post("/core_data/sites/#{a.site.id}/preview_token", {}, a.token)
        status 'the owner can', res, '200'
        status 'and the old link stops working', get(path, nil, preview: old_token), '404'
        a.site.reload

        status 'publishing it', patch("/core_data/sites/#{a.site.id}", { site: { published: true } }, a.token), '200'
        status 'makes it public', get(path), '200'
      ensure
        a.site.update!(published: true) unless a.site.reload.published
      end

      group 'an atlas\'s own domain' do
        own_domain(a, b)
      end

      group 'uploaded images' do
        res = get("/core_data/public/v1/assets/#{a.asset_key}/probe.png")
        status 'a site image is public', res, '200'
        check 'as its image type', res['Content-Type'] == 'image/png', res['Content-Type']
        check 'sandboxed and not sniffable', res['Content-Security-Policy'].to_s.include?('sandbox') && res['X-Content-Type-Options'] == 'nosniff'
        status 'a job\'s file is not served', get("/core_data/public/v1/assets/#{a.job_file_key}/probe.csv"), '404'
        status 'unknown key is 404', get('/core_data/public/v1/assets/nosuchkey/probe.png'), '404'
      end

      group 'anonymous is refused everywhere' do
        status 'sites index', get('/core_data/sites'), '401'
        status 'site config', get("/core_data/sites/#{a.site.id}/config"), '401'
        status 'job', get("/core_data/jobs/#{a.job.id}"), '401'
        status 'search collections', get('/core_data/search_collections'), '401'
        status 'import preview', post("/core_data/projects/#{a.project.id}/place_imports/preview", { place_import: {} }), '401'
        status 'admin_children', get('/core_data/place_imports/admin_children?geoname_id=6295630'), '401'
        status 'atlas create', post('/core_data/atlases', { atlas: { name: 'x' } }), '401'
        status 'dataset preview', post("/core_data/projects/#{a.project.id}/dataset_imports/preview", {}), '401'
        status 'dataset import', post("/core_data/projects/#{a.project.id}/dataset_imports", { dataset_import: { columns: [] } }), '401'
        status 'address lookup', post("/core_data/projects/#{a.project.id}/dataset_imports/geocode", { geocode: { street: 'Address' } }), '401'
        status 'site images', get("/core_data/sites/#{a.site.id}/assets"), '401'
        status 'search fields', get("/core_data/sites/#{a.site.id}/search_fields"), '401'
        status 'image upload', upload("/core_data/sites/#{a.site.id}/assets", 'x.png', PNG), '401'
        status 'image delete', delete("/core_data/sites/#{a.site.id}/assets/#{a.asset_key}"), '401'
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
        refused 'dataset preview into A', post("/core_data/projects/#{a.project.id}/dataset_imports/preview", {}, b.token)
        refused 'dataset import into A', post("/core_data/projects/#{a.project.id}/dataset_imports", { dataset_import: { columns: [] } }, b.token)
        refused 'address lookup in A', post("/core_data/projects/#{a.project.id}/dataset_imports/geocode", { geocode: { street: 'Address' } }, b.token)
        refused 'list A\'s images', get("/core_data/sites/#{a.site.id}/assets", b.token)
        refused 'A\'s search fields', get("/core_data/sites/#{a.site.id}/search_fields", b.token)
        refused 'upload an image to A', upload("/core_data/sites/#{a.site.id}/assets", 'x.png', PNG, b.token)
        refused 'delete A\'s image', delete("/core_data/sites/#{a.site.id}/assets/#{a.asset_key}", b.token)
        refused 'delete A\'s image through B\'s own site', delete("/core_data/sites/#{b.site.id}/assets/#{a.asset_key}", b.token)
        check 'A\'s image is still there', a.site.assets_attachments.joins(:blob).exists?(active_storage_blobs: { key: a.asset_key })
        refused 'edit A\'s pages', patch("/core_data/sites/#{a.site.id}", { site: { content: { pages: [{ slug: 'pwned', title: 'Pwned' }] } } }, b.token)
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

        projects = ::CoreDataConnector::Project.count
        res = post('/core_data/atlases', { atlas: { name: 'OG Tenancy Probe, B' } }, a.token)
        status 'an atlas name already in use is refused', res, '422'
        check '... as a name problem, with nothing created', body(res).dig('errors', 0, 'name', 0).to_s.include?('already uses this name') && ::CoreDataConnector::Project.count == projects, res.body.to_s[0, 200]

        res = patch("/core_data/sites/#{a.site.id}", { site: { content: { pages: [{ slug: 'about', title: 'About', sections: [{ type: 'text', body: 'Hello' }] }] } } }, a.token)
        status 'own pages saved', res, '200'
        res = patch("/core_data/sites/#{a.site.id}", { site: { content: { pages: [{ slug: 'about', title: 'About', sections: [{ type: 'call_to_action', button_url: 'javascript:alert(1)' }] }] } } }, a.token)
        status 'but not a javascript: link', res, %w[400 422]
        res = patch("/core_data/sites/#{a.site.id}", { site: { branding: { primary_color: '#000;}</style><script>' } } }, a.token)
        status 'nor a color that isn\'t one', res, %w[400 422]
        res = patch("/core_data/sites/#{a.site.id}", { site: { branding: { footer: { copyright: 'x' * 301 } } } }, a.token)
        status 'nor a 301-character copyright line', res, %w[400 422]

        doomed = ::CoreDataConnector::Site.create!(project: a.project, name: 'OG Tenancy Probe doomed', slug: 'og-tenancy-probe-doomed', published: true)
        doomed.assets.attach(io: StringIO.new(PNG), filename: 'doomed.png', content_type: 'image/png')
        refused 'another tenant can\'t delete an atlas', delete("/core_data/sites/#{doomed.id}", b.token)
        status 'anonymous can\'t either', delete("/core_data/sites/#{doomed.id}"), '401'
        status 'the owner can', delete("/core_data/sites/#{doomed.id}", a.token), '200'
        check 'and the atlas is gone, its project and records kept', !::CoreDataConnector::Site.exists?(doomed.id) &&
                                                                    ::CoreDataConnector::Project.exists?(a.project.id) && ::CoreDataConnector::Place.exists?(a.place.id)
        status 'its public address answers 404', get('/core_data/public/v1/atlases/og-tenancy-probe-doomed'), '404'

        res = upload("/core_data/sites/#{a.site.id}/assets", 'own.png', PNG, a.token)
        status 'own image upload', res, '200'
        own_key = body(res).dig('asset', 'key')
        status 'an HTML file named .png is refused', upload("/core_data/sites/#{a.site.id}/assets", 'page.png', '<html><script>alert(1)</script></html>', a.token), '422'
        status 'own image delete', delete("/core_data/sites/#{a.site.id}/assets/#{own_key}", a.token), '204'
      end

      group 'an atlas in more than one language' do
        languages(a)
      end

      group 'an editor edits the content; owners manage the atlas' do
        editor(a, b)
      end

      group 'placing places without a location' do
        unplaced = ::CoreDataConnector::Place.create!(project_model_id: a.place.project_model_id, place_names_attributes: [{ name: 'Probe Unplaced', primary: true }])
        list = "/core_data/sites/#{a.site.id}/unlocated_places"
        locate = "#{list}/locate"
        point = { locations: [{ place_id: unplaced.id, latitude: 33.75, longitude: -84.39 }] }

        status 'anonymous can\'t list them', get(list), '401'
        status 'nor look them up', post("#{list}/lookup", { place_ids: [unplaced.id] }), '401'
        status 'nor place them', post(locate, point), '401'
        status 'another tenant can\'t list them', get(list, b.token), %w[401 404]
        status 'nor place them', post(locate, point, b.token), %w[401 404]
        res = post("/core_data/sites/#{b.site.id}/unlocated_places/locate", point, b.token)
        check 'nor through its own atlas', body(res)['located'].to_i.zero? && unplaced.reload.place_geometry.nil?, res.body.to_s[0, 120]

        res = get(list, a.token)
        status 'the owner lists them', res, '200'
        check '... including the new one', Array(body(res)['places']).any? { |p| p['id'] == unplaced.id }
        status 'coordinates must be coordinates', post(locate, { locations: [{ place_id: unplaced.id, latitude: 95, longitude: 0 }] }, a.token), '422'
        res = post(locate, point, a.token)
        check 'the owner places it', body(res)['located'] == 1 && unplaced.reload.place_geometry.present?, res.body.to_s[0, 120]
        res = post(locate, { locations: [{ place_id: unplaced.id, latitude: 1, longitude: 1 }] }, a.token)
        check 'a placed place isn\'t moved here', body(res)['located'].to_i.zero?, res.body.to_s[0, 120]
      ensure
        unplaced&.destroy
      end

      group 'renaming category values' do
        model = ::CoreDataConnector::ProjectModel.find(a.place.project_model_id)
        types = ::CoreDataConnector::Atlases::Template.ensure_relationship!(model, 'Types', template_model: 'Places')
        house = ::CoreDataConnector::Taxonomy.create!(project_model: types.related_model, name: 'house')
        houses = ::CoreDataConnector::Taxonomy.create!(project_model: types.related_model, name: 'Houses')
        ::CoreDataConnector::Relationship.create!(project_model_relationship: types, primary_record: a.place, related_record: house)
        path = "/core_data/sites/#{a.site.id}/categories"

        status 'anonymous can\'t list them', get(path), '401'
        status 'nor rename one', patch("#{path}/#{house.id}", { name: 'x' }), '401'
        status 'another tenant can\'t rename one', patch("#{path}/#{house.id}", { name: 'x' }, b.token), %w[401 404]
        status 'nor through its own atlas', patch("/core_data/sites/#{b.site.id}/categories/#{house.id}", { name: 'x' }, b.token), '404'
        check 'and the name is unchanged', house.reload.name == 'house', house.name

        res = get(path, a.token)
        status 'the owner lists them', res, '200'
        terms = Array(body(res)['categories']).flat_map { |c| c['terms'] }
        check 'with how many places use each', terms.any? { |t| t['id'] == house.id && t['places'] == 1 }, terms.inspect[0, 200]
        status 'a blank name is refused', patch("#{path}/#{house.id}", { name: '  ' }, a.token), '422'

        patch("#{path}/#{house.id}", { name: 'House' }, a.token)
        check 'the owner renames one', house.reload.name == 'House', house.name
        res = patch("#{path}/#{house.id}", { name: 'houses' }, a.token)
        linked = ::CoreDataConnector::Relationship.where(project_model_relationship: types, primary_record: a.place).map(&:related_record_id)
        check 'renaming onto another value merges the two', body(res)['merged'] == true && !::CoreDataConnector::Taxonomy.exists?(house.id) &&
                                                              linked == [houses.id] && houses.reload.name == 'houses',
              "#{res.body.to_s[0, 120]} linked=#{linked.inspect}"
      ensure
        if types
          ::CoreDataConnector::Relationship.where(project_model_relationship: types).delete_all
          ::CoreDataConnector::Taxonomy.where(project_model_id: types.related_model_id).delete_all
          related = types.related_model
          types.destroy
          related.destroy
        end
      end

      group 'photo links can\'t reach the server\'s own network' do
        remote_files_refusals
      end

      group 'an atlas\'s history: its project reads it; editors restore content, never what owners decide' do
        history(a, b)
      end

      group 'feedback reports: anyone signed in sends them; only admins read others\'' do
        feedback(a, b)
      end

      group 'uploaded photos get web-sized copies' do
        if ::CoreDataConnector::SiteImages.available?
          image_copies(a, b)
        else
          puts '  skip (libvips is not available to this host: images are served as uploaded)'
        end
      end
    end

    private

    # The atlas's history (SiteVersion): saves become versions; who can read
    # and restore them; a restore puts back content only.
    def history(a, b)
      site = "/core_data/sites/#{a.site.id}"
      versions = "#{site}/versions"
      branding = (a.site.reload.branding || {}).merge('primary_color' => '#123456')

      status 'the owner saves the branding', patch(site, { site: { branding: } }, a.token), '200'
      res = get(versions, a.token)
      status 'the owner lists the versions', res, '200'
      list = Array(body(res)['versions'])
      newest = list.first || {}
      check '... the save, by them, with what changed', newest['source'] == 'console' && newest.dig('user', 'id') == a.user.id &&
                                                         newest['changed_parts'] == ['branding'], newest.inspect[0, 160]
      check '... and the atlas as it was before, to go back to', list.size >= 2 && %w[baseline created].include?(list.last['source']), list.map { |v| v['source'] }.inspect
      older = list.last

      refused 'anonymous can\'t list them', get(versions)
      status 'another tenant can\'t list them', get(versions, b.token), %w[401 404]
      status 'nor read one', get("#{versions}/#{older['id']}", b.token), %w[401 404]
      status 'nor restore one', post("#{versions}/#{older['id']}/restore", { parts: ['branding'] }, b.token), %w[401 404]
      status 'nor through its own atlas', post("/core_data/sites/#{b.site.id}/versions/#{older['id']}/restore", { parts: ['branding'] }, b.token), '404'
      check '... and the branding is unchanged', a.site.reload.branding['primary_color'] == '#123456', a.site.branding['primary_color']

      res = get("#{versions}/#{older['id']}", a.token)
      check 'a version says what restoring it would change', body(res).dig('differences', 'branding').to_a.any? { |line| line.include?('#123456') }, res.body[0, 200]

      editor_token = login(Fixtures::EDITOR_EMAIL)
      status 'an editor restores the branding', post("#{versions}/#{older['id']}/restore", { parts: ['branding'] }, editor_token), '200'
      check '... put back', a.site.reload.branding['primary_color'] != '#123456'
      restored = Array(body(get(versions, a.token))['versions']).first || {}
      check '... as a new version, by them, from the old one', restored['source'] == 'restore' && restored['restored_from_id'] == older['id'],
            restored.inspect[0, 160]
      status 'a restore can\'t touch what owners decide', post("#{versions}/#{older['id']}/restore", { parts: %w[published slug domain] }, editor_token), '422'
      check '... the atlas stays published at its address', a.site.reload.published == true && a.site.slug == 'og-tenancy-probe-a'
    end

    # "Send feedback": who may send a report, about which atlas, and who may
    # read it, its screenshot and its status.
    def feedback(a, b)
      path = '/core_data/feedback_reports'
      report = { what_happened: 'Probe: the import failed.', expected: 'Places on the map.', page_url: '/atlases', context: { source: 'probe' } }
      ids = ->(res) { Array(body(res)['feedback_reports']).map { |r| r['id'] } }

      refused 'anonymous can\'t send one', post(path, report)
      refused 'nor list them', get(path)

      res = post(path, report.merge(site_id: a.site.id), a.token)
      status 'an owner sends one about their atlas', res, '201'
      mine = body(res)['feedback_report'] || {}
      check '... tied to the atlas and its project', mine.dig('site', 'id') == a.site.id && mine.dig('project', 'id') == a.project.id, mine.inspect[0, 160]

      before = ::CoreDataConnector::FeedbackReport.count
      status 'another tenant can\'t send one about it', post(path, report.merge(site_id: a.site.id), b.token), '404'
      check '... and nothing is saved', ::CoreDataConnector::FeedbackReport.count == before

      editor_token = login(Fixtures::EDITOR_EMAIL)
      status 'an editor (a FairData guest) sends one', post(path, report.merge(site_id: a.site.id), editor_token), '201'

      res = post(path, report, b.token)
      status 'B sends one without an atlas', res, '201'
      theirs = body(res)['feedback_report']&.dig('id')

      res = get(path, b.token)
      check 'B lists only its own', ids.(res) == [theirs], ids.(res).inspect
      status 'B can\'t read A\'s', get("#{path}/#{mine['id']}", b.token), %w[401 404]
      status 'nor mark it resolved', patch("#{path}/#{mine['id']}", { status: 'resolved' }, b.token), %w[401 404]
      status 'an owner can\'t mark even their own resolved', patch("#{path}/#{mine['id']}", { status: 'resolved' }, a.token), %w[401 403]
      check '... and it stays new', ::CoreDataConnector::FeedbackReport.find(mine['id']).status == 'new'
      status 'a blank report is refused', post(path, report.merge(what_happened: '  '), a.token), '422'

      res = multipart(path, { what_happened: 'Probe: with a screenshot', site_id: a.site.id.to_s }, { screenshot: ['shot.png', PNG, 'image/png'] }, a.token)
      status 'a screenshot is attached', res, '201'
      shot = body(res)['feedback_report']&.dig('id')
      res = get("#{path}/#{shot}/screenshot", a.token, accept: '*/*')
      check 'the sender sees it, sandboxed', res.code == '200' && res['Content-Type'].to_s.start_with?('image/png') &&
                                            res['X-Content-Type-Options'] == 'nosniff' && res['Content-Security-Policy'].to_s.include?('sandbox') &&
                                            res['Cache-Control'].to_s.include?('no-store'), "#{res.code} #{res['Content-Type']}"
      status 'another tenant can\'t', get("#{path}/#{shot}/screenshot", b.token, accept: '*/*'), %w[401 404]
      status 'nor anonymous', get("#{path}/#{shot}/screenshot", nil, accept: '*/*'), '401'
      status 'an HTML file named .png is refused', multipart(path, { what_happened: 'x' }, { screenshot: ['shot.png', '<html><script>alert(1)</script></html>', 'image/png'] }, a.token), '422'

      admin = @fixtures.send(:build_admin, password: @password)
      admin_token = login(admin.email)
      res = get(path, admin_token)
      check 'an admin lists everyone\'s', (ids.(res) & [mine['id'], theirs, shot]).size == 3, ids.(res).inspect[0, 120]
      status 'an admin marks one resolved', patch("#{path}/#{mine['id']}", { status: 'resolved' }, admin_token), '200'
      check '... recorded, with who', ::CoreDataConnector::FeedbackReport.find(mine['id']).then { |r| r.status == 'resolved' && r.resolved_by_id == admin.id }
      status 'an admin sees the screenshot', get("#{path}/#{shot}/screenshot", admin_token, accept: '*/*'), '200'

      # Twenty an hour per person.
      codes = Array.new(::CoreDataConnector::FeedbackReport::HOURLY_LIMIT) { post(path, report, b.token).code }
      check 'too many in an hour are refused', codes.last == '429' && codes.count('201') == ::CoreDataConnector::FeedbackReport::HOURLY_LIMIT - 1, codes.tally.inspect
    end

    # A 2400 x 1600 photo through upload, the public bundle, the public route
    # and delete (SiteImages).
    # Languages (config.i18n) and translated pages (content.translations):
    # what's refused, and what the public bundle carries.
    def languages(a)
      site = "/core_data/sites/#{a.site.id}"
      pages = [{ slug: 'about', title: 'About', sections: [{ type: 'call_to_action', title: 'Map', button_url: '/en/search/places' }] }]
      i18n = ->(locales) { { 'default_locale' => 'en', 'locales' => locales } }
      config = ->(locales) { (a.site.reload.config || {}).merge('i18n' => i18n.(locales)) }

      status 'a language the renderer doesn\'t route is refused', patch(site, { site: { config: config.(%w[en zz]) } }, a.token), %w[400 422]
      status 'so is a translation into one', patch(site, { site: { content: { pages:, translations: { zz: { pages: [] } } } } }, a.token), %w[400 422]
      status 'or of a page the atlas doesn\'t have', patch(site, { site: { content: { pages:, translations: { es: { pages: [{ slug: 'nope', title: 'No' }] } } } } }, a.token), %w[400 422]
      bad = { pages:, translations: { es: { pages: [{ slug: 'about', title: 'A', sections: [{ type: 'call_to_action', button_url: 'javascript:alert(1)' }] }] } } }
      status 'or a translation with a javascript: link', patch(site, { site: { content: bad } }, a.token), %w[400 422]
      status 'or a menu label in an unknown language', patch(site, { site: { navigation: { items: [{ _template: 'Page', page: 'about', labels: { zz: 'x' } }] } } }, a.token), %w[400 422]

      res = patch(site, { site: { config: config.(%w[en es]), content: { pages:, translations: { es: { pages: [{ slug: 'about', title: 'Acerca de', sections: [] }] } } } } }, a.token)
      status 'English and Spanish, with a Spanish page, is saved', res, '200'

      atlas = body(get("/core_data/public/v1/atlases/#{a.site.slug}"))['atlas'] || {}
      menu = atlas.dig('navigations', 'es', 'items') || []
      check 'the public bundle carries the translation', atlas.dig('content', 'translations', 'es', 'pages', 0, 'title') == 'Acerca de'
      check 'and a menu per language, with Spanish titles and links', menu.any? { |item| item['label'] == 'Acerca de' && item['href'] == '/es/pages/about' } &&
                                                                     (atlas.dig('navigations', 'en', 'items') || []).any? { |item| item['href'] == '/en/pages/about' },
            menu.inspect[0, 200]
    ensure
      a.site.reload.update_columns(content: {}, navigation: {}, config: (a.site.config || {}).except('i18n'))
    end

    # A project editor (FairData's role) does the atlas's content work —
    # settings, pages, images, categories, places, imports, reindexing —
    # but publishing, the slug, the domain, the preview link and deleting
    # stay with the owners (SitePolicy#manage?, #destroy?). And the editor
    # of A is nobody on B.
    def editor(a, b)
      token = login(Fixtures::EDITOR_EMAIL)
      site = "/core_data/sites/#{a.site.id}"
      project = "/core_data/projects/#{a.project.id}"

      res = get(site, token)
      status 'an editor opens the atlas', res, '200'
      check 'and is told it can edit but not manage or delete', body(res).dig('site', 'permissions') == { 'edit' => true, 'manage' => false, 'delete' => false },
            body(res).dig('site', 'permissions').inspect
      check 'the owner is told it can do all three', body(get(site, a.token)).dig('site', 'permissions') == { 'edit' => true, 'manage' => true, 'delete' => true }

      status 'saves the pages', patch(site, { site: { content: { pages: [{ slug: 'editors', title: 'Editors', sections: [{ type: 'text', body: 'Hi' }] }] } } }, token), '200'
      status 'and the branding', patch(site, { site: { branding: { primary_color: '#123456' } } }, token), '200'
      status 'a save that sends the slug and state unchanged goes through', patch(site, { site: { name: a.site.name, slug: a.site.slug, published: true } }, token), '200'
      refused 'but changing the slug is refused', patch(site, { site: { slug: "#{a.site.slug}-moved" } }, token)
      refused 'so is unpublishing', patch(site, { site: { published: false } }, token)
      a.site.reload
      check 'and both are unchanged', a.site.slug == 'og-tenancy-probe-a' && a.site.published, "#{a.site.slug} #{a.site.published}"
      refused 'replacing the preview link is refused', post("#{site}/preview_token", {}, token)
      refused 'so is setting a domain', put("#{site}/domain", { domain: 'og-probe-editor.example.com' }, token)
      refused 'or checking one', post("#{site}/domain/check", {}, token)
      check 'and the atlas has no domain', a.site.reload.domain.nil?
      refused 'deleting the atlas is refused', delete(site, token)
      check 'and it\'s still there', ::CoreDataConnector::Site.exists?(a.site.id)

      res = upload("#{site}/assets", 'editor.png', PNG, token)
      status 'uploads an image', res, '200'
      status 'and deletes it', delete("#{site}/assets/#{body(res).dig('asset', 'key')}", token), '204'
      status 'lists the categories', get("#{site}/categories", token), '200'
      status 'lists the places without a location', get("#{site}/unlocated_places", token), '200'

      # Imports: an incomplete request gets past authorization and fails on
      # its input, never 401/403/404.
      res = post("#{project}/dataset_imports/preview", {}, token)
      check 'can upload a dataset (gets past authorization)', !REFUSED.include?(res.code), "got #{res.code}"
      res = post("#{project}/dataset_imports", { dataset_import: { columns: [] } }, token)
      check 'can import one', !REFUSED.include?(res.code), "got #{res.code}"
      res = post("#{project}/place_imports/preview", { place_import: { source: 'nowhere', area: {}, filters: {} } }, token)
      check 'can preview a gazetteer import', !REFUSED.include?(res.code), "got #{res.code}"

      res = post("/core_data/search_collections/#{a.collection.id}/reindex", {}, token)
      status 'reindexes the atlas', res, '200'
      job = ::CoreDataConnector::Job.find_by(id: body(res).dig('job', 'id'))
      20.times { break if job.nil? || %w[completed failed].include?(job.reload.status); sleep 0.5 }

      refused 'edits nothing of B\'s', patch("/core_data/sites/#{b.site.id}", { site: { name: 'x' } }, token)
      refused 'imports nothing into B', post("/core_data/projects/#{b.project.id}/dataset_imports/preview", {}, token)
      refused 'reindexes nothing of B\'s', post("/core_data/search_collections/#{b.collection.id}/reindex", {}, token)
    ensure
      a.site.reload.update!(slug: 'og-tenancy-probe-a', published: true, content: {}, branding: {}) if a.site
    end

    # An atlas's own domain (SiteDomains): who can set it, what's refused,
    # that only a connected domain is served and only for its own atlas,
    # that a second atlas can't take it without the DNS, and that drafts
    # stay private there. On a development server .localhost names connect
    # without DNS; elsewhere they're refused and only the DNS path is checked.
    def own_domain(a, b)
      suffix = SecureRandom.hex(3)
      local = ::CoreDataConnector::SiteDomains.local_names_allowed?
      base = ::CoreDataConnector::SiteDomains.base_domain
      domain = "og-probe-a-#{suffix}.test.localhost"
      elsewhere = "og-probe-#{suffix}.example.com"
      path_a = "/core_data/sites/#{a.site.id}/domain"
      path_b = "/core_data/sites/#{b.site.id}/domain"
      lookup = ->(name) { "/core_data/public/v1/atlases/by_domain?domain=#{name}" }
      allowed = ->(name) { "/core_data/public/v1/domains/allowed?domain=#{name}" }

      refused 'anonymous can\'t set a domain', put(path_a, { domain: elsewhere })
      refused 'nor another tenant', put(path_a, { domain: elsewhere }, b.token)
      refused 'nor check one', post("#{path_a}/check", {}, b.token)
      check 'and the atlas has none', a.site.reload.domain.nil?

      refusals = ['localhost', '127.0.0.1', 'bad..name.org', '-x.example.org', "#{'a' * 64}.org", 'xn--caf-dma.org.' * 20, 'café.org']
      refusals << 'og-tenancy-probe-b.localhost' if local
      refusals += [base, "#{b.site.slug}.#{base}"] if base
      console = ::CoreDataConnector::SiteDomains.console_host
      refusals << console if console&.include?('.')
      refusals.uniq.each { |name| status "#{name.truncate(40)} is refused", put(path_a, { domain: name }, a.token), '422' }

      res = patch("/core_data/sites/#{b.site.id}", { site: { domain: elsewhere, domain_verified_at: Time.now.utc } }, b.token)
      b.site.reload
      check 'the general update can\'t set or connect a domain', b.site.domain.nil? && b.site.domain_verified_at.nil?, "#{res.code} #{b.site.domain.inspect}"

      if local
        res = put(path_a, { domain: "HTTPS://#{domain.upcase}:4321/about?x=1" }, a.token)
        status 'the owner can set one', res, '200'
        check 'stored without scheme, case, port or path', body(res).dig('site', 'domain') == domain, body(res).dig('site', 'domain')
        check 'a local name connects without DNS', body(res).dig('site', 'domain_status') == 'connected'

        res = get(lookup.(domain))
        status 'the domain resolves', res, '200'
        check 'to its own atlas only', body(res).dig('atlas', 'slug') == a.site.slug &&
                                       body(res).dig('atlas', 'config', 'core_data', 'project_ids') == [a.project.id.to_s]
        check 'and the slug lookup names the domain', body(get("/core_data/public/v1/atlases/#{a.site.slug}")).dig('atlas', 'domain') == domain
        status 'the TLS check allows it', get(allowed.(domain)), '200'
        status 'in any case', get(lookup.(domain.upcase)), '200'
        res = get(lookup.("www.#{domain}"))
        check 'its www pair resolves to the same atlas, naming the domain to send visitors to',
              res.code == '200' && body(res).dig('atlas', 'slug') == a.site.slug && body(res).dig('atlas', 'domain') == domain, res.code
        status 'and gets a certificate', get(allowed.("www.#{domain}")), '200'

        res = put(path_b, { domain: }, b.token)
        status 'another atlas can enter the same domain', res, '200'
        check 'but it isn\'t connected to it', body(res).dig('site', 'domain_status') == 'pending'
        res = post("#{path_b}/check", {}, b.token)
        check 'checking again doesn\'t take it', body(res).dig('site', 'domain_status') == 'pending' && body(res).dig('check', 'connected') == false
        check 'and the domain still serves the first atlas', body(get(lookup.(domain))).dig('atlas', 'slug') == a.site.slug
        put(path_b, { domain: '' }, b.token)

        a.site.update!(published: false)
        status 'a draft isn\'t served at its domain', get(lookup.(domain)), '404'
        status 'nor with another atlas\'s preview token', get(lookup.(domain), nil, preview: b.site.preview_token), '404'
        status 'its own preview token shows it', get(lookup.(domain), nil, preview: a.site.preview_token), '200'
        status 'and it still gets a certificate (preview links need one)', get(allowed.(domain)), '200'
        a.site.update!(published: true)

        slug = a.site.slug
        patch("/core_data/sites/#{a.site.id}", { site: { slug: "#{slug}-moved" } }, a.token)
        check 'a new slug disconnects the domain', a.site.reload.domain_status == 'pending'
        status 'which then isn\'t served', get(lookup.(domain)), '404'
        patch("/core_data/sites/#{a.site.id}", { site: { slug: } }, a.token)
        res = post("#{path_a}/check", {}, a.token)
        check 'until it\'s checked again', body(res).dig('site', 'domain_status') == 'connected' && get(lookup.(domain)).code == '200'
      else
        status '.localhost domains are refused outside development', put(path_a, { domain: }, a.token), '422'
      end

      res = put(path_a, { domain: elsewhere }, a.token)
      status 'a domain whose DNS doesn\'t name the atlas can be entered', res, '200'
      check 'and waits for DNS', body(res).dig('site', 'domain_status') == 'pending' && body(res).dig('check', 'connected') == false
      status 'it isn\'t served', get(lookup.(elsewhere)), '404'
      status 'and gets no certificate', get(allowed.(elsewhere)), '404'
      status 'the domain it replaced is no longer served', get(lookup.(domain)), '404' if local
      check 'and the atlas isn\'t sent anywhere', body(get("/core_data/public/v1/atlases/#{a.site.slug}")).dig('atlas', 'domain').nil?

      status 'nor its www pair', get(lookup.("www.#{elsewhere}")), '404'

      res = put(path_a, { domain: '' }, a.token)
      check 'the owner can remove it', res.code == '200' && a.site.reload.domain.nil?
      status 'after which its www pair isn\'t served either', get(lookup.("www.#{domain}")), '404' if local

      if base
        status 'the TLS check allows an atlas\'s platform address', get(allowed.("#{a.site.slug}.#{base}")), '200'
        status 'but not a made-up one', get(allowed.("no-such-atlas-#{suffix}.#{base}")), '404'
      end
      status 'nor an unknown domain', get(allowed.("nobody-#{suffix}.example.org")), '404'
    ensure
      [a.site, b.site].each { |site| site.reload.update_columns(domain: nil, domain_verified_at: nil) }
      a.site.update!(published: true) unless a.site.published
      a.site.update!(slug: 'og-tenancy-probe-a') unless a.site.slug == 'og-tenancy-probe-a'
    end

    def image_copies(a, b)
      xyz = Vips::Image.xyz(2400, 1600)
      photo = (xyz[0] * (255.0 / 2400)).bandjoin([xyz[1] * (255.0 / 1600), xyz[0] * 0 + 128]).cast(:uchar)
                                       .copy(interpretation: :srgb).jpegsave_buffer(Q: 90)

      res = upload("/core_data/sites/#{a.site.id}/assets", 'photo.jpg', photo, a.token)
      status 'a 2400 px photo uploads', res, '200'
      asset = body(res)['asset'] || {}
      check 'with its size', asset['width'] == 2400 && asset['height'] == 1600, asset.slice('width', 'height').inspect
      check 'and a smaller preview for the console', asset['thumbnail_path'].present? && asset['thumbnail_path'] != asset['path']

      image = body(get("/core_data/public/v1/atlases/#{a.site.slug}")).dig('atlas', 'images', asset['key']) || {}
      variants = image['variants'] || []
      check 'the public bundle lists its copies, 2000 px at most',
            variants.map { |v| v['width'] } == [160, 320, 640, 1024, 1440, 2000], variants.map { |v| v['width'] }.inspect

      largest = variants.last || {}
      res = get(largest['path'].to_s)
      status 'the largest copy is public', res, '200'
      served = res.code == '200' ? Vips::Image.new_from_buffer(res.body, '') : nil
      check 'as a JPEG of the advertised size',
            res['Content-Type'] == 'image/jpeg' && served && [served.width, served.height] == [largest['width'], largest['height']],
            "#{res['Content-Type']} #{served && [served.width, served.height].inspect}"

      keys = (body(get("/core_data/sites/#{a.site.id}/assets", a.token))['assets'] || []).map { |listed| listed['key'] }
      variant_keys = variants.map { |v| v['path'].to_s.split('/')[-2] }
      check 'the image library lists the photo, not its copies', keys.include?(asset['key']) && (keys & variant_keys).empty?

      status 'a truncated photo is refused', upload("/core_data/sites/#{a.site.id}/assets", 'cut.jpg', photo[0, photo.bytesize / 3], a.token), '422'
      status 'too many pixels is refused',
             upload("/core_data/sites/#{a.site.id}/assets", 'huge.png', Vips::Image.black(11_000, 10_000).pngsave_buffer(compression: 9), a.token), '422'

      image_crops(a, b, asset)

      status 'deleting the photo', delete("/core_data/sites/#{a.site.id}/assets/#{asset['key']}", a.token), '204'
      status 'deletes its copies', get(largest['path'].to_s), '404'

      tiff_copies(a, photo)
    end

    # Cropping an uploaded photo (the console's image picker): a new image of
    # the atlas, cut from the original where asked, with its own copies; the
    # original stays; nobody else's atlas can crop it.
    def image_crops(a, b, asset)
      crop = "/core_data/sites/#{a.site.id}/assets/#{asset['key']}/crop"
      link_preview = { x: 100, y: 200, width: 1910, height: 1000 }

      status 'anonymous can\'t crop it', post(crop, link_preview), '401'
      status 'another tenant can\'t crop it', post(crop, link_preview, b.token), %w[401 404]
      status 'nor through its own atlas', post("/core_data/sites/#{b.site.id}/assets/#{asset['key']}/crop", link_preview, b.token), '404'

      res = post(crop, link_preview, a.token)
      status 'the owner crops it to 1.91:1 (a link preview)', res, '200'
      cropped = body(res)['asset'] || {}
      check '... a new image of that size, with its own copies',
            cropped['key'] && cropped['key'] != asset['key'] && [cropped['width'], cropped['height']] == [1910, 1000] &&
            cropped['thumbnail_path'] != cropped['path'], cropped.slice('key', 'width', 'height').inspect
      check '... recording what it was cut from', cropped['cropped_from'] == link_preview.transform_keys(&:to_s).merge('from' => asset['key']),
            cropped['cropped_from'].inspect

      # The photo's red rises with x and its green with y: the crop's first
      # pixel must be the original's pixel at (100, 200).
      served = Vips::Image.new_from_buffer(get(cropped['path'].to_s).body, '')
      expected = [100 * 255.0 / 2400, 200 * 255.0 / 1600, 128]
      pixel = served.getpoint(0, 0)
      check '... cut where asked', pixel.zip(expected).all? { |got, want| (got - want).abs <= 6 }, "#{pixel.inspect} vs #{expected.map(&:round).inspect}"

      keys = (body(get("/core_data/sites/#{a.site.id}/assets", a.token))['assets'] || []).map { |listed| listed['key'] }
      check 'the original stays in the library', keys.include?(asset['key']) && keys.include?(cropped['key'])
      status 'a crop outside the image is refused', post(crop, { x: 2000, y: 0, width: 500, height: 100 }, a.token), '422'
      status 'and one that isn\'t whole pixels', post(crop, { x: '1.5', y: 0, width: 100, height: 100 }, a.token), '422'

      res = post(crop, { x: 0, y: 0, width: 160, height: 160 }, login(Fixtures::EDITOR_EMAIL))
      status 'an editor crops too', res, '200'

      [cropped['key'], body(res).dig('asset', 'key')].compact.each { |key| delete("/core_data/sites/#{a.site.id}/assets/#{key}", a.token) }
    end

    # RemoteFiles (photo links in uploaded data are fetched by the server):
    # every address that leads inside is refused before a connection is made.
    def remote_files_refusals
      fetcher = ::CoreDataConnector::RemoteFiles
      {
        'loopback' => 'http://127.0.0.1/',
        'localhost by name' => 'http://localhost/',
        'cloud metadata' => 'http://169.254.169.254/latest/meta-data/',
        'a private network' => 'http://10.0.0.1/',
        'carrier-grade NAT (Tailscale)' => 'http://100.100.100.100/',
        'IPv6 loopback' => 'http://[::1]/',
        'IPv4 inside IPv6' => 'http://[::ffff:127.0.0.1]/',
        'another port' => 'http://example.com:9200/',
        'another scheme' => 'file:///etc/passwd',
        'a user:password address' => 'http://user:pass@example.com/'
      }.each do |label, url|
        begin
          fetcher.fetch(url)
          check "refuses #{label}", false, url
        rescue fetcher::Refused
          check "refuses #{label}", true
        rescue fetcher::Error => e
          check "refuses #{label}", false, "#{e.class}: #{e.message}"
        end
      end
    end

    # A 16-bit TIFF scan (what archives hand out) is stored as a JPEG.
    def tiff_copies(a, photo)
      unless ::CoreDataConnector::SiteImages.converts_tiff?
        status 'a TIFF is refused when it can\'t be converted', upload("/core_data/sites/#{a.site.id}/assets", 'scan.tif', 'II*' + "\0" * 64, a.token), '422'
        return
      end

      scan = Vips::Image.new_from_buffer(photo, '').colourspace(:rgb16).tiffsave_buffer
      res = upload("/core_data/sites/#{a.site.id}/assets", 'scan.tif', scan, a.token)
      status 'a 16-bit TIFF scan uploads', res, '200'
      asset = body(res)['asset'] || {}
      check 'stored as a JPEG named for it, at full size',
            asset['content_type'] == 'image/jpeg' && asset['filename'] == 'scan.jpg' && asset['width'] == 2400,
            asset.slice('content_type', 'filename', 'width').inspect
      res = get(asset['path'].to_s)
      check 'served as an 8-bit JPEG', res['Content-Type'] == 'image/jpeg' && Vips::Image.new_from_buffer(res.body, '').format == :uchar, res['Content-Type']
      status 'a damaged TIFF is refused', upload("/core_data/sites/#{a.site.id}/assets", 'cut.tif', scan[0, scan.bytesize / 3], a.token), '422'
      delete("/core_data/sites/#{a.site.id}/assets/#{asset['key']}", a.token) if asset['key']
    end

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

    def get(path, token = nil, preview: nil, accept: 'application/json') = request(Net::HTTP::Get, path, nil, token, preview:, accept:)

    # A multipart form: fields plus files ({ name => [filename, bytes, type] }).
    def multipart(path, fields, files, token = nil)
      uri = URI.join(@host, path)
      req = Net::HTTP::Post.new(uri)
      req['Accept'] = 'application/json'
      req['Authorization'] = token if token
      parts = fields.map { |name, value| [name.to_s, value.to_s] } +
              files.map { |name, (filename, bytes, type)| [name.to_s, StringIO.new(bytes), { filename:, content_type: type }] }
      req.set_form(parts, 'multipart/form-data')

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
    end

    # A multipart file upload (the console's image upload).
    def upload(path, filename, bytes, token = nil)
      uri = URI.join(@host, path)
      req = Net::HTTP::Post.new(uri)
      req['Accept'] = 'application/json'
      req['Authorization'] = token if token
      req.set_form([['file', StringIO.new(bytes), { filename:, content_type: 'image/png' }]], 'multipart/form-data')

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
    end

    def post(path, payload, token = nil) = request(Net::HTTP::Post, path, payload, token)
    def patch(path, payload, token = nil) = request(Net::HTTP::Patch, path, payload, token)
    def put(path, payload, token = nil) = request(Net::HTTP::Put, path, payload, token)
    def delete(path, token = nil) = request(Net::HTTP::Delete, path, nil, token)

    def request(klass, path, payload, token, accept: 'application/json', preview: nil)
      uri = URI.join(@host, path)
      req = klass.new(uri)
      req['Accept'] = accept
      req['Authorization'] = token if token
      req['X-OG-Preview'] = preview if preview

      if payload
        req['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
    end
  end
end
