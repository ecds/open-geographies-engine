# An atlas's own pages: the home page and standalone pages such as About, as
# the console edits them ({ home: {...}, pages: [...] }; see
# CoreDataConnector::SiteContent). Additive; images the pages use are
# ActiveStorage attachments on the site, which need no column.
class AddContentToCoreDataConnectorSites < ActiveRecord::Migration[8.1]
  def change
    add_column :core_data_connector_sites, :content, :jsonb, default: {}
  end
end
