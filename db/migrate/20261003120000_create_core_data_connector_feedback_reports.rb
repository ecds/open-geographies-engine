# What curators send with "Send feedback" in the atlas console: what happened,
# what they expected, the page and atlas it was about, and an optional
# screenshot (an Active Storage attachment). Kept here for the platform's
# admins and, when OG_FEEDBACK_EMAIL is set, emailed as well. A report
# outlives its atlas, its project and its sender's account (the references
# are cleared, the report stays).
class CreateCoreDataConnectorFeedbackReports < ActiveRecord::Migration[8.1]
  def change
    create_table :core_data_connector_feedback_reports do |t|
      t.references :user, foreign_key: { to_table: :core_data_connector_users, on_delete: :nullify }
      t.references :project, foreign_key: { to_table: :core_data_connector_projects, on_delete: :nullify }
      t.references :site, foreign_key: { to_table: :core_data_connector_sites, on_delete: :nullify }
      t.string :page_url, limit: 2000
      t.text :what_happened, null: false
      t.text :expected
      t.jsonb :context, null: false, default: {}
      t.string :status, null: false, default: 'new'
      t.datetime :resolved_at
      t.bigint :resolved_by_id
      t.datetime :emailed_at
      t.string :email_error, limit: 500
      t.timestamps
    end

    add_index :core_data_connector_feedback_reports, [:status, :created_at]
    add_index :core_data_connector_feedback_reports, [:user_id, :created_at]
  end
end
