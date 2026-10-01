module CoreDataConnector
  # Reindexes an atlas's records into the shared v1 search index — the
  # coalesced reindex that follows a bulk write (imports suspend per-record
  # indexing for the duration), or a console-requested rebuild.
  #
  # Scoped, never global: the index is shared across every atlas, so this job
  # only ever touches the records of the project models it is given
  # (extra.project_model_ids), defaulting to all of the job's project's models.
  # Progress lands on the Job row (extra.progress) for the console.
  #
  # Reindexes of one project run one at a time (a Postgres advisory lock
  # keyed on the project): two imports in quick succession each queue one,
  # and run side by side they write the same records' derived rows (the
  # lower engine's GeoNames hierarchy cache is unique per place) and the
  # loser fails. A queued reindex waits in "initializing" until the one
  # ahead of it finishes, then covers every record written since.
  class ReindexAtlasJob < ApplicationJob
    PROGRESS_INTERVAL = 2.seconds

    # Advisory lock namespace ("OG"), paired with the project id.
    LOCK_NAMESPACE = 0x4F47

    def perform(job_id)
      job = Job.find(job_id)

      self.class.with_project_lock(job.project_id) { reindex(job) }
    end

    # Runs the block holding the project's reindex lock (shared with
    # ReindexRecordsJob).
    def self.with_project_lock(project_id)
      connection = ActiveRecord::Base.connection
      connection.execute("SELECT pg_advisory_lock(#{LOCK_NAMESPACE}, #{project_id.to_i})")
      yield
    ensure
      connection&.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{project_id.to_i})")
    end

    private

    def reindex(job)
      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        project_models = project_models_for(job)
        last_reported_at = nil

        reindexed = ::OpenGeographiesPlatform::Indexing.reindex_project_models(project_models) do |completed, total|
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
