module CoreDataConnector
  class SitesSerializer < BaseSerializer
    index_attributes :id, :project_id, :name, :slug, :config, :area, :branding, :navigation,
                     :created_at, :updated_at

    show_attributes :id, :project_id, :name, :slug, :config, :area, :branding, :navigation,
                    :created_at, :updated_at
  end
end
