# Open Geographies engine migration (additive — creates a NEW table only).
#
# Squashed from the fork's original 7 sites migrations into the FINAL shape — the
# retired deploy-pipeline columns (deploy_adapter, deploy_config, netlify_token,
# content_repo_*, deploy_key_*, webhook_secret, auto_rebuild) were added then dropped
# on the fork; the engine never creates them. Installs onto a clean upstream Core
# Data via `rails open_geographies:install:migrations`.
class CreateCoreDataConnectorSites < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_connector_sites do |t|
      t.references :project, null: false
      t.string :name, null: false
      t.string :slug, null: false
      t.jsonb :config, default: {}
      t.jsonb :area
      t.jsonb :branding, default: {}
      t.jsonb :navigation, default: {}
      t.timestamps
    end

    add_index :core_data_connector_sites, :slug, unique: true
  end
end
