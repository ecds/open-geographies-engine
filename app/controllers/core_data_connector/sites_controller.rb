module CoreDataConnector
  class SitesController < ApplicationController
    # Search attributes
    search_attributes :name, :slug

    # Preloads
    preloads :project

    # GET /core_data/sites/:id/config
    #
    # Emits the config.json document for the site: the stored config with the
    # platform-derived sections (Core Data connection, Typesense blocks from
    # the referenced search collections) filled in.
    #
    # The shared dynamic renderer resolves a site by slug through the public
    # endpoint (GET /core_data/public/v1/atlases/:slug); this authenticated,
    # id-addressed variant remains for console previews and tooling. Named
    # site_config because ActionController reserves #config.
    def site_config
      site = Site.find(params[:id])

      authorize site, :show?

      render json: site.to_site_config, status: :ok
    end

    # POST /core_data/sites/:id/build_tiles
    #
    # Queues PMTiles generation from the site's project geometries. The run is
    # tracked as a Job (job_type "build_tiles") so its status is visible in the
    # console. The generated archive is self-hosted (S3) and referenced by the
    # site config's pmtiles layer, served to the shared renderer's map.
    def build_tiles
      site = Site.find(params[:id])

      authorize site, :update?

      job = Job.create(
        project_id: site.project_id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_BUILD_TILES,
        extra: {
          site_id: site.id,
          site_slug: site.slug
        }
      )

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end
  end
end
