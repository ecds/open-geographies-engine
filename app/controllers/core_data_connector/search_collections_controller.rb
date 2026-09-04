module CoreDataConnector
  class SearchCollectionsController < ApplicationController
    # Search attributes
    search_attributes :name

    # Preloads
    preloads :project

    # POST /core_data/search_collections/:id/reindex
    #
    # Queues a reindex of the collection's project models' records into the
    # shared v1 index. Tracked as a Job (job_type "reindex") so its status is
    # visible in the console.
    def reindex
      search_collection = SearchCollection.find(params[:id])

      authorize search_collection, :update?

      job = Job.create(
        project_id: search_collection.project_id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_REINDEX,
        extra: {
          search_collection_id: search_collection.id,
          search_collection_name: search_collection.name,
          project_model_ids: search_collection.project_model_ids
        }
      )

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end

    protected

    def apply_filters(query)
      query = super

      query = query.where(project_id: params[:project_id]) if params[:project_id].present?

      query
    end
  end
end
