module OpenGeographies
  # Applies Open Geographies' in-place extensions to upstream Core Data classes —
  # the OG-coupled subset of the changes the fork used to make directly to upstream
  # files. Each is a reopen (additive include / new methods) or a prepend
  # (behavioral override). Applied inside the engine's `config.to_prepare` so they
  # re-apply after Zeitwerk reloads in development (each reload yields a fresh
  # upstream class, so includes/callbacks land exactly once).
  #
  # Indexing is deliberately NOT decorated here. The lower-layer engine
  # (core-data-connector-open-geographies) hooks the upstream classes with its
  # own V1::Reindexable / ReindexesParent decorators, so every create, update
  # and destroy — including nested names, geometries and relationships — is
  # written to the shared v1 Elasticsearch index without this engine's help.
  # This engine only suspends that around bulk writes and reindexes what it
  # wrote afterwards (see OpenGeographies::Indexing).
  module Decorators
    def self.apply!
      wire_job_dispatch!
      wire_job_policy!
      wire_import_csv_job!
      wire_authority_bulk!
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

    # ImportCsvJob → suspend per-record indexing during the bulk import, then
    # queue one reindex scoped to the project.
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
      CoreDataConnector::ReindexAtlasJob.perform_later(id)
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
    # Suspend per-record indexing for the bulk import (one Elasticsearch
    # round-trip per row would flood the cluster and re-serialize relationship
    # graphs thousands of times), then queue a single reindex scoped to the
    # project's records.
    def perform(id)
      OpenGeographies::Indexing.suspend { super }

      job = CoreDataConnector::Job.find_by(id:)
      queue_reindex(job) if job&.status == CoreDataConnector::Job::JOB_STATUS_COMPLETED
    end

    private

    def queue_reindex(job)
      CoreDataConnector::Job.create(
        project_id: job.project_id,
        user_id: job.user_id,
        job_type: CoreDataConnector::Job::JOB_TYPE_REINDEX,
        extra: {}
      )
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
end
