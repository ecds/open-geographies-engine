module CoreDataConnector
  # Incrementally updates a single record's document in every search
  # collection that covers its project model. Queued on record save by
  # Search::AutoIndexable.
  class IndexRecordJob < ApplicationJob

    def perform(record_type, record_id)
      record = record_type.constantize.find_by(id: record_id)
      return if record.nil? || record.project_model_id.nil?

      SearchCollection
        .covering_project_model(record.project_model_id)
        .where(auto_index: true)
        .each do |search_collection|
          search_collection.typesense_search.index_record(
            record,
            polygons: search_collection.polygons,
            facet_field_uuids: search_collection.facet_field_uuids
          )
        end
    end
  end
end
