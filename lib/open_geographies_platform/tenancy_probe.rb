# frozen_string_literal: true

require 'base64'
require 'net/http'
require 'json'
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

        res = upload("/core_data/sites/#{a.site.id}/assets", 'own.png', PNG, a.token)
        status 'own image upload', res, '200'
        own_key = body(res).dig('asset', 'key')
        status 'an HTML file named .png is refused', upload("/core_data/sites/#{a.site.id}/assets", 'page.png', '<html><script>alert(1)</script></html>', a.token), '422'
        status 'own image delete', delete("/core_data/sites/#{a.site.id}/assets/#{own_key}", a.token), '204'
      end

      group 'photo links can\'t reach the server\'s own network' do
        remote_files_refusals
      end

      group 'uploaded photos get web-sized copies' do
        if ::CoreDataConnector::SiteImages.available?
          image_copies(a)
        else
          puts '  skip (libvips is not available to this host: images are served as uploaded)'
        end
      end
    end

    private

    # A 2400 x 1600 photo through upload, the public bundle, the public route
    # and delete (SiteImages).
    def image_copies(a)
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

      status 'deleting the photo', delete("/core_data/sites/#{a.site.id}/assets/#{asset['key']}", a.token), '204'
      status 'deletes its copies', get(largest['path'].to_s), '404'

      tiff_copies(a, photo)
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

    def get(path, token = nil, preview: nil) = request(Net::HTTP::Get, path, nil, token, preview:)

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
