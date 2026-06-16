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
      OpenGeographies::Decorators.apply!
    end

    # Add Open Geographies' routes to the connector engine's route set so they are
    # served under the same /core_data mount the host already provides — e.g.
    # GET /core_data/public/v1/atlases/:slug and the admin sites/search_collections/
    # place_imports endpoints. Registered before routes are finalized; the append
    # block is evaluated in the connector engine's (isolated CoreDataConnector) route
    # context, so controllers resolve to CoreDataConnector::*.
    initializer 'open_geographies.append_routes', after: :add_routing_paths do
      CoreDataConnector::Engine.routes.append do
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
    end
  end
end
