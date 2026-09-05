module CoreDataConnector
  class SitesController < ApplicationController
    # Search attributes
    search_attributes :name, :slug

    # Preloads
    preloads :project

    # GET /core_data/sites/:id/facets
    #
    # The facet attributes this site's searches can declare, derived from the
    # v1 index's mapping and promotion rules for the project's models (see
    # OpenGeographies::FacetCatalog). The console's facet pick-list.
    def facets
      site = Site.find(params[:id])
      authorize site, :show?

      models = ProjectModel.where(project_id: site.project_id).order(:order)

      render json: { facets: ::OpenGeographies::FacetCatalog.for_models(models).map(&:to_h) }, status: :ok
    end

    # GET /core_data/sites/:id/config
    #
    # Emits the config.json document for the site: the stored config with the
    # platform-derived sections (Core Data connection, the shared search index)
    # filled in.
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

    private

    # A site's project is fixed at creation (attr_readonly on the model):
    # authorization runs against the current project before an update, so a
    # project_id in an update body is dropped rather than raising.
    def prepare_params(item = nil)
      prepared = super

      item&.persisted? ? prepared.except('project_id', :project_id) : prepared
    end

  end
end
