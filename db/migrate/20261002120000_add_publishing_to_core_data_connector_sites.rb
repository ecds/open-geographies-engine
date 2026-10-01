# An atlas is private until its curator publishes it: `published` gates the
# public atlas-by-slug endpoint, and `preview_token` lets the curator (and
# whoever they share the link with) see a draft. Atlases that exist when this
# runs were already public, so they stay published; new ones start as drafts.
class AddPublishingToCoreDataConnectorSites < ActiveRecord::Migration[8.1]
  def up
    add_column :core_data_connector_sites, :published, :boolean, default: false, null: false
    add_column :core_data_connector_sites, :preview_token, :string
    add_index :core_data_connector_sites, :preview_token, unique: true

    # Tokens made in SQL so none is written to the migration log.
    execute <<~SQL
      UPDATE core_data_connector_sites
         SET published = TRUE,
             preview_token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
    SQL
  end

  def down
    remove_index :core_data_connector_sites, :preview_token
    remove_column :core_data_connector_sites, :preview_token
    remove_column :core_data_connector_sites, :published
  end
end
