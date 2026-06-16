module CoreDataConnector
  # Rebuilds a search collection from scratch: drop, create, full import,
  # facet/geopoint fixup. Progress and outcome are tracked on the Job row so
  # the console can display index status.
  class ReindexSearchCollectionJob < ApplicationJob

    def perform(job_id)
      job = Job.find(job_id)
      search_collection = SearchCollection.find(job.extra['search_collection_id'])

      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        search = search_collection.typesense_search

        begin
          search.delete
        rescue StandardError
          # No existing collection.
        end

        search.create

        # Report progress on the job row (throttled) so the console can show
        # records-done / total while the reindex runs.
        last_reported_at = nil

        search.index(
          project_model_ids: search_collection.project_model_ids,
          polygons: search_collection.polygons,
          facet_field_uuids: search_collection.facet_field_uuids
        ) do |completed, total|
          now = Time.current

          if last_reported_at.nil? || now - last_reported_at >= 2.seconds || completed >= total
            job.update_columns(
              extra: job.extra.merge('progress' => { 'completed' => completed, 'total' => total }),
              updated_at: now
            )

            last_reported_at = now
          end
        end

        search.update

        documents = search
                      .client
                      .collections[search_collection.name]
                      .retrieve['num_documents']

        search_collection.update(last_indexed_at: Time.current)

        job.update(
          status: Job::JOB_STATUS_COMPLETED,
          extra: job.extra.merge('documents' => documents)
        )
      rescue StandardError => error
        log_error error

        job.update(
          status: Job::JOB_STATUS_FAILED,
          extra: job.extra.merge('error' => error.message)
        )
      end
    end

    private

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
