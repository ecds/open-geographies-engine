# An atlas's history: every save of its content (home page, pages,
# translations), branding, menu and settings keeps a version — a snapshot of
# those parts as saved, who saved it, how (the console, a restore, an import,
# a tile build) and which parts changed. Changes to what only owners decide
# (published, the slug, the domain) are recorded with the version as events;
# a restore never changes them. The last 100 versions of each atlas are kept
# (and its first). Versions go with their atlas.
class CreateCoreDataConnectorSiteVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_connector_site_versions do |t|
      t.references :site, null: false, foreign_key: { to_table: :core_data_connector_sites, on_delete: :cascade }
      t.bigint :project_id, null: false
      t.references :user, foreign_key: { to_table: :core_data_connector_users, on_delete: :nullify }
      t.string :source, null: false
      t.jsonb :changed_parts, null: false, default: []
      t.jsonb :events, null: false, default: {}
      t.jsonb :snapshot, null: false, default: {}
      t.bigint :restored_from_id
      t.datetime :created_at, null: false
    end

    add_index :core_data_connector_site_versions, [:site_id, :id]
    add_index :core_data_connector_site_versions, :project_id
  end
end
