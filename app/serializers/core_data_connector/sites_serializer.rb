module CoreDataConnector
  class SitesSerializer < BaseSerializer
    index_attributes :id, :project_id, :name, :slug, :config, :area, :branding, :navigation,
                     :created_at, :updated_at

    # content is the editable pages document (SiteContent), with the starter
    # home page filled in when none has been saved, so the console always
    # opens on what the atlas is actually showing.
    show_attributes :id, :project_id, :name, :slug, :config, :area, :branding, :navigation,
                    :created_at, :updated_at, content: ->(site, *) { site.to_content }
  end
end
