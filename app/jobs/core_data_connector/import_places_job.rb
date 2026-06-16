module CoreDataConnector
  # Bulk-imports places from a geographic authority (GeoNames/Wikidata) for
  # the area + filters in the job's extra document. Each new record becomes
  # a Place (primary name + point geometry) with a web_identifier back to
  # the authority — provenance that also makes re-runs idempotent: records
  # whose identifier already exists in the project are skipped, so the same
  # import can be re-run later with an expanded area or new filters.
  #
  # Follows ImportCsvJob's bulk pattern: incremental indexing is suspended
  # for the duration and the affected search collections are fully
  # reindexed afterwards. Progress lands on the Job row (extra.progress).
  #
  # extra: { web_authority_id:, project_model_id:, source:, area: {...},
  #          filters: {...} }
  class ImportPlacesJob < ApplicationJob
    PROGRESS_INTERVAL = 2.seconds

    # Records imported this run get a light duplicate check against
    # pre-existing places (same primary name within ~100m, e.g. the same POI
    # already imported from another authority); pairs are reported on the
    # job, not merged.
    DUPLICATE_DISTANCE_METERS = 100
    DUPLICATE_SAMPLE_LIMIT = 20

    def perform(job_id)
      job = Job.find(job_id)
      web_authority = WebAuthority.find(job.extra['web_authority_id'])
      project_model = ProjectModel.find(job.extra['project_model_id'])

      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        source = PlaceImports::Sources.for(
          web_authority,
          area: job.extra['area'],
          filters: job.extra['filters']
        )

        counts = { 'imported' => 0, 'skipped' => 0, 'outside_area' => 0, 'failed' => 0 }
        error_samples = []
        imported_place_ids = []
        processed = 0
        total = nil
        last_reported_at = nil

        Search::AutoIndexable.disable do
          total = source.count

          source.each_record do |record|
            if record['in_area']
              begin
                result, place_id = import_record(web_authority, project_model, record)

                counts[result.to_s] += 1
                imported_place_ids << place_id if place_id
              rescue StandardError => error
                counts['failed'] += 1
                error_samples << "#{record['identifier']}: #{error.message}" if error_samples.length < 20
              end
            else
              counts['outside_area'] += 1
            end

            processed += 1
            now = Time.current

            if last_reported_at.nil? || now - last_reported_at >= PROGRESS_INTERVAL
              job.update_columns(
                extra: job.extra.merge('progress' => { 'completed' => processed, 'total' => total }),
                updated_at: now
              )

              last_reported_at = now
            end
          end
        end

        queue_reindexes job, project_model

        job.update(
          status: Job::JOB_STATUS_COMPLETED,
          extra: job.extra.merge(
            'progress' => { 'completed' => processed, 'total' => processed },
            'counts' => counts,
            'errors_sample' => error_samples.presence,
            'warnings' => source.warnings.presence,
            'duplicates' => duplicate_report(imported_place_ids)
          ).compact
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

    # Returns [:skipped] when the identifier is already in the project, or
    # [:imported, place_id].
    def import_record(web_authority, project_model, record)
      identifier = record['identifier'].to_s

      return [:skipped] if WebIdentifier.exists?(web_authority_id: web_authority.id, identifier:)

      place = nil

      ActiveRecord::Base.transaction do
        place = Place.new(project_model_id: project_model.id)
        place.place_names.build(name: record['name'], primary: true)
        place.save!

        PlaceGeometry.create!(
          place:,
          geometry_json: { type: 'Point', coordinates: [record['longitude'], record['latitude']] }.to_json
        )

        WebIdentifier.create!(
          web_authority:,
          identifiable: place,
          identifier:,
          extra: record['extra'].presence
        )
      end

      [:imported, place.id]
    end

    # Full reindex of the collections covering the imported model, replacing
    # the suspended incremental indexing (ImportCsvJob pattern).
    def queue_reindexes(job, project_model)
      SearchCollection
        .covering_project_model(project_model.id)
        .where(project_id: job.project_id, auto_index: true)
        .find_each do |search_collection|
        Job.create(
          project_id: job.project_id,
          user_id: job.user_id,
          job_type: Job::JOB_TYPE_REINDEX,
          extra: {
            search_collection_id: search_collection.id,
            search_collection_name: search_collection.name
          }
        )
      end
    end

    def duplicate_report(imported_place_ids)
      # Bound the check: an enormous import samples its first slice rather
      # than running an unbounded spatial self-join. The ids are integers
      # from this run's own inserts, so inlining them is safe.
      ids = imported_place_ids.first(2000).map(&:to_i)
      return nil if ids.empty?

      id_list = ids.join(',')

      rows = ActiveRecord::Base.connection.exec_query(<<~SQL, 'place_import_duplicates')
        SELECT pn1.name, p1.id AS imported_id, p2.id AS existing_id
        FROM core_data_connector_places p1
        JOIN core_data_connector_place_names pn1
          ON pn1.place_id = p1.id AND pn1."primary"
        JOIN core_data_connector_place_geometries g1
          ON g1.place_id = p1.id
        JOIN core_data_connector_places p2
          ON p2.project_model_id = p1.project_model_id
         AND p2.id NOT IN (#{id_list})
        JOIN core_data_connector_place_names pn2
          ON pn2.place_id = p2.id AND pn2."primary"
         AND lower(pn2.name) = lower(pn1.name)
        JOIN core_data_connector_place_geometries g2
          ON g2.place_id = p2.id
        WHERE p1.id IN (#{id_list})
          AND ST_DWithin(g1.geometry::geography, g2.geometry::geography, #{DUPLICATE_DISTANCE_METERS})
        LIMIT #{DUPLICATE_SAMPLE_LIMIT + 1}
      SQL

      return nil if rows.empty?

      {
        'sample' => rows.to_a.first(DUPLICATE_SAMPLE_LIMIT),
        'more' => rows.length > DUPLICATE_SAMPLE_LIMIT
      }
    end

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
