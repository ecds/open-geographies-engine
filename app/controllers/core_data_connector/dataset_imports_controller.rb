module CoreDataConnector
  # A curator's own dataset (CSV or GeoJSON) imported as places — the way a
  # new atlas with its own data gets its records, next to the authority
  # imports (GeoNames/Wikidata) for atlases that start from a gazetteer.
  #
  # Two steps, so nothing is written until the curator has seen the plan:
  #
  #   POST /core_data/projects/:project_id/dataset_imports/preview
  #     multipart `file` (+ optional project_model_id). Stores the upload as
  #     a blob and answers with its profile (DatasetImports::Profile): a
  #     proposed role and field type per column, the geometry mapping and a
  #     sample of features, plus `blob_id` to import it by.
  #
  #   POST /core_data/projects/:project_id/dataset_imports
  #     { dataset_import: { blob_id:, project_model_id:, columns: [{ name:, role:, label:, data_type: }] } }
  #     Queues an import_dataset Job with the file attached (ImportDatasetJob).
  class DatasetImportsController < ApplicationController
    ROLES = %w[name latitude longitude geometry identifier types field skip].freeze
    DATA_TYPES = %w[String Text Number Boolean Date FuzzyDate Select].freeze

    def preview
      project = Project.find(params[:project_id])
      authorize project, :update?

      upload = params.require(:file)
      model = place_model(project, params[:project_model_id])

      reader = DatasetImports::Reader.open(upload.tempfile.path, filename: upload.original_filename)
      profile = DatasetImports::Profile.new(reader).to_h
      annotate_existing_fields!(profile, model)
      attach_previous_choices!(profile, model)

      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(upload.tempfile.path),
        filename: upload.original_filename,
        content_type: upload.content_type
      )

      render json: {
        dataset_import: profile.merge(
          'blob_id' => blob.signed_id,
          'filename' => upload.original_filename,
          'project_model_id' => model.id,
          'project_model_name' => model.name,
          # So the console can tell, as the curator renames a column, whether
          # the name fills an existing field (and takes its type).
          'existing_fields' => model.user_defined_fields.map { |f| { 'label' => f.column_name, 'data_type' => f.data_type, 'uuid' => f.uuid } }
        )
      }, status: :ok
    rescue DatasetImports::Reader::UnsupportedFormat, DatasetImports::Reader::Invalid => e
      render json: { errors: [{ base: e.message }] }, status: :unprocessable_entity
    end

    def create
      project = Project.find(params[:project_id])
      authorize project, :update?

      attributes = params.require(:dataset_import).permit(:blob_id, :project_model_id, columns: [:name, :role, :label, :data_type])
      model = place_model(project, attributes[:project_model_id])
      blob = ActiveStorage::Blob.find_signed(attributes[:blob_id])

      render json: { errors: [{ base: 'The uploaded file has expired; upload it again.' }] }, status: :unprocessable_entity and return if blob.nil?

      columns = Array(attributes[:columns]).map { |c| c.to_h.slice('name', 'role', 'label', 'data_type') }
      errors = validate_columns(columns)
      render json: { errors: errors.map { |e| { base: e } } }, status: :unprocessable_entity and return if errors.any?

      job = Job.new(
        project_id: project.id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_IMPORT_DATASET,
        extra: { 'filename' => blob.filename.to_s, 'project_model_id' => model.id, 'columns' => columns }
      )
      job.file.attach(blob)
      job.save!

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end

    private

    # Marks columns whose label matches a field the model already has, so the
    # import fills that field (and keeps its type) instead of adding a twin.
    # Matching ignores case and punctuation: "short description" fills the
    # canonical "Short Description", which the index promotes.
    def annotate_existing_fields!(profile, model)
      profile['columns'].each do |column|
        field = existing_field(model, column['label'], profile['format'])
        mark_existing!(column, field) if field
      end
    end

    # The choices from the last upload into this model, by column name, so a
    # second file of the same shape (the polygons after the points, next
    # month's export) starts where the curator left off: each matching
    # column gets `previous` (role, label, type — and the existing field its
    # label now fills), and the profile says which upload they came from.
    # The console applies them; "Restore suggestions" starts over.
    def attach_previous_choices!(profile, model)
      job = Job.where(project_id: model.project_id, job_type: Job::JOB_TYPE_IMPORT_DATASET, status: Job::JOB_STATUS_COMPLETED)
               .where("extra->>'project_model_id' = ?", model.id.to_s)
               .order(created_at: :desc)
               .first
      return unless job

      previous = Array(job.extra['columns']).index_by { |column| column['name'] }
      matched = 0

      profile['columns'].each do |column|
        choice = previous[column['name']]
        next unless choice

        choice = choice.slice('role', 'label', 'data_type')
        field = %w[field identifier].include?(choice['role']) ? existing_field(model, choice['label'], profile['format']) : nil
        mark_existing!(choice, field) if field

        column['previous'] = choice
        matched += 1
      end

      return if matched.zero?

      profile['previous_import'] = {
        'filename' => job.extra['filename'],
        'imported_at' => job.created_at.iso8601,
        'matched' => matched
      }
    end

    def existing_field(model, label, format)
      @fields ||= model.user_defined_fields.to_a
      @fields.find { |field| field.column_name.parameterize == label.to_s.parameterize } ||
        truncated_match(label, @fields, format)
    end

    def mark_existing!(column, field)
      column['label'] = field.column_name
      column['field_uuid'] = field.uuid
      column['data_type'] = field.data_type if DATA_TYPES.include?(field.data_type)
      column['existing'] = true
    end

    # A shapefile's .dbf cuts field names to 10 characters ("Short Desc");
    # match one to the only existing field it is the start of.
    DBF_NAME_LENGTH = 10

    def truncated_match(label, fields, format)
      return unless format == 'shapefile' && label.to_s.length == DBF_NAME_LENGTH

      candidates = fields.select { |field| field.column_name.downcase.start_with?(label.downcase) }
      candidates.first if candidates.one?
    end

    def validate_columns(columns)
      roles = columns.map { |c| c['role'] }
      errors = []

      errors << "Unknown role: #{(roles - ROLES).uniq.join(', ')}" if (roles - ROLES).any?
      errors << 'Choose exactly one column as the place name.' unless roles.count('name') == 1
      errors << 'Choose both a latitude and a longitude column, or neither.' unless roles.count('latitude') == roles.count('longitude')
      errors << 'Choose at most one latitude and one longitude column.' if roles.count('latitude') > 1
      errors << 'Choose at most one geometry column.' if roles.count('geometry') > 1
      errors << 'Use coordinate columns or a geometry column, not both.' if roles.include?('latitude') && roles.include?('geometry')
      errors << 'Choose at most one identifier column.' if roles.count('identifier') > 1

      columns.each do |column|
        next unless column['role'] == 'field'

        errors << "#{column['name']}: a field needs a label." if column['label'].blank?
        errors << "#{column['name']}: unknown field type #{column['data_type']}." unless DATA_TYPES.include?(column['data_type'])
      end

      labels = columns.select { |c| c['role'] == 'field' }.map { |c| c['label'].to_s.parameterize }
      errors << 'Two field columns have the same label.' if labels.uniq.size < labels.size

      errors
    end

    def place_model(project, project_model_id)
      scope = ProjectModel.where(project:, model_class: Place.to_s)
      model = project_model_id.present? ? scope.find_by(id: project_model_id) : scope.order(:order, :id).first
      raise ArgumentError, 'Project has no Place model to import into' if model.nil?

      model
    end
  end
end
