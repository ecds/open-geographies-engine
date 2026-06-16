module CoreDataConnector
  # Provisions everything a wizard-created atlas needs beyond its database
  # records (those are created synchronously by AtlasesController so validation
  # errors return immediately): the Typesense collection and its search-only
  # key.
  #
  # Once those exist the atlas is LIVE on the shared dynamic renderer
  # (core-data-places) — the renderer resolves the site's config / branding /
  # navigation from the console per request
  # (GET /core_data/public/v1/atlases/:slug), so there is no content repository
  # to scaffold and no static build/deploy step. Place data flows into the
  # (initially empty) collection via import / on-save auto-indexing.
  #
  # The current stage is recorded on the Job row (extra.stage) so the wizard can
  # show progress; a failure records extra.failed_stage. Re-running is safe: the
  # search index is recreated from scratch (empty at this point).
  class ProvisionAtlasJob < ApplicationJob

    def perform(job_id)
      job = Job.find(job_id)
      search_collection = SearchCollection.find(job.extra['search_collection_id'])

      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        stage job, 'search_index'
        create_search_index search_collection

        job.update(status: Job::JOB_STATUS_COMPLETED)
      rescue StandardError => error
        log_error error

        job.update(
          status: Job::JOB_STATUS_FAILED,
          extra: job.extra.merge(
            'error' => error.message.truncate(1000),
            'failed_stage' => job.extra['stage']
          )
        )
      end
    end

    private

    # Creates the (empty) Typesense collection and issues its search-only key —
    # the same drop/create a reindex performs, with nothing to import yet. The
    # key must exist before the atlas serves search: the emitted site config
    # embeds it.
    def create_search_index(search_collection)
      search = search_collection.typesense_search

      begin
        search.delete
      rescue StandardError
        # No existing collection.
      end

      search.create

      search_collection.issue_search_only_key!
      search_collection.update(last_indexed_at: Time.current)
    end

    def stage(job, name)
      job.update_columns(
        extra: job.extra.merge('stage' => name),
        updated_at: Time.current
      )
    end

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
