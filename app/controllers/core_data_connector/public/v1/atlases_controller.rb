module CoreDataConnector
  module Public
    module V1
      # GET /core_data/public/v1/atlases/:slug
      #
      # Public, by-slug resolution of a published atlas for the shared dynamic
      # renderer (core-data-places). Returns everything the SSR app needs to
      # render an atlas at request time — the site config (the config.json
      # document), branding, and navigation — in a single document, so the
      # renderer resolves an atlas per request with one call instead of reading
      # a baked config file.
      #
      # Only atlases whose project is discoverable are served (the same
      # visibility rule the rest of the public API enforces); an unknown or
      # non-discoverable slug returns 404. Unlike the admin
      # GET /core_data/sites/:id/config endpoint (authenticated, addressed by
      # id, used by the build pipeline), this is unauthenticated and addressed
      # by the slug the renderer already has from the request.
      class AtlasesController < ApplicationController
        include UnauthenticateableController
        include DiscoverableProjectScope

        def show
          site = Site.find_by(slug: params[:slug])

          return head :not_found unless site&.project&.discoverable?

          config = site.to_site_config
          default_locale = config.dig('i18n', 'default_locale') || 'en'

          render json: {
            atlas: {
              slug: site.slug,
              config:,
              branding: site.to_branding,
              navigation: site.to_navigation(default_locale)
            }
          }, status: :ok
        end
      end
    end
  end
end
