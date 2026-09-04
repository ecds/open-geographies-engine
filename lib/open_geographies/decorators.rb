# On-save indexing wraps the connector's Typesense client (lib/typesense, not
# autoloaded). The merged core-data-cloud / FairData host no longer ships
# lib/typesense/search.rb, so the require is optional: without it the Typesense
# decorators below simply aren't applied. Typesense indexing is being retired
# outright in favour of the v1 Elasticsearch index (see the v1 integration handoff);
# this guard only keeps the engine bootable until that removal lands.
begin
  require 'typesense/search'
rescue LoadError
  nil
end

module OpenGeographies
  # Applies Open Geographies' in-place extensions to upstream Core Data classes —
  # the OG-coupled subset of the changes the fork used to make directly to upstream
  # files. Each is a reopen (additive include / new methods) or a prepend
  # (behavioral override). Applied inside the engine's `config.to_prepare` so they
  # re-apply after Zeitwerk reloads in development (each reload yields a fresh
  # upstream class, so includes/callbacks land exactly once).
  #
  # The GENERAL, non-OG changes (the discoverable gate, GeometryCollection
  # flattening, and search/base's orphaned-relationship guard + per-index facet
  # opt-in) are NOT here — they carry on the connector mirror as thin, upstream-
  # bound commits, because (a) they reference no OG model and (b) the gate's
  # `base_query` edit can't be expressed as a clean prepend (it calls `super` into
  # NestableController). See the connector `og/connector-base` overlay.
  module Decorators
    # Models that gain on-save Typesense indexing. Each `include Search::<Model>`,
    # which pulls in Search::Base. Upstream Search::Base does NOT include
    # AutoIndexable (that concern is OG-specific — it depends on SearchCollection),
    # so the engine adds it to each searchable model here.
    SEARCHABLE_MODELS = %w[
      Event Instance Item MediaContent Organization Person Place Taxonomy Work
    ].freeze

    # Nested records whose changes must reindex their parent searchable record(s).
    NESTED_AUTO_REINDEXERS = {
      'CoreDataConnector::PlaceGeometry' => %i[place],
      'CoreDataConnector::PlaceName' => %i[place],
      'CoreDataConnector::Relationship' => %i[primary_record related_record]
    }.freeze

    def self.apply!
      wire_auto_indexing!
      wire_nested_auto_indexing!
      wire_job_dispatch!
      wire_job_policy!
      wire_import_csv_job!
      wire_authority_bulk!
      wire_typesense_records!
    end

    # Search::Base#included → (OG) include AutoIndexable, per searchable model.
    def self.wire_auto_indexing!
      auto_indexable = CoreDataConnector::Search::AutoIndexable

      SEARCHABLE_MODELS.each do |name|
        model = "CoreDataConnector::#{name}".constantize
        model.include(auto_indexable) unless model.include?(auto_indexable)
      end
    end

    # PlaceGeometry/PlaceName/Relationship → AutoIndexable::Nested + auto_reindexes.
    def self.wire_nested_auto_indexing!
      nested = CoreDataConnector::Search::AutoIndexable::Nested

      NESTED_AUTO_REINDEXERS.each do |name, parents|
        model = name.constantize
        next if model.include?(nested)

        model.include(nested)
        model.auto_reindexes(*parents)
      end
    end

    # Job → the OG job types + their after_create_commit dispatch.
    def self.wire_job_dispatch!
      job = CoreDataConnector::Job
      job.include(OpenGeographies::JobDispatch) unless job.include?(OpenGeographies::JobDispatch)
    end

    # JobPolicy → project members can view their own jobs (wizard polling).
    def self.wire_job_policy!
      policy = CoreDataConnector::JobPolicy
      policy.prepend(OpenGeographies::JobPolicyDecorator) unless policy.include?(OpenGeographies::JobPolicyDecorator)

      scope = CoreDataConnector::JobPolicy::Scope
      scope.prepend(OpenGeographies::JobPolicyScopeDecorator) unless scope.include?(OpenGeographies::JobPolicyScopeDecorator)
    end

    # ImportCsvJob → suspend on-save indexing during the bulk import, then queue a
    # single full reindex per auto-indexed search collection.
    def self.wire_import_csv_job!
      job = CoreDataConnector::ImportCsvJob
      job.prepend(OpenGeographies::ImportCsvJobDecorator) unless job.include?(OpenGeographies::ImportCsvJobDecorator)
    end

    # GeoNames/Wikidata → area-scoped bulk-import methods.
    def self.wire_authority_bulk!
      geonames = CoreDataConnector::Authority::Geonames
      geonames.include(OpenGeographies::GeonamesBulk) unless geonames.include?(OpenGeographies::GeonamesBulk)

      wikidata = CoreDataConnector::Authority::Wikidata
      wikidata.include(OpenGeographies::WikidataBulk) unless wikidata.include?(OpenGeographies::WikidataBulk)
    end

    # Typesense::Search → single-record upsert/remove (on-save indexing) + an
    # optional progress callback on full index runs.
    def self.wire_typesense_records!
      # Absent on the merged FairData host (see the require guard at the top).
      return unless defined?(::Typesense::Search)

      search = Typesense::Search
      search.include(OpenGeographies::TypesenseSearchRecords) unless search.include?(OpenGeographies::TypesenseSearchRecords)
      search.prepend(OpenGeographies::TypesenseSearchProgress) unless search.include?(OpenGeographies::TypesenseSearchProgress)
    end
  end

  # --- Job dispatch (reopen) ------------------------------------------------

  module JobDispatch
    extend ActiveSupport::Concern

    JOB_TYPE_REINDEX = 'reindex'
    JOB_TYPE_BUILD_TILES = 'build_tiles'
    JOB_TYPE_PROVISION_ATLAS = 'provision_atlas'
    JOB_TYPE_IMPORT_PLACES = 'import_places'

    included do
      after_create_commit :queue_reindex_job, if: :reindex?
      after_create_commit :queue_build_tiles_job, if: :build_tiles?
      after_create_commit :queue_provision_atlas_job, if: :provision_atlas?
      after_create_commit :queue_import_places_job, if: :import_places?
    end

    def reindex?
      job_type == JOB_TYPE_REINDEX
    end

    def build_tiles?
      job_type == JOB_TYPE_BUILD_TILES
    end

    def provision_atlas?
      job_type == JOB_TYPE_PROVISION_ATLAS
    end

    def import_places?
      job_type == JOB_TYPE_IMPORT_PLACES
    end

    private

    def queue_reindex_job
      CoreDataConnector::ReindexSearchCollectionJob.perform_later(id)
    end

    def queue_build_tiles_job
      CoreDataConnector::BuildTilesJob.perform_later(id)
    end

    def queue_provision_atlas_job
      CoreDataConnector::ProvisionAtlasJob.perform_later(id)
    end

    def queue_import_places_job
      CoreDataConnector::ImportPlacesJob.perform_later(id)
    end
  end

  # --- Job policy (prepend override) ----------------------------------------

  module JobPolicyDecorator
    # Members of a job's project can view it: the atlas wizard polls its provision
    # and import jobs as the (non-admin) project owner.
    def show?
      return true if current_user.admin?

      member?
    end

    private

    def member?
      current_user
        .user_projects
        .where(project_id: job.project_id)
        .exists?
    end
  end

  module JobPolicyScopeDecorator
    # Admin users can view all jobs, other users the jobs of their projects.
    def resolve
      return scope.all if current_user.admin?

      scope.where(
        project_id: current_user.user_projects.select(:project_id)
      )
    end
  end

  # --- Import CSV job (prepend override) ------------------------------------

  module ImportCsvJobDecorator
    # Suspend on-save incremental indexing for the bulk import (per-record
    # IndexRecordJobs would flood the queue and re-serialize relationship graphs
    # thousands of times), then queue a single full reindex per affected search
    # collection.
    def perform(id)
      CoreDataConnector::Search::AutoIndexable.disable { super }

      job = CoreDataConnector::Job.find_by(id:)
      queue_reindexes(job) if job&.status == CoreDataConnector::Job::JOB_STATUS_COMPLETED
    end

    private

    def queue_reindexes(job)
      CoreDataConnector::SearchCollection
        .where(project_id: job.project_id, auto_index: true)
        .find_each do |search_collection|
          CoreDataConnector::Job.create(
            project_id: job.project_id,
            user_id: job.user_id,
            job_type: CoreDataConnector::Job::JOB_TYPE_REINDEX,
            extra: {
              search_collection_id: search_collection.id,
              search_collection_name: search_collection.name
            }
          )
        end
    end
  end

  # --- Authority bulk imports (reopen) --------------------------------------

  module GeonamesBulk
    # Area-scoped search for bulk place imports. Accepts a bounding box
    # (options[:bbox] = { west:, south:, east:, north: }) or GeoNames admin codes
    # (options[:country], options[:admin_code1], options[:admin_code2]), optionally
    # narrowed by feature classes/codes and a name query. Paged via
    # options[:max_rows] (API ceiling 1000) and options[:start_row].
    #
    # featureClass/featureCode are repeated query keys (not arrays), so the query
    # string is built with encode_www_form rather than the params option.
    def search_area(options = {})
      pairs = [
        ['username', options[:username]],
        ['maxRows', options[:max_rows] || 100],
        ['startRow', options[:start_row] || 0]
      ]

      pairs << ['q', options[:q]] if options[:q].present?

      if (bbox = options[:bbox]).present?
        pairs << ['west', bbox[:west]]
        pairs << ['south', bbox[:south]]
        pairs << ['east', bbox[:east]]
        pairs << ['north', bbox[:north]]
      end

      pairs << ['country', options[:country]] if options[:country].present?
      pairs << ['adminCode1', options[:admin_code1]] if options[:admin_code1].present?
      pairs << ['adminCode2', options[:admin_code2]] if options[:admin_code2].present?

      Array(options[:feature_classes]).each { |feature_class| pairs << ['featureClass', feature_class] }
      Array(options[:feature_codes]).each { |feature_code| pairs << ['featureCode', feature_code] }

      send_request("#{self.class::BASE_URL}/searchJSON?#{URI.encode_www_form(pairs)}", method: :get) do |body|
        JSON.parse(body)
      end
    end

    # The direct children of an administrative unit (country -> ADM1 -> ADM2 ...),
    # for cascading admin-unit pickers.
    def admin_children(geoname_id, options = {})
      params = {
        geonameId: geoname_id,
        username: options[:username],
        maxRows: options[:max_rows] || 1000,
        # FULL includes adminCode1/adminCode2, which area searches need.
        style: 'FULL'
      }
      send_request("#{self.class::BASE_URL}/childrenJSON", method: :get, params:) do |body|
        JSON.parse(body)
      end
    end
  end

  module WikidataBulk
    SPARQL_URL = 'https://query.wikidata.org/sparql'

    # Executes a SPARQL query against the Wikidata Query Service. Used for
    # area-scoped bulk imports (geo box / containment queries), which the
    # wbsearchentities API cannot express. WDQS policy requires an identifying
    # User-Agent.
    def sparql(query, options = {})
      params = {
        query:,
        format: 'json'
      }

      headers = {
        'User-Agent' => options[:user_agent] || 'OpenGeographies/1.0 (https://github.com/terminusfilms/core-data-connector)'
      }

      send_request(SPARQL_URL, method: :get, params:, headers:) do |body|
        JSON.parse(body)
      end
    end
  end

  # --- Typesense client (reopen + prepend) ----------------------------------

  module TypesenseSearchRecords
    # Serializes a single record and upserts it into the collection. Used by
    # incremental (on-save) indexing; the next full reindex re-imports the record
    # with a fresh import_id.
    def index_record(record, options = {})
      collection = client.collections[collection_name]

      document = record.to_search_json(options.merge(include_relationships: true))
      collection.documents.import([document], action: 'emplace')
    end

    # Removes a single record's document from the collection. Document ids are
    # record uuids (see Search::Base search_attribute :id).
    def remove_record(uuid)
      collection = client.collections[collection_name]

      begin
        collection.documents[uuid].delete
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end
    end
  end

  module TypesenseSearchProgress
    # Full index run with an optional progress callback (done, total), so the
    # reindex job can report progress on the Job record. Overrides the upstream
    # `index` (which takes no block).
    def index(options, &on_progress)
      collection = client.collections[collection_name]

      project_model_ids = options.delete(:project_model_ids)
      options[:include_relationships] = true

      # Query project_models and build a hash of class names to arrays of project_model IDs
      model_classes = CoreDataConnector::ProjectModel
                        .where(id: project_model_ids)
                        .pluck(:id, :model_class)
                        .inject({}) do |hash, record|
                          id, model_class = record

                          hash[model_class] ||= []
                          hash[model_class] << id

                          hash
                        end

      # Total record count across all models, so callers can report progress.
      total = model_classes.keys.sum do |model_class|
        model_class.constantize.all_records_by_project_model(model_classes[model_class]).count
      end

      completed = 0
      on_progress&.call(completed, total)

      # Append a unique import_id to all of the documents indexed in this batch
      import_id = DateTime.now.to_i
      import_attributes = { import_id: import_id }

      # Iterate over the keys and query the records belonging to each project model
      model_classes.keys.each do |model_class|
        klass = model_class.constantize
        ids = model_classes[model_class]

        klass.for_search(ids) do |records|
          documents = records.map { |r| r.to_search_json(options).merge(import_attributes) }
          collection.documents.import(documents, action: 'emplace')

          completed += records.size
          on_progress&.call(completed, total)
        end
      end

      # Delete any records from the index not included in this batch
      collection.documents.delete(filter_by: "import_id:!=#{import_id}")
    end
  end
end
