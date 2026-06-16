module CoreDataConnector
  # Removes a deleted record's document from every search collection that
  # covered its project model. Queued on record destroy by
  # Search::AutoIndexable (the uuid and project_model_id are captured before
  # the row is gone).
  class RemoveRecordJob < ApplicationJob

    def perform(uuid, project_model_id)
      SearchCollection
        .covering_project_model(project_model_id)
        .where(auto_index: true)
        .each do |search_collection|
          search_collection.typesense_search.remove_record(uuid)
        end
    end
  end
end
