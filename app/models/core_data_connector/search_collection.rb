require 'typesense/search'

module CoreDataConnector
  # A search collection maps a project's records (by project model) onto a
  # Typesense collection. It is the unit of configuration for automated
  # indexing: a full reindex can be queued per collection, and saving a record
  # belonging to one of its project models incrementally updates the index.
  #
  # Typesense connection settings come from the deployment environment
  # (TYPESENSE_HOST / TYPESENSE_PORT / TYPESENSE_PROTOCOL / TYPESENSE_API_KEY),
  # so per-collection records carry only publishing choices.
  class SearchCollection < ApplicationRecord
    # Relationships
    belongs_to :project

    # Validations
    validates :name, presence: true, uniqueness: true,
                     format: { with: /\A[a-z0-9_]+\z/, message: 'only lowercase letters, numbers, and underscores' }
    validates :project_model_ids, presence: true
    validate :validate_project_models

    def self.permitted_params
      [:project_id, :name, :polygons, :auto_index, project_model_ids: [], facet_field_uuids: []]
    end

    # Returns the search collections covering the passed project model ID.
    def self.covering_project_model(project_model_id)
      where('project_model_ids @> ?', [project_model_id.to_i].to_json)
    end

    def typesense_search
      ::Typesense::Search.new(**self.class.typesense_connection, collection_name: name)
    end

    # Creates a Typesense API key scoped to this collection only, so public
    # sites never need the admin key: documents:search plus collections:get
    # (the frontend's facet provider fetches the collection schema, which
    # 401s under a search-only scope). Typesense returns the full key value
    # only at creation time; we store it so the console can display it.
    # Issuing again revokes any previously stored key.
    def issue_search_only_key!
      client = typesense_search.client

      revoke_search_only_key!(client)

      key = client.keys.create(
        'description' => "Search-only key for collection #{name}",
        'actions' => ['documents:search', 'collections:get'],
        'collections' => [name]
      )

      update!(search_only_key: key['value'], search_only_key_id: key['id'])

      key['value']
    end

    private

    def revoke_search_only_key!(client)
      return if search_only_key_id.nil?

      begin
        client.keys[search_only_key_id].delete
      rescue StandardError
        # Key already gone (e.g. Typesense reset); nothing to revoke.
      end
    end

    public

    def self.typesense_connection
      {
        host: ENV.fetch('TYPESENSE_HOST', 'localhost'),
        port: ENV.fetch('TYPESENSE_PORT', 8108).to_i,
        protocol: ENV.fetch('TYPESENSE_PROTOCOL', 'http'),
        api_key: ENV.fetch('TYPESENSE_API_KEY', nil)
      }
    end

    private

    # All referenced project models must belong to this collection's project.
    def validate_project_models
      return if project_id.nil? || project_model_ids.blank?

      valid_ids = ProjectModel.where(project_id:).pluck(:id)
      invalid = project_model_ids.map(&:to_i) - valid_ids

      errors.add(:project_model_ids, "contains models not in this project: #{invalid.join(', ')}") if invalid.any?
    end
  end
end
