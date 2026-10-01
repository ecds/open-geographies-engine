module CoreDataConnector
  class SitesSerializer < BaseSerializer
    index_attributes :id, :project_id, :name, :slug, :published, :config, :area, :branding, :navigation,
                     :created_at, :updated_at

    # content is the editable pages document (SiteContent), with the starter
    # home page filled in when none has been saved, so the console always
    # opens on what the atlas is actually showing.
    # preview_token is the draft's shareable preview link; only the people
    # who can edit the atlas see it (the sites policy).
    show_attributes :id, :project_id, :name, :slug, :published, :preview_token, :config, :area, :branding, :navigation,
                    :created_at, :updated_at, content: ->(site, *) { site.to_content }
  end
end
