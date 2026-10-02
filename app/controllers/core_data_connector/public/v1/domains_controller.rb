module CoreDataConnector
  module Public
    module V1
      # GET /core_data/public/v1/domains/allowed?domain=atlas.example.org
      #
      # 200 when `domain` is an address this platform serves an atlas at — a
      # connected custom domain (SiteDomains) or an atlas's platform address
      # (<slug>.<base domain>) — else 404. The shape of Caddy's on-demand TLS
      # `ask` check, so the proxy in front of the renderer gets a
      # certificate for an atlas's domain the first time it's visited, and
      # never for a name nobody connected. Drafts count: their preview links
      # need a certificate too. Says nothing a DNS lookup of the domain
      # doesn't already.
      class DomainsController < ApplicationController
        include UnauthenticateableController

        def allowed
          domain = SiteDomains.normalize(params[:domain])

          head(domain && served?(domain) ? :ok : :not_found)
        end

        private

        def served?(domain)
          return true if Site.where.not(domain_verified_at: nil).exists?(domain:)

          base = SiteDomains.base_domain
          return false unless base && domain.end_with?(".#{base}")

          slug = domain.delete_suffix(".#{base}")
          !slug.include?('.') && Site.exists?(slug:)
        end
      end
    end
  end
end
