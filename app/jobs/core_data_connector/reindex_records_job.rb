module CoreDataConnector
  # Reindexes a few records of one project in the background: the places a
  # curator just put on the map (UnlocatedPlacesController#locate). Indexing a
  # newly located place looks its administrative area up on GeoNames, about
  # one place a second, too slow to wait for in the request. Takes the same
  # per-project lock as ReindexAtlasJob, so it never races a full reindex on
  # the lower engine's GeoNames cache.
  class ReindexRecordsJob < ApplicationJob
    def perform(project_id, model_class, ids)
      ReindexAtlasJob.with_project_lock(project_id) do
        ::OpenGeographiesPlatform::Indexing.reindex_records(model_class.constantize, ids)
      end
    rescue StandardError => error
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
