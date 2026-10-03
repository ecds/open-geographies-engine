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
  #   modules     - optional module names to add to the 'atlas' template
  #                 (Atlases::Template.optional_models: Map Layers, Work Types, Tours)
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

      # The name problems a curator can fix, said in their terms, before
      # anything is created. Otherwise the first record to fail speaks for
      # them all: a reused name surfaced as the internal search collection's
      # "name has already been taken".
      if (problem = name_problem(name, slug))
        render json: { errors: [{ name: [problem] }] }, status: :unprocessable_entity and return
      end

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

        models = Atlases::Template.create_models!(project, template, include: atlas_params[:modules] || [])
        places_model = models.find { |model| model.model_class == 'CoreDataConnector::Place' }

        search_collection = SearchCollection.create!(
          project:,
          name: collection_name(slug),
          project_model_ids: [places_model.id],
          auto_index: true,
          polygons: true
        )

        locale = atlas_params[:locale].presence || 'en'

        # The starter home page (a banner with the description, a search box
        # and a way into the map) is stored rather than left to the default,
        # so the console opens on a page the curator owns and edits.
        # A draft: private until the curator publishes it from the console.
        SiteVersion::Context.user = current_user
        site = Site.create!(
          project:,
          name:,
          slug:,
          published: false,
          area: atlas_params[:area],
          config: default_config(search_collection, locale),
          content: {
            'home' => SiteContent.default_home(description: atlas_params[:description], search_href: "/#{locale}/search/places")
          }
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
          live_url: site.public_url,
          published: site.published,
          preview_token: site.preview_token,
          search_collection_id: search_collection.id,
          job: { id: job.id, status: job.status }
        }
      }, status: :ok
    rescue ActiveRecord::RecordInvalid => error
      render json: { errors: [error.record.errors.to_hash.presence || { base: error.message }] }, status: :unprocessable_entity
    end

    private

    def atlas_params
      params.require(:atlas).permit(:name, :slug, :description, :locale, :template, area: {}, modules: [])
    end

    # A curator-facing sentence when the name can't make an atlas, else nil.
    # Two names that differ only in punctuation or case ("Savannah,
    # Documented" / "savannah documented") share a web address, so the
    # address is what has to be free.
    def name_problem(name, slug)
      return 'Give the atlas a name.' if name.blank?
      return 'The name needs at least one letter or number.' if slug.blank?
      return 'That name is reserved. Choose a different one.' if Site::RESERVED_SLUGS.include?(slug)
      return 'The name is too long for a web address. Shorten it.' if slug.length > 63

      return unless Site.exists?(slug:)

      "Another atlas already uses this name (its address is “#{slug}”). Choose a different name."
    end

    # The search collection is internal (the site config points at it by
    # id), so a leftover collection from a deleted atlas just moves the new
    # one to the next free name.
    def collection_name(slug)
      base = "#{slug.tr('-', '_')}_places"
      name = base
      suffix = 1
      name = "#{base}_#{suffix += 1}" while SearchCollection.exists?(name:)
      name
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
            'facets' => [
              { 'name' => 'types', 'type' => 'list' }
            ],
            'result_card' => {
              'title' => 'name',
              'attributes' => [{ 'name' => 'types' }]
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
