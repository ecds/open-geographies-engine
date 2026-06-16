module CoreDataConnector
  class SearchCollectionsController < ApplicationController
    # Search attributes
    search_attributes :name

    # Preloads
    preloads :project

    # POST /core_data/search_collections/:id/reindex
    #
    # Queues a full rebuild of the collection. The run is tracked as a Job
    # (job_type "reindex") so its status is visible in the console.
    def reindex
      search_collection = SearchCollection.find(params[:id])

      authorize search_collection, :update?

      job = Job.create(
        project_id: search_collection.project_id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_REINDEX,
        extra: {
          search_collection_id: search_collection.id,
          search_collection_name: search_collection.name
        }
      )

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end

    # POST /core_data/search_collections/:id/issue_key
    #
    # Issues (or re-issues, revoking the previous) a search-only Typesense
    # API key scoped to this collection, for use by public sites.
    def issue_key
      search_collection = SearchCollection.find(params[:id])

      authorize search_collection, :update?

      key = search_collection.issue_search_only_key!

      render json: { search_only_key: key }, status: :ok
    rescue StandardError => error
      render json: { errors: [{ base: error.message }] }, status: :unprocessable_entity
    end

    protected

    def apply_filters(query)
      query = super

      query = query.where(project_id: params[:project_id]) if params[:project_id].present?

      query
    end
  end
end
