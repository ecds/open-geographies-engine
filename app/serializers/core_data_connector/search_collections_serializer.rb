module CoreDataConnector
  class SearchCollectionsSerializer < BaseSerializer
    index_attributes :id, :project_id, :name, :project_model_ids, :polygons, :facet_field_uuids, :search_only_key,
                     :auto_index, :last_indexed_at, :created_at, :updated_at

    show_attributes :id, :project_id, :name, :project_model_ids, :polygons, :facet_field_uuids, :search_only_key,
                    :auto_index, :last_indexed_at, :created_at, :updated_at
  end
end
