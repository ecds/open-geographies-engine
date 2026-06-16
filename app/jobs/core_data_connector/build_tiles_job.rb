require 'open3'
require 'fileutils'

module CoreDataConnector
  # Generates self-hosted PMTiles vector tiles from a site's project place
  # geometries:
  #
  #   1. Streams the project's geometries out of PostGIS as line-delimited
  #      GeoJSON — a "features" layer (original geometries, with uuid + name
  #      properties) and a "labels" layer (ST_PointOnSurface anchors for
  #      symbol/label placement).
  #   2. Runs tippecanoe to produce a .pmtiles archive.
  #   3. Stores it under the tiles root, where the build worker copies it
  #      into the site's public/tiles/ on the next deploy.
  #   4. Writes/updates the generated pmtiles layer entry in the site's
  #      config, so the next publish serves it with no manual config.
  #
  # Environment:
  #
  #   DEPLOY_TILES_ROOT - directory for generated tile archives
  #                       (default: DEPLOY_STATIC_ROOT/_tiles)
  #   TILES_PUBLIC_URL  - public base URL serving the tiles root (e.g. a
  #                       bucket/CDN). When unset the layer entry uses the
  #                       site-relative /tiles/<slug>.pmtiles that the build
  #                       worker copies into each deploy.
  #   TILES_MIN_ZOOM / TILES_MAX_ZOOM - tippecanoe zoom range (default 2/15)
  #
  # Requires tippecanoe on the PATH.
  class BuildTilesJob < ApplicationJob
    LAYER_NAME = 'All records'.freeze

    def self.tiles_root
      ENV.fetch('DEPLOY_TILES_ROOT') { File.join(ENV.fetch('DEPLOY_STATIC_ROOT'), '_tiles') }
    end

    def perform(job_id)
      job = Job.find(job_id)
      site = Site.find(job.extra['site_id'])

      job.update(status: Job::JOB_STATUS_PROCESSING)

      workspace = Rails.root.join('tmp', 'tiles', "#{site.slug}-#{job.id}").to_s
      FileUtils.mkdir_p(workspace)

      begin
        step job, 'export_geometries'
        count = export_geometries(site, workspace)

        raise 'Project has no place geometries to tile' if count.zero?

        step job, 'tippecanoe'
        archive = run_tippecanoe(site, workspace)

        step job, 'store'
        stored = store(site, archive)

        step job, 'update_config'
        url = update_site_config(site)

        job.update(
          status: Job::JOB_STATUS_COMPLETED,
          extra: job.extra.merge('features' => count, 'tiles' => stored, 'layer_url' => url)
        )
      rescue StandardError => error
        log_error error

        job.update(
          status: Job::JOB_STATUS_FAILED,
          extra: job.extra.merge('error' => error.message.truncate(1000))
        )
      ensure
        FileUtils.rm_rf(workspace)
      end
    end

    private

    # Streams the project's place geometries to features.geojsonl +
    # labels.geojsonl in the workspace. Returns the feature count.
    def export_geometries(site, workspace)
      features = File.open(File.join(workspace, 'features.geojsonl'), 'w')
      labels = File.open(File.join(workspace, 'labels.geojsonl'), 'w')

      count = 0

      query = Place
                .all_records_by_project(site.project_id)
                .joins(:place_geometry)
                .joins(:primary_name)
                .select(
                  'core_data_connector_places.id',
                  'core_data_connector_places.uuid AS place_uuid',
                  'core_data_connector_place_names.name AS place_name',
                  'ST_AsGeoJSON(core_data_connector_place_geometries.geometry) AS feature_json',
                  'ST_AsGeoJSON(ST_PointOnSurface(core_data_connector_place_geometries.geometry)) AS label_json'
                )

      query.find_each do |row|
        properties = { uuid: row.place_uuid, name: row.place_name }

        each_geometry(JSON.parse(row.feature_json)) do |geometry|
          features.puts({ type: 'Feature', geometry:, properties: }.to_json)
        end

        if row.label_json.present?
          labels.puts({ type: 'Feature', geometry: JSON.parse(row.label_json), properties: }.to_json)
        end

        count += 1
      end

      count
    ensure
      features&.close
      labels&.close
    end

    # Yields tileable geometries: tippecanoe does not accept
    # GeometryCollections (a KML-import artifact in real datasets), so
    # collection members are emitted as individual features.
    def each_geometry(geometry, &block)
      if geometry['type'] == 'GeometryCollection'
        (geometry['geometries'] || []).each { |member| each_geometry(member, &block) }
      else
        yield geometry
      end
    end

    def run_tippecanoe(site, workspace)
      archive = File.join(workspace, "#{site.slug}.pmtiles")

      run!(
        'tippecanoe',
        '-o', archive,
        '--force',
        '--name', site.slug,
        '-Z', ENV.fetch('TILES_MIN_ZOOM', '2'),
        '-z', ENV.fetch('TILES_MAX_ZOOM', '15'),
        '--drop-densest-as-needed',
        '--extend-zooms-if-still-dropping',
        '--coalesce-densest-as-needed',
        '-L', "features:#{File.join(workspace, 'features.geojsonl')}",
        '-L', "labels:#{File.join(workspace, 'labels.geojsonl')}",
        chdir: workspace
      )

      archive
    end

    def store(site, archive)
      target = File.join(self.class.tiles_root, "#{site.slug}.pmtiles")

      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(archive, target)

      target
    end

    # Writes the generated layer entry into the site config (or updates its
    # URL if present), so the next publish picks it up automatically. The
    # `generated` marker keeps re-runs idempotent and leaves hand-authored
    # layers alone.
    def update_site_config(site)
      url = layer_url(site)

      layers = (site.config['layers'] || []).deep_dup
      layer = layers.find { |entry| entry['generated'] == 'tiles' }

      if layer
        layer['url'] = url
      else
        layers << {
          'name' => LAYER_NAME,
          'layer_type' => 'pmtiles',
          'url' => url,
          'overlay' => true,
          'generated' => 'tiles'
        }
      end

      site.update!(config: site.config.merge('layers' => layers))

      url
    end

    def layer_url(site)
      base = ENV.fetch('TILES_PUBLIC_URL', nil)

      return "#{base.chomp('/')}/#{site.slug}.pmtiles" if base.present?

      "/tiles/#{site.slug}.pmtiles"
    end

    def step(job, name)
      job.update_columns(
        extra: job.extra.merge('step' => name),
        updated_at: Time.current
      )
    end

    def run!(*command, chdir: nil, env: {})
      options = {}
      options[:chdir] = chdir if chdir

      out, err, status = Open3.capture3(env, *command, **options)

      if chdir
        File.open(File.join(chdir, 'tiles.log'), 'a') do |log|
          log.puts "$ #{command.join(' ')}"
          log.puts out
          log.puts err
        end
      end

      raise "#{command.first} failed: #{err.to_s.split("\n").last(5).join(' | ')}" unless status.success?
    end

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
