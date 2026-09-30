# frozen_string_literal: true

module CoreDataConnector
  module DatasetImports
    # One pass over a dataset that proposes how to import it: a role and a
    # field type for every column, how its geometry is carried, and a sample
    # of features for the preview map. The curator can override every choice
    # before importing; nothing here writes anything.
    #
    # Roles:
    #   name        the place's primary name (exactly one column)
    #   latitude /
    #   longitude   coordinate columns
    #   geometry    a WKT or GeoJSON-text column
    #   identifier  a unique id from the source; re-running the import skips
    #               rows whose id is already in the atlas
    #   types       a category; each value becomes a term of the atlas's
    #               Types taxonomy (its standard facet). Several values may
    #               be separated by ";" or "|"
    #   field       kept as a field on the place
    #   skip        not imported
    class Profile
      SAMPLE_FEATURES = 500
      SAMPLES_PER_COLUMN = 3
      DISTINCT_CAP = 1000

      # A column that repeats a small set of short values is a pick-list
      # (Select) field, which the index turns into a facet.
      SELECT_MAX_DISTINCT = 30
      SELECT_MAX_LENGTH = 60

      NAME = /\A(name|title|label|place|place_?name|site|site_?name|full_?name|display_?name)\z/i
      IDENTIFIER = /\A(id|identifier|source_?id|record_?id|uuid|objectid|fid|gid|ref|reference)\z/i
      TYPES = /\A(type|types|category|categories|kind|classification|place_?type|site_?type)\z/i

      BOOLEAN_VALUES = %w[true false yes no].freeze
      NUMBER = /\A-?\d+(\.\d+)?\z/
      ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

      attr_reader :reader

      def initialize(reader)
        @reader = reader
      end

      def to_h
        rows = []
        reader.each_row { |row| rows << row }

        columns = reader.columns
        geometry = Geometry.detect(reader.format, columns, rows.first(200))
        stats = column_stats(columns, rows)

        {
          'format' => reader.format,
          'row_count' => rows.size,
          'geometry' => geometry.merge(geometry_summary(rows, geometry, name_column(columns, stats))),
          'columns' => columns.map { |column| describe(column, stats[column], geometry, columns, stats) },
          'warnings' => warnings(rows, columns, stats)
        }
      end

      private

      def column_stats(columns, rows)
        columns.to_h do |column|
          values = rows.filter_map { |row| row[:properties][column] }
          distinct = values.uniq

          [column, {
            filled: values.size,
            distinct: distinct.first(DISTINCT_CAP).size,
            samples: distinct.first(SAMPLES_PER_COLUMN),
            max_length: values.map(&:length).max || 0,
            data_type: infer_type(values, distinct),
            options: distinct.size <= SELECT_MAX_DISTINCT ? distinct.sort : nil
          }]
        end
      end

      def infer_type(values, distinct)
        return 'String' if values.empty?
        return 'Boolean' if values.all? { |v| BOOLEAN_VALUES.include?(v.downcase) }
        return 'Number' if values.all? { |v| v.match?(NUMBER) }
        return 'Date' if values.all? { |v| v.match?(ISO_DATE) }
        return 'Text' if values.any? { |v| v.length > 255 }

        if distinct.size <= SELECT_MAX_DISTINCT && distinct.size * 2 <= values.size &&
           distinct.all? { |v| v.length <= SELECT_MAX_LENGTH }
          return 'Select'
        end

        'String'
      end

      def name_column(columns, stats)
        columns.find { |c| c.match?(NAME) && stats[c][:filled].positive? } ||
          columns.find { |c| %w[String Text].include?(stats[c][:data_type]) && stats[c][:filled].positive? }
      end

      # A bare "id"-style header makes a poor field name; call it what it is.
      GENERIC_IDENTIFIER = /\A(id|fid|gid|objectid|uuid)\z/i

      def describe(column, stat, geometry, columns, stats)
        role = suggest_role(column, stat, geometry, columns, stats)

        {
          'name' => column,
          'role' => role,
          'data_type' => stat[:data_type],
          'label' => role == 'identifier' && column.match?(GENERIC_IDENTIFIER) ? 'Source ID' : column,
          'filled' => stat[:filled],
          'distinct' => stat[:distinct],
          'samples' => stat[:samples],
          'options' => stat[:options]
        }.compact
      end

      def suggest_role(column, stat, geometry, columns, stats)
        return 'latitude' if geometry['mode'] == 'latlon' && column == geometry['latitude']
        return 'longitude' if geometry['mode'] == 'latlon' && column == geometry['longitude']
        return 'geometry' if %w[wkt geojson].include?(geometry['mode']) && column == geometry['column']
        return 'skip' if stat[:filled].zero?
        return 'name' if column == name_column(columns, stats)
        return 'identifier' if column.match?(IDENTIFIER) && stat[:distinct] == stat[:filled] && stat[:distinct] < DISTINCT_CAP
        return 'types' if column.match?(TYPES)

        'field'
      end

      def geometry_summary(rows, mapping, name_column)
        counts = Hash.new(0)
        problems = []
        features = []
        bbox = nil

        rows.each do |row|
          geometry, error = Geometry.resolve(row, mapping)

          if error
            counts['invalid'] += 1
            problems << "Row #{row[:index] + 2}: #{error}" if problems.size < 5
            next
          end

          if geometry.nil?
            counts['missing'] += 1
            next
          end

          counts[geometry['type']] += 1
          bbox = extend_bbox(bbox, Geometry.positions(geometry))

          next if features.size >= SAMPLE_FEATURES

          features << { 'type' => 'Feature', 'geometry' => geometry,
                        'properties' => { 'name' => name_column && row[:properties][name_column] } }
        end

        {
          'counts' => counts,
          'problems' => problems,
          'bbox' => bbox,
          'features' => { 'type' => 'FeatureCollection', 'features' => features }
        }
      end

      def extend_bbox(bbox, positions)
        positions.each do |lon, lat|
          bbox = bbox ? [[bbox[0], lon].min, [bbox[1], lat].min, [bbox[2], lon].max, [bbox[3], lat].max] : [lon, lat, lon, lat]
        end
        bbox
      end

      def warnings(rows, columns, stats)
        warnings = []
        warnings << 'The file has no rows.' if rows.empty?
        warnings << 'No column looks like a place name; choose one before importing.' unless name_column(columns, stats)
        warnings
      end
    end
  end
end
