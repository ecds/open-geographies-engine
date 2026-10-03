module CoreDataConnector
  # Imports a curator's dataset (the Job's attached CSV or GeoJSON) as places
  # according to the column roles chosen in the preview
  # (DatasetImportsController). Each row becomes a Place with its name, its
  # geometry when it has one, its field values, and a Types term per
  # category value.
  #
  # Fields are created on the place model on first use, typed as mapped;
  # a column whose label matches an existing field fills that field, so a
  # "Short Description" column lands in the canonical field the index
  # promotes. A Select field's options grow to cover the file's values.
  # Categories use the model's canonical Types relationship, created (with
  # the Types taxonomy) the way the template defines it when the project
  # lacks one.
  #
  # After a run that imported anything, the project's atlases are set up to
  # show it (configure_sites!): the category and each pick-list field become
  # filters, and the identifier field is hidden on public pages.
  #
  # Re-runs are safe when an identifier column is mapped: rows whose
  # identifier was already on a place in the model before this run are
  # skipped. Rows of the same file that share an identifier are all imported
  # (real data does this: one National Register listing covering eight
  # buildings) and counted as `shared_identifier`; a re-run skips them all.
  # Without an identifier, a re-run imports the rows again.
  #
  # Per-record indexing is suspended for the duration; one scoped reindex of
  # the touched models is queued at the end (ImportPlacesJob pattern).
  # Progress and outcome land on the Job row.
  class ImportDatasetJob < ApplicationJob
    PROGRESS_INTERVAL = 2.seconds
    BATCH_SIZE = 200
    SAMPLE_LIMIT = 20
    TYPES = 'Types'.freeze

    def perform(job_id)
      job = Job.find(job_id)
      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        model = ProjectModel.find(job.extra['project_model_id'])
        columns = job.extra['columns']

        job.file.open do |file|
          reader = DatasetImports::Reader.open(file.path, filename: job.extra['filename'])
          rows = []
          reader.each_row { |row| rows << row }

          run(job, model, columns, reader.format, rows)
        end
      rescue StandardError => error
        log_error error

        job.update(status: Job::JOB_STATUS_FAILED, extra: job.extra.merge('error' => error.message.truncate(1000)))
      end
    end

    private

    def run(job, model, columns, format, rows)
      @job = job
      @model = model
      @columns = columns
      @mapping = DatasetImports::Geometry.mapping_for(format, columns)
      @row_label = DatasetImports::Reader.row_name(format)
      @name_column = role_column('name')
      @identifier_column = role_column('identifier')
      @photo_column = role_column('photo')
      @counts = Hash.new(0)
      @problems = []

      @fields = ensure_fields!(rows)

      # Yes/No columns of marks and blanks ("X" on 7 rows): blanks are No.
      @checkmark_columns = @fields.select { |_column, field| field.data_type == 'Boolean' }.keys.select do |column|
        DatasetImports::Values.checkmark_column?(rows.map { |row| row[:properties][column] })
      end
      # Columns of web addresses (photo links, record links): shown as links,
      # never searched — "storage" shouldn't match every photo's address.
      @link_columns = @fields.keys.select do |column|
        values = rows.filter_map { |row| row[:properties][column].presence }
        values.any? && values.all? { |value| value.match?(DatasetImports::Profile::URL_LIKE) }
      end
      @types = ensure_types! if columns.any? { |c| c['role'] == 'types' }
      if @types
        @spellings = category_spellings(rows)
        @casing = DatasetImports::Values.word_casing(@spellings.values)
      end
      @known_identifiers = known_identifiers
      @file_identifiers = Set.new
      @geocoded = geocode_missing(rows, job.extra['geocode'])

      last_reported_at = nil

      ::OpenGeographiesPlatform::Indexing.suspend do
        rows.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
          ActiveRecord::Base.transaction do
            batch.each { |row| import_row(row) }
          end

          now = Time.current
          next unless last_reported_at.nil? || now - last_reported_at >= PROGRESS_INTERVAL

          report_progress([(batch_index + 1) * BATCH_SIZE, rows.size].min, rows.size)
          last_reported_at = now
        end
      end

      # Nothing new to index (or show) when every row was skipped or failed.
      # The reindex's id goes on this job so the console can follow it: the
      # places are saved now, but visitors see them only once it succeeds.
      if @counts['imported'].positive?
        configure_sites!
        reindex = queue_reindex([model, @types&.related_model].compact)
      end

      # Copied even when every row was already here: a re-run fetches the
      # photos an earlier run couldn't.
      copy = queue_copy_photos

      job.update(
        status: Job::JOB_STATUS_COMPLETED,
        extra: job.extra.merge(
          'progress' => { 'completed' => rows.size, 'total' => rows.size },
          'counts' => @counts,
          'geometry' => @mapping,
          'fields_created' => @fields_created.presence,
          'filters_added' => @filters_added.presence,
          'searched_fields' => @searched_fields.presence,
          'dates_added' => @dates_added.presence,
          'hidden_fields' => @hidden_fields.presence,
          'problems' => @problems.presence,
          'geocode_error' => @geocode_error,
          'reindex_job_id' => reindex&.id,
          'copy_photos_job_id' => copy&.id
        ).compact
      )
    end

    # --- One row -------------------------------------------------------------

    def import_row(row)
      properties = row[:properties]
      name = properties[@name_column]
      line = row[:line] || (row[:index] + 2)

      if name.blank?
        fail_row(line, 'has no name')
        return
      end

      identifier = @identifier_column && properties[@identifier_column]
      if identifier && @known_identifiers.include?(identifier)
        @counts['skipped'] += 1
        return
      end

      if identifier && @file_identifiers.include?(identifier)
        @counts['shared_identifier'] += 1
      end

      geometry, geometry_error = DatasetImports::Geometry.resolve(row, @mapping)
      problem(line, geometry_error) if geometry_error
      geometry ||= geocoded_geometry(row, line, name) unless geometry_error

      # A savepoint per row, so one bad row doesn't undo its batch.
      ActiveRecord::Base.transaction(requires_new: true) do
        place = Place.new(project_model_id: @model.id, user_defined: user_defined_for(properties, line))
        place.place_names.build(name:, primary: true)
        place.save!

        PlaceGeometry.create!(place:, geometry_json: geometry.to_json) if geometry
        link_categories!(place, properties)
      end

      @file_identifiers << identifier if identifier
      @counts['imported'] += 1
      @counts['without_geometry'] += 1 unless geometry
    rescue StandardError => e
      fail_row(line, e.message)
    end

    TYPE_NAMES = {
      'Number' => 'number', 'Boolean' => 'yes/no value', 'Date' => 'full date (YYYY-MM-DD)',
      'FuzzyDate' => 'date', 'Select' => 'value', 'String' => 'text', 'Text' => 'text'
    }.freeze

    def user_defined_for(properties, line)
      @fields.each_with_object({}) do |(column, field), values|
        value = DatasetImports::Values.cast(properties[column], field.data_type, checkmarks: @checkmark_columns.include?(column))

        if value == :invalid
          problem(line, "#{column}: \"#{properties[column].to_s.truncate(30)}\" is not a #{TYPE_NAMES.fetch(field.data_type, field.data_type.downcase)}; left empty")
          next
        end

        values[field.uuid] = value unless value.nil?
      end
    end

    def link_categories!(place, properties)
      return unless @types

      @columns.select { |c| c['role'] == 'types' }.each do |column|
        DatasetImports::Values.terms(properties[column['name']]).uniq.each do |value|
          value = @spellings.fetch(value.downcase, value)
          term = term_for(column['capitalize'] ? DatasetImports::Values.capitalize_term(value, @casing) : value)
          Relationship.create!(project_model_relationship: @types, primary_record: place, related_record: term)
        end
      end
    end

    # The spelling each category term is created with, decided over the
    # whole file so a term's capitalized spelling wins wherever it appears
    # (not whichever row comes first).
    def category_spellings(rows)
      names = @columns.select { |c| c['role'] == 'types' }.map { |c| c['name'] }
      DatasetImports::Values.preferred_spellings(rows.flat_map { |row| names.flat_map { |name| DatasetImports::Values.terms(row[:properties][name]) } })
    end

    def term_for(value)
      key = value.downcase
      @terms[key] ||= Taxonomy.create!(project_model: @types.related_model, name: value)
    end

    # --- Structure -----------------------------------------------------------

    # { column name => UserDefinedField } for every field and identifier
    # column, creating fields that don't exist yet.
    def ensure_fields!(rows)
      @fields_created = []
      existing = @model.user_defined_fields.index_by { |field| field.column_name.parameterize }
      order = (@model.user_defined_fields.maximum(:order) || -1) + 1

      @columns.select { |c| %w[field identifier photo].include?(c['role']) }.to_h do |column|
        label = column['label'].presence || column['name']
        data_type = %w[identifier photo].include?(column['role']) ? 'String' : column['data_type']
        values = rows.filter_map { |row| row[:properties][column['name']] }.uniq
        field = existing[label.parameterize]

        if field
          if field.data_type == 'Select'
            missing = values - Array(field.options)
            field.update!(options: Array(field.options) + missing.sort) if missing.any?
          end
        else
          field = @model.user_defined_fields.create!(
            table_name: Place.to_s, column_name: label, data_type:,
            options: data_type == 'Select' ? values.sort : [],
            searchable: true, required: false, allow_multiple: false, order:
          )
          order += 1
          @fields_created << label
        end

        [column['name'], field]
      end
    end

    # The model's canonical Types relationship, or one created as the
    # template defines it (Places —Types→ Types, multiple, inverse "Places").
    def ensure_types!
      relationship = @model.project_model_relationships.includes(:related_model).find do |r|
        r.name.casecmp?(TYPES) && r.related_model.model_class == Taxonomy.to_s
      end

      unless relationship
        taxonomy = ProjectModel.find_by(project_id: @model.project_id, name: TYPES, model_class: Taxonomy.to_s) ||
                   ProjectModel.create!(project_id: @model.project_id, name: TYPES, model_class: Taxonomy.to_s,
                                        order: (ProjectModel.where(project_id: @model.project_id).maximum(:order) || 0) + 1)

        relationship = ProjectModelRelationship.create!(
          primary_model: @model, related_model: taxonomy, name: TYPES,
          multiple: true, allow_inverse: true, inverse_name: @model.name, inverse_multiple: true
        )
        @fields_created << 'Types (taxonomy)'
      end

      @terms = Taxonomy.where(project_model: relationship.related_model).index_by { |t| t.name.downcase }
      relationship
    end

    def known_identifiers
      return Set.new unless @identifier_column

      uuid = @fields[@identifier_column].uuid
      Place.where(project_model_id: @model.id).where('user_defined ? :uuid', uuid:)
           .pluck(Arel.sql("user_defined ->> #{ActiveRecord::Base.connection.quote(uuid)}")).to_set
    end

    # --- The atlas ------------------------------------------------------------

    # Makes the import show up the way a curator expects, with no trip to
    # Settings: the category and every pick-list field become filters on
    # each search (of each of the project's atlases) that covers this model,
    # and the identifier field — an internal key — is hidden on public
    # pages, unless its values are web addresses (a record page at the
    # source, which visitors can follow). A photo column becomes the places' photo
    # (detail_pages.models.places.photo_field), shown as an image rather
    # than listed as an address. Only adds; never removes a filter or a
    # hidden field a curator chose, or replaces a photo field.
    def configure_sites!
      filters = {}
      filters['types'] = TYPES if @types
      @fields.each_value do |field|
        filters["#{field.column_name.parameterize.underscore}_facet"] = field.column_name if field.data_type == 'Select'
      end

      hidden = []
      if @identifier_column && !@link_columns.include?(@identifier_column)
        hidden << @fields[@identifier_column].column_name.parameterize.underscore
      end
      # The photo shows as the place's image, not as an address in its fields.
      photo_key = @photo_column && @fields[@photo_column].column_name.parameterize.underscore
      hidden << photo_key if photo_key

      # The first date column dates the places: the year filter and date
      # sorts (search[].dates), on searches that have no dates yet.
      date_field = @fields.values.find { |field| ::OpenGeographiesPlatform::FacetCatalog.date_field?(field) }
      dates = date_field && { 'field' => ::OpenGeographiesPlatform::FacetCatalog.date_key(@model, date_field), 'label' => date_field.column_name }
      @dates_added = []

      # Text fields become searchable ("Peachtree" finds the addresses);
      # columns of web addresses don't.
      searchable = @fields.except(@identifier_column, *@link_columns).values
                          .select { |field| ::OpenGeographiesPlatform::FacetCatalog::SEARCHABLE_TYPES.include?(field.data_type) }
                          .to_h { |field| [::OpenGeographiesPlatform::FacetCatalog.search_path(@model, field), field.column_name] }
      @searched_fields = []

      @filters_added = []
      @hidden_fields = []

      Site.where(project_id: @model.project_id).find_each do |site|
        site.with_lock do
          config = (site.config || {}).deep_dup

          Array(config['search']).each do |search|
            next unless covers_model?(search)

            facets = (search['facets'] ||= [])
            filters.each do |name, label|
              next if facets.any? { |facet| facet['name'] == name }

              facets << { 'name' => name, 'type' => 'list' }
              @filters_added << label
            end

            if dates && search['dates'].blank?
              search['dates'] = dates
              @dates_added << dates['label']
            end

            fields = (search['search_fields'] ||= [])
            searchable.each do |path, label|
              next if fields.include?(path)

              fields << path
              @searched_fields << label
            end
          end

          if photo_key
            places = ((config['detail_pages'] ||= {})['models'] ||= {})['places'] ||= {}
            places['photo_field'] ||= photo_key
          end

          if hidden.any?
            places = ((config['detail_pages'] ||= {})['models'] ||= {})['places'] ||= {}
            missing = hidden - Array(places['exclude'])

            if missing.any?
              places['exclude'] = Array(places['exclude']) + missing
              @hidden_fields.concat(missing.map { |key| @fields.values.find { |f| f.column_name.parameterize.underscore == key }&.column_name || key })
            end
          end

          site.update!(config:) unless config == site.config
        end
      end

      @filters_added.uniq!
      @hidden_fields.uniq!
      @searched_fields.uniq!
      @dates_added.uniq!
    end

    # A search with no collection covers the whole project.
    def covers_model?(search)
      id = search['search_collection_id']
      return true if id.blank?

      Array(SearchCollection.where(id:).pick(:project_model_ids)).map(&:to_i).include?(@model.id)
    end

    # --- Bookkeeping ---------------------------------------------------------

    def role_column(role)
      @columns.find { |c| c['role'] == role }&.dig('name')
    end

    # --- Addresses -------------------------------------------------------------

    # Looks up, from their address, the rows that have no location of their
    # own (DatasetImports::Geocoder); { row index => Result }. An unreachable
    # lookup doesn't fail the import: the places come in without a location
    # and the job says why.
    def geocode_missing(rows, config)
      return {} unless DatasetImports::Geocoder.usable?(config)

      @geocode_config = config
      addresses = rows.each_with_object({}) do |row, wanted|
        geometry, error = DatasetImports::Geometry.resolve(row, @mapping)
        next unless geometry.nil? && error.nil?

        parts = DatasetImports::Geocoder.parts_for(row[:properties], config, row[:properties][@name_column])
        wanted[row[:index]] = parts if parts.first.present?
      end

      record_geocode_constants(rows, config)
      DatasetImports::Geocoder.locate(addresses)
    rescue DatasetImports::Geocoder::Unavailable => e
      @geocode_error = "#{e.message} Places without coordinates were imported without a location."
      {}
    end

    # An address part from a column that wasn't kept as a field but held
    # one value throughout (HABS's City: "Savannah" in every row), so the
    # console's Places page can look the rest of the places up later.
    def record_geocode_constants(rows, config)
      kept = @columns.select { |c| %w[field identifier].include?(c['role']) }.map { |c| c['name'] }

      constants = %w[city state zip].each_with_object({}) do |part, found|
        column = config[part].presence
        next if column.nil? || kept.include?(column)

        values = rows.filter_map { |row| row[:properties][column].presence }.uniq
        found[part] = values.first if values.size == 1
      end

      @job.update_columns(extra: @job.extra.merge('geocode_constants' => constants)) if constants.any?
    end

    def geocoded_geometry(row, line, name)
      return nil unless @geocode_config

      result = @geocoded[row[:index]]

      if result&.found?(exact_only: @geocode_config['exact_only'] == true)
        @counts['located_from_address'] += 1
        @counts['approximate_address'] += 1 if result.status == 'approximate'
        return { 'type' => 'Point', 'coordinates' => [result.longitude, result.latitude] }
      end

      parts = DatasetImports::Geocoder.parts_for(row[:properties], @geocode_config, name)

      if parts.first.blank?
        @counts['no_address'] += 1
        return nil
      end

      @counts['address_not_found'] += 1
      reason = case result&.status
               when 'tie' then 'the address matches more than one place'
               when 'other_town' then "the address was found only in another town (#{result.matched})"
               when 'approximate' then "only an approximate match (#{result.matched}), and exact matches were chosen"
               else 'the address wasn\'t found'
               end
      problem(line, "(#{name}): #{reason}: #{parts.compact_blank.join(', ')}")
      nil
    end

    def fail_row(line, message)
      @counts['failed'] += 1
      problem(line, message)
    end

    def problem(line, message)
      @problems << "#{@row_label} #{line} #{message}" if @problems.size < SAMPLE_LIMIT
    end

    def report_progress(completed, total)
      @job.update_columns(
        extra: @job.extra.merge('progress' => { 'completed' => completed, 'total' => total }),
        updated_at: Time.current
      )
    end

    def queue_copy_photos
      column = @photo_column && @columns.find { |c| c['name'] == @photo_column }
      return unless column && column['copy'] && PlacePhotos.available? && @fields[@photo_column]

      Job.create(
        project_id: @job.project_id,
        user_id: @job.user_id,
        job_type: Job::JOB_TYPE_COPY_PHOTOS,
        extra: { project_model_id: @model.id, photo_field_uuid: @fields[@photo_column].uuid, import_job_id: @job.id }
      )
    end

    def queue_reindex(models)
      Job.create(
        project_id: @job.project_id,
        user_id: @job.user_id,
        job_type: Job::JOB_TYPE_REINDEX,
        extra: { project_model_ids: models.map(&:id) }
      )
    end

    def log_error(error)
      Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
    end
  end
end
