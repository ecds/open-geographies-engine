module CoreDataConnector
  # Reindexes an atlas's records into the shared v1 search index — the
  # coalesced reindex that follows a bulk write (imports suspend per-record
  # indexing for the duration), or a console-requested rebuild.
  #
  # Scoped, never global: the index is shared across every atlas, so this job
  # only ever touches the records of the project models it is given
  # (extra.project_model_ids), defaulting to all of the job's project's models.
  # Progress lands on the Job row (extra.progress) for the console.
  class ReindexAtlasJob < ApplicationJob
    PROGRESS_INTERVAL = 2.seconds

    def perform(job_id)
      job = Job.find(job_id)

      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        project_models = project_models_for(job)
        last_reported_at = nil

        reindexed = ::OpenGeographies::Indexing.reindex_project_models(project_models) do |completed, total|
          now = Time.current

          if last_reported_at.nil? || now - last_reported_at >= PROGRESS_INTERVAL || completed >= total
            job.update_columns(
              extra: job.extra.merge('progress' => { 'completed' => completed, 'total' => total }),
              updated_at: now
            )

            last_reported_at = now
          end
        end

        SearchCollection.where(project_id: job.project_id).update_all(last_indexed_at: Time.current)

        job.update(
          status: Job::JOB_STATUS_COMPLETED,
          extra: job.extra.merge('documents' => reindexed)
        )
      rescue StandardError => error
        log_error error

        job.update(
          status: Job::JOB_STATUS_FAILED,
          extra: job.extra.merge('error' => error.message.truncate(1000))
        )
      end
    end

    private

    def project_models_for(job)
      scope = ProjectModel.where(project_id: job.project_id)
      ids = Array(job.extra['project_model_ids']).map(&:to_i)

      ids.any? ? scope.where(id: ids).to_a : scope.to_a
    end

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
