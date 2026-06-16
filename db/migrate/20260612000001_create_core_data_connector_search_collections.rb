# Open Geographies engine migration (additive — creates a NEW table only).
#
# Squashed from the fork's original pair (create + add_search_only_key) into the
# final shape. Installs onto a clean upstream Core Data via
# `rails open_geographies:install:migrations`.
class CreateCoreDataConnectorSearchCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_connector_search_collections do |t|
      t.references :project, null: false
      t.string :name, null: false
      t.jsonb :project_model_ids, default: []
      t.boolean :polygons, default: true
      t.jsonb :facet_field_uuids, default: []
      t.boolean :auto_index, default: true
      t.datetime :last_indexed_at
      t.string :search_only_key
      t.integer :search_only_key_id
      t.timestamps
    end

    add_index :core_data_connector_search_collections, :name, unique: true
  end
end
