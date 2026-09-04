module CoreDataConnector
  # POST /core_data/atlases
  #
  # The "Create your atlas" wizard's provisioning endpoint. Creates the
  # database records for a new atlas synchronously — project (discoverable,
  # owned by the caller), starter models from the template, search
  # collection, site — so name/slug validation errors return immediately,
  # then queues a ProvisionAtlasJob for the external bit (making sure the shared
  # search index exists with its mapping). The atlas is then live on the shared
  # dynamic renderer — no content repository, build, or deploy.
  #
  # Params (atlas):
  #   name        - required; also the site name
  #   slug        - optional; defaults to name.parameterize
  #   description - optional project description
  #   locale      - optional default locale (default 'en')
  #   template    - 'places' (default) or 'atlas' (see Atlases::Template)
  #   area        - optional geographic area document, stored on the site:
  #                 { geometry_json: <GeoJSON>, admin_units: [...] }
  class AtlasesController < ApplicationController
    def create
      authorize Project.new, :create?

      template = atlas_params[:template].presence || 'places'

      unless Atlases::Template.valid?(template)
        render json: { errors: [{ base: "Unknown template: #{template}" }] }, status: :unprocessable_entity and return
      end

      name = atlas_params[:name]
      slug = atlas_params[:slug].presence || name.to_s.parameterize

      project = nil
      site = nil
      search_collection = nil

      ActiveRecord::Base.transaction do
        # Discoverable from the start: the public API only serves
        # discoverable projects, and the site this wizard publishes is
        # backed by those endpoints.
        project = Project.create!(
          name:,
          description: atlas_params[:description],
          discoverable: true
        )

        # Unlike ProjectsController#after_create, the owner row is created even
        # for admins: an atlas should always have an owner who can manage it.
        UserProject.create!(
          project:,
          user_id: current_user.id,
          role: UserProject::ROLE_OWNER
        )

        models = Atlases::Template.create_models!(project, template)
        places_model = models.find { |model| model.model_class == 'CoreDataConnector::Place' }

        search_collection = SearchCollection.create!(
          project:,
          name: "#{slug.tr('-', '_')}_places",
          project_model_ids: [places_model.id],
          auto_index: true,
          polygons: true
        )

        site = Site.create!(
          project:,
          name:,
          slug:,
          area: atlas_params[:area],
          config: default_config(search_collection, atlas_params[:locale].presence || 'en')
        )
      end

      # Created outside the transaction: the Job's after_create_commit queues
      # the async work, which must only run once the records are committed.
      job = Job.create!(
        project_id: project.id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_PROVISION_ATLAS,
        extra: {
          site_id: site.id,
          site_slug: site.slug,
          search_collection_id: search_collection.id
        }
      )

      render json: {
        atlas: {
          project_id: project.id,
          site_id: site.id,
          slug: site.slug,
          live_url: atlas_url(site.slug),
          search_collection_id: search_collection.id,
          job: { id: job.id, status: job.status }
        }
      }, status: :ok
    rescue ActiveRecord::RecordInvalid => error
      render json: { errors: [error.record.errors.to_hash.presence || { base: error.message }] }, status: :unprocessable_entity
    end

    private

    def atlas_params
      params.require(:atlas).permit(:name, :slug, :description, :locale, :template, area: {})
    end

    # The atlas's public URL on the shared dynamic renderer, when a URL template
    # is configured: OG_ATLAS_URL_TEMPLATE with `{slug}` substituted, e.g.
    # "https://{slug}.opengeographies.org". Returns nil when unset (local
    # single-tenant dev), so the wizard simply omits the link — the atlas is
    # live either way the instant it's provisioned.
    def atlas_url(slug)
      ENV['OG_ATLAS_URL_TEMPLATE'].presence&.gsub('{slug}', slug)
    end

    # The stored config for a fresh atlas: an OSM base layer and one places
    # search wired to the new collection. The platform-derived sections
    # (core_data connection, elasticsearch index name) are
    # filled in by Site#to_site_config at publish time.
    def default_config(search_collection, locale)
      {
        'layers' => [
          {
            'name' => 'OpenStreetMap',
            'layer_type' => 'raster',
            'url' => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
          }
        ],
        'search' => [
          {
            'name' => 'places',
            'route' => '/places',
            'geosearch' => true,
            'search_collection_id' => search_collection.id,
            'map' => {
              'geometry' => 'geometry',
              'zoom_to_place' => true,
              'max_zoom' => 16,
              'cluster_radius' => 8
            },
            'elasticsearch' => {
              'facet_attributes' => ['types']
            },
            'result_card' => {
              'title' => 'name'
            }
          }
        ],
        'i18n' => {
          'default_locale' => locale,
          'locales' => [locale]
        }
      }
    end
  end
end
