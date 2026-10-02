module CoreDataConnector
  class SitesSerializer < BaseSerializer
    # public_url is the atlas's address: its connected domain, else its
    # address on the platform (Site#public_url), so console links follow
    # the domain.
    index_attributes :id, :project_id, :name, :slug, :published, :config, :area, :branding, :navigation,
                     :domain, :created_at, :updated_at,
                     domain_status: ->(site, *) { site.domain_status },
                     public_url: ->(site, *) { site.public_url }

    # content is the editable pages document (SiteContent), with the starter
    # home page filled in when none has been saved, so the console always
    # opens on what the atlas is actually showing.
    # preview_token is the draft's shareable preview link; only the people
    # who can edit the atlas see it (the sites policy).
    # domain_dns is what the domain's DNS needs to connect it (SiteDomains).
    show_attributes :id, :project_id, :name, :slug, :published, :preview_token, :config, :area, :branding, :navigation,
                    :domain, :created_at, :updated_at,
                    content: ->(site, *) { site.to_content },
                    domain_status: ->(site, *) { site.domain_status },
                    domain_dns: ->(site, *) { SiteDomains.instructions(site.domain, site.slug) },
                    public_url: ->(site, *) { site.public_url },
                    platform_url: ->(site, *) { site.platform_url },
                    # The FairData project the atlas's records live in (they
                    # stay there if the atlas is deleted).
                    project_name: ->(site, *) { site.project&.name }
  end
end
