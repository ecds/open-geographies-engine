module CoreDataConnector
  # Authority bulk imports for a project (the wizard's "seed with real
  # places" step, also re-runnable later from the console).
  #
  # All actions take a place_import document:
  #   source           - 'geonames' | 'wikidata'
  #   project_model_id - optional; defaults to the project's first Place model
  #   area             - { geometry_json: <GeoJSON>, admin_units: [...] }
  #   filters          - geonames: feature_classes/feature_codes/name;
  #                      wikidata: types (P31 Q-ids, matched via P279*)
  class PlaceImportsController < ApplicationController
    # POST /core_data/projects/:project_id/place_imports/preview
    #
    # The pre-import preview: total count plus up to limit records for the
    # map. Synchronous and bounded (one authority page).
    def preview
      project = Project.find(params[:project_id])
      authorize project, :update?

      source = PlaceImports::Sources.for(
        web_authority(project),
        area: import_params[:area].to_h,
        filters: import_params[:filters].to_h
      )

      limit = (params[:limit] || 500).to_i.clamp(1, 1000)

      render json: source.preview(limit:), status: :ok
    rescue Pundit::NotAuthorizedError
      # Let the resource controller's rescue answer, as for every other action.
      raise
    rescue StandardError => error
      log_error error

      render json: { errors: [{ base: error.message }] }, status: :unprocessable_entity
    end

    # POST /core_data/projects/:project_id/place_imports
    #
    # Queues the import as a Job (job_type "import_places") so progress and
    # outcome are visible in the console.
    def create
      project = Project.find(params[:project_id])
      authorize project, :update?

      job = Job.create!(
        project_id: project.id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_IMPORT_PLACES,
        extra: {
          source: import_params[:source],
          web_authority_id: web_authority(project).id,
          project_model_id: place_model(project).id,
          area: import_params[:area].to_h,
          filters: import_params[:filters].to_h
        }
      )

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end

    # GET /core_data/projects/:project_id/place_imports/admin_children?geoname_id=...
    # GET /core_data/place_imports/admin_children?geoname_id=...
    #
    # Proxies the GeoNames admin hierarchy (country -> ADM1 -> ADM2 ...) for
    # the cascading admin-unit picker. Project-scoped requests use the
    # project's credentials; the unscoped variant exists for the wizard's
    # first step (the project does not exist yet), is open to any user who
    # can create projects, and uses the ENV credentials.
    def admin_children
      if params[:project_id].present?
        project = Project.find(params[:project_id])
        authorize project, :update?

        authority = WebAuthority.find_or_create_by!(project:, source_type: 'geonames')
        username = authority.access&.dig('username').presence || ENV.fetch('GEONAMES_USERNAME', nil)
      else
        authorize Project.new, :create?

        username = ENV.fetch('GEONAMES_USERNAME', nil)
      end

      render json: { errors: [{ base: 'geoname_id is required' }] }, status: :bad_request and return if params[:geoname_id].blank?

      json = Authority::Geonames.new.admin_children(params[:geoname_id], username:)

      render json:, status: :ok
    end

    private

    def import_params
      @import_params ||= params.require(:place_import).permit(:source, :project_model_id, area: {}, filters: {})
    end

    # Imports hang their web_identifiers off the project's authority record
    # (one per source per project); created on first use.
    def web_authority(project)
      source_type = import_params[:source].to_s

      raise ArgumentError, "Unsupported import source: #{source_type}" unless %w[geonames wikidata].include?(source_type)

      WebAuthority.find_or_create_by!(project:, source_type:)
    end

    def place_model(project)
      scope = ProjectModel.where(project:, model_class: Place.to_s)

      model =
        if import_params[:project_model_id].present?
          scope.find(import_params[:project_model_id])
        else
          scope.order(:order, :id).first
        end

      raise ArgumentError, 'Project has no Place model to import into' if model.nil?

      model
    end
  end
end
