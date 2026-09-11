# The per-atlas search-only API key was a Typesense-era artifact: every atlas
# now searches one shared Elasticsearch index through the renderer's
# server-side handler, so nothing issues or reads these columns. Dropped
# (Jay's read of the model, 2026-09-11: keep SearchCollection, lose the key).
class DropSearchOnlyKeyFromSearchCollections < ActiveRecord::Migration[8.1]
  def change
    remove_column :core_data_connector_search_collections, :search_only_key, :string
    remove_column :core_data_connector_search_collections, :search_only_key_id, :integer
  end
end
