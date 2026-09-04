require 'open_geographies/decorators'

module OpenGeographies
  class Engine < ::Rails::Engine
    # Without isolate_namespace the engine name would default to
    # "open_geographies_engine"; set it explicitly so the install task and the
    # copied migration suffix are the clean `open_geographies` (see README).
    engine_name 'open_geographies'

    # Deliberately NOT isolated. Open Geographies extends Core Data *in place*: its
    # models/controllers/serializers/policies/jobs live in the CoreDataConnector
    # namespace (they are genuinely Core Data domain objects — a Site extends a
    # Project), and its routes join the connector engine's /core_data route set.
    # Isolating the namespace would fork the very namespace we intend to share.

    config.generators.api_only = true

    # Apply the in-place extensions to upstream Core Data classes (the conversions of
    # the 20 files the fork used to modify) on boot and after every code reload, so
    # they survive Zeitwerk reloading in development.
    config.to_prepare do
      # Fail with a clear message rather than a NameError deep in the decorators
      # when the engine is mounted on a host that doesn't provide Core Data at all.
      unless defined?(::CoreDataConnector::Project)
        raise OpenGeographies::HostError,
              'open_geographies must be mounted on a Core Data / FairData host: ' \
              'CoreDataConnector::Project is not defined.'
      end

      OpenGeographies::Decorators.apply!
    end

    # The routes Open Geographies adds under /core_data — e.g.
    # GET /core_data/public/v1/atlases/:slug and the admin sites/search_collections/
    # place_imports endpoints. Controllers resolve to CoreDataConnector::*.
    ROUTES = proc do
        # --- Admin API (engine root → /core_data/...) ---
        resources :atlases, only: [:create]

        # Additive: upstream declares `resources :jobs, only: [:destroy, :index]`.
        # We add the wizard's progress-polling show without redefining the `job`
        # route helper (which upstream's :destroy member already owns).
        get 'jobs/:id', to: 'jobs#show', as: nil

        resources :search_collections do
          post :reindex, on: :member
          post :issue_key, on: :member
        end

        resources :sites do
          get :config, action: :site_config, on: :member
          post :build_tiles, on: :member
        end

        # NOTE: the admin `projects/:id/descriptors` route is NOT added here — it
        # ships on the connector mirror with the discoverable-gate commit (the
        # authenticated descriptors endpoint), so appending it again would clash
        # on the `descriptors_project` route helper.

        # Authority bulk imports (atlas wizard step 3 + console re-runs). The
        # unscoped admin_children variant authorizes on create-project (wizard
        # collects the area before the project exists).
        post 'projects/:project_id/place_imports/preview', to: 'place_imports#preview', as: nil
        post 'projects/:project_id/place_imports', to: 'place_imports#create', as: nil
        get 'projects/:project_id/place_imports/admin_children', to: 'place_imports#admin_children', as: nil
        get 'place_imports/admin_children', to: 'place_imports#admin_children', as: nil

        # --- Public V1 API (→ /core_data/public/v1/...) ---
        namespace :public do
          namespace :v1 do
            # Shared dynamic renderer: resolve a published atlas by slug.
            resources :atlases, only: [:show], param: :slug
          end
        end
    end

    # Register the routes wherever the host serves Core Data from. Two host shapes
    # exist:
    #
    # - The merged core-data-cloud / FairData app: the old connector engine is gone
    #   and its routes live directly in the host's routes.rb as
    #   `scope path: 'core_data', module: 'core_data_connector'`. Append ours to the
    #   host under that same scope so the URLs are unchanged.
    # - A legacy host still on the standalone gem: append to the connector engine's
    #   own route set, exactly as before.
    #
    # Registered before routes are finalized (after :add_routing_paths).
    initializer 'open_geographies.append_routes', after: :add_routing_paths do |app|
      routes = OpenGeographies::Engine::ROUTES

      if defined?(::CoreDataConnector::Engine)
        ::CoreDataConnector::Engine.routes.append(&routes)
      else
        app.routes.append do
          scope path: 'core_data', module: 'core_data_connector' do
            instance_exec(&routes)
          end
        end
      end
    end
  end

  # Raised when the engine is mounted on a host that does not provide Core Data.
  class HostError < StandardError; end
end
