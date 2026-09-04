module CoreDataConnector
  # Provisions what a wizard-created atlas needs beyond its database records
  # (those are created synchronously by AtlasesController so validation errors
  # return immediately): the search index.
  #
  # There is no per-atlas index. Records are written to the shared v1
  # Elasticsearch index by the lower-layer engine on every save, so the one
  # thing provisioning must guarantee is that the index EXISTS WITH ITS MAPPING
  # before the curator's first save: a single-record write into a missing index
  # lets Elasticsearch auto-create it with dynamic mapping, which silently breaks
  # keyword exact-match fields (slug, types, ...). Creation is mapping-aware and
  # idempotent, so re-running is safe.
  #
  # Once that holds the atlas is LIVE on the shared dynamic renderer
  # (core-data-places), which resolves the site's config / branding / navigation
  # from the console per request (GET /core_data/public/v1/atlases/:slug) — no
  # content repository, no build, no deploy. The current stage is recorded on
  # the Job row (extra.stage) so the wizard can show progress; a failure records
  # extra.failed_stage.
  class ProvisionAtlasJob < ApplicationJob

    def perform(job_id)
      job = Job.find(job_id)

      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        stage job, 'search_index'
        ensure_search_index job

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

    def ensure_search_index(job)
      project_models = ProjectModel.where(project_id: job.project_id).to_a

      ::OpenGeographies::Indexing.ensure_index!(project_models)

      SearchCollection.where(project_id: job.project_id).update_all(last_indexed_at: Time.current)
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
