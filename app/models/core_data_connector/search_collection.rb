module CoreDataConnector
  # A search collection groups a project's records (by project model) as a
  # unit of search configuration for the console: which models an atlas
  # searches over, whether polygons are indexed, and which user-defined fields
  # are offered as facets. It also carries last_indexed_at for the console's
  # index status.
  #
  # It no longer owns an index. Records are written to the shared v1
  # Elasticsearch index by the lower-layer engine regardless of collections;
  # a collection's reindex action rebuilds just its project models' records
  # there (ReindexAtlasJob). Whether the model survives at all, now that there
  # is no per-atlas index to provision, is an open question with the lower
  # engine — the search_only_key columns are already unused.
  class SearchCollection < ApplicationRecord
    # Relationships
    belongs_to :project

    # Same reasoning as Site: the policy check precedes the update, so the
    # project must not be changeable after creation.
    attr_readonly :project_id

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
