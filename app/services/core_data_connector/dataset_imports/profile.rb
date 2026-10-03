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
    #   photo       the address of an image of the place, shown on its
    #               detail page and panel (one column)
    #   field       kept as a field on the place
    #   skip        not imported
    #
    # Columns that carry nothing a visitor would read — the same value in
    # every row, GUIDs, a GIS export's bookkeeping (Shape_Length, created/
    # edited stamps, millisecond timestamps) — default to skip, with a `note`
    # saying why, so a 38-column export doesn't propose 36 fields.
    class Profile
      SAMPLE_FEATURES = 500
      SAMPLES_PER_COLUMN = 3
      DISTINCT_CAP = 1000

      # A column that repeats a small set of short values is a pick-list
      # (Select) field, which the index turns into a facet.
      SELECT_MAX_DISTINCT = 30
      SELECT_MAX_LENGTH = 60

      NAME = /\A(name|title|label|place|place_?name|site|site_?name|full_?name|display_?name)\z/i
      # Headers that say "name" without being exactly that: RESNAME, PROP_NAME,
      # Name_1, SiteName, Title (EN).
      NAMEISH = /name|title/i
      # Columns that look like names but aren't the place's: "Multiple
      # resource name", "county name", "owner name", ...
      NOT_A_PLACE_NAME = /multi|county|state|city|owner|architect|builder|file|layer|user|author|creator|editor/i
      IDENTIFIER = /\A(id|identifier|source_?id|record_?id|uuid|objectid|fid|gid|ref|reference)\z/i
      # Headers that suggest an id without being exactly one ("LOC record",
      # "Accession no.", "RecordID", "Catalog number").
      IDISH = /(\A|[^\p{L}])(id|no|num|number|ref|record|accession|catalog|catalogue|inventory|permalink|uri|url|link|key|code)(\z|[^\p{L}])|\p{Ll}(ID|Id)\z/
      # A code: one token with a digit in it (ga0141, 77000435, HABS-GA-225).
      CODE = %r{\A(?=.*\d)[\p{L}\p{N}][\p{L}\p{N}._:/#-]{0,39}\z}
      TYPES = /\A(type|types|category|categories|kind|classification|place_?type|site_?type)\z/i
      # Headers with a category word in them ("Building types", NPS's
      # "ResType", "site_type", "Property category") are proposed as a
      # category only when their terms repeat; these words beside it say the
      # column describes something else (a file's type, a record's type).
      TYPEISH_WORD = /\A(\p{L}*types?|categor(y|ies)|kinds?|class(es|ification)?)\z/
      NOT_TYPEISH_WORD = /\A(proto|arche|geno|pheno|stereo)types?\z/
      NOT_A_CATEGORY = %w[file data geometry geom shape bnd boundary mime media content record document doc feature field value unit].freeze
      # Longest term a category is likely to have (LOC subject headings run
      # to about 50 characters).
      TERM_MAX_LENGTH = 80

      BOOLEAN_VALUES = %w[true false yes no].freeze

      # The types whose values can fail to read.
      TYPED = %w[Number Boolean Date FuzzyDate].freeze
      NUMBER = /\A-?\d+(\.\d+)?\z/
      # "007", "00000741": codes, whose leading zeros a number would drop.
      LEADING_ZERO = /\A-?0\d/
      ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

      # A column of years ("1911") reads as numbers; under a header that says
      # it's a date or a year ("Year built", "Date", "erected") it's proposed
      # as a date instead, so it can date the places (the atlas's year filter).
      YEAR_VALUE = /\A1\d{3}\z|\A20\d{2}\z/
      DATE_HEADER = /(\A|[^a-z])(year|years|yr|date|dates|dated|built|founded|established|erected|constructed|completed|opened|listed|circa)([^a-z]|\z)/i
      # ...unless the header names a measure ("Built area (sq ft)", "Listed price").
      MEASURE_HEADER = /(\A|[^a-z])(area|price|cost|value|units?|size|sq|ft|feet|acres?|count|number|total|amount|population|height|width|length|capacity)([^a-z]|\z)/i

      # Values that are something other than a name: dates (also partial,
      # "1983-03-"), links, GUIDs.
      DATE_LIKE = /\A\d{4}-\d{2}(-\d{0,2})?/
      URL_LIKE = %r{\A(https?://|www\.)}i
      # An address that serves an image (a photo column of links).
      IMAGE_URL = %r{\Ahttps?://\S+\.(jpe?g|png|gif|webp|avif)(\?\S*)?\z}i
      PHOTO = /photo|image|picture|thumbnail|illustration|\Aimg\z/i
      GUID = /\A\{?\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\}?\z/

      # A GIS export's own bookkeeping.
      GIS_BOOKKEEPING = /\A(shape_?(length|leng|len|area)|st_?(length|area)\(?.*|globalid|created_?(user|date)|last_?edited_?(user|date)|create_?date|edit_?date|creation_?date|editor|creator|edit_?user)\z/i

      # Integers that read as epoch milliseconds between 1900 and 2100 (and
      # not within four months of 1970, where small counts would match): how
      # ArcGIS writes dates into GeoJSON. Negative before 1970.
      EPOCH_MS = (-2_208_988_800_000)..(4_102_444_800_000)
      EPOCH_MS_DIGITS = /\A-?\d{11,13}\z/

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
        summary = geometry_summary(rows, geometry, name_column(columns, stats))

        {
          'format' => reader.format,
          'row_count' => rows.size,
          'geometry' => geometry.merge(summary),
          'columns' => columns.map { |column| describe(column, stats[column], geometry, columns, stats) },
          'warnings' => warnings(rows, columns, stats),
          # Rows without a location can be looked up from an address; the
          # columns that seem to make one.
          'geocoding' => summary['counts']['missing'].positive? && Geocoder.available? ? {
            'provider' => Geocoder::PROVIDER,
            'suggested' => Geocoder.suggest(columns)
          } : nil
        }.compact
      end

      private

      def column_stats(columns, rows)
        columns.to_h do |column|
          values = rows.filter_map { |row| row[:properties][column] }
          distinct = values.uniq
          terms = values.flat_map { |value| Values.terms(value) }
          distinct_terms = terms.uniq
          # One spelling per term, as the import will use it; the ones still
          # in lower case are what capitalizing would change.
          spellings = Values.preferred_spellings(distinct_terms).values
          casing = Values.word_casing(spellings)
          lowercase_terms = spellings.select { |term| Values.lowercase_term?(term) }

          [column, {
            rows: rows.size,
            filled: values.size,
            distinct: distinct.first(DISTINCT_CAP).size,
            # Rows whose value an earlier row already has.
            duplicates: values.size - distinct.size,
            all_distinct: distinct.size,
            guid: values.any? && values.all? { |v| v.match?(GUID) },
            epoch_ms: values.any? && values.all? { |v| v.match?(EPOCH_MS_DIGITS) && EPOCH_MS.cover?(v.to_i) },
            not_a_name: values.any? && values.count { |v| v.match?(DATE_LIKE) || v.match?(URL_LIKE) || v.match?(GUID) } * 2 > values.size,
            checkmarks: Values.checkmark_column?(values),
            # Category terms (a cell may list several) written all in lower
            # case, and how many distinct terms there are.
            lowercase_terms: lowercase_terms.size,
            lowercase_sample: lowercase_terms.find { |term| Values.title_case(term, casing) != term },
            casing:,
            terms: spellings.size,
            # Terms that repeat across rows and stay short: what a category
            # column looks like.
            categorical: terms.size > distinct_terms.size && distinct_terms.all? { |term| term.length <= TERM_MAX_LENGTH },
            links: values.any? && values.all? { |v| v.match?(URL_LIKE) },
            codes: values.any? && values.all? { |v| v.match?(CODE) },
            image_links: values.any? && values.count { |v| v.match?(IMAGE_URL) } * 10 >= values.size * 8,
            # How many values each typed choice couldn't take, so the console
            # can warn before an import leaves them empty.
            misfits: TYPED.to_h { |type| [type, Values.misfits(values, type)] }.compact,
            samples: distinct.first(SAMPLES_PER_COLUMN),
            max_length: values.map(&:length).max || 0,
            data_type: infer_type(values, distinct, column),
            options: distinct.size <= SELECT_MAX_DISTINCT ? distinct.sort : nil
          }]
        end
      end

      # "YearBuilt" and "CertDate" count as well as "Year built".
      def date_header?(column)
        words = column.to_s.gsub(/([a-z])([A-Z])/, '\\1 \\2')
        words.match?(DATE_HEADER) && !words.match?(MEASURE_HEADER)
      end

      def infer_type(values, distinct, column = nil)
        return 'String' if values.empty?
        return 'Boolean' if values.all? { |v| BOOLEAN_VALUES.include?(v.downcase) } || Values.checkmark_column?(values)
        return 'FuzzyDate' if date_header?(column) && values.all? { |v| v.strip.match?(YEAR_VALUE) }
        return 'Number' if values.all? { |v| v.match?(NUMBER) } && values.none? { |v| v.match?(LEADING_ZERO) }
        return 'Date' if values.all? { |v| v.match?(ISO_DATE) }
        return 'FuzzyDate' if values.all? { |v| Values.fuzzy_date(v.strip) != :invalid }
        return 'Text' if values.any? { |v| v.length > 255 }

        if distinct.size <= SELECT_MAX_DISTINCT && distinct.size * 2 <= values.size &&
           distinct.all? { |v| v.length <= SELECT_MAX_LENGTH }
          return 'Select'
        end

        'String'
      end

      # The column most likely to be the place's name: scored on the header
      # (exactly "name"/"title"/..., or one that contains name/title and isn't
      # a county/owner/multiple-listing name), on being filled in nearly every
      # row and on being nearly unique. Text only, and not mostly dates,
      # links or GUIDs. Ties go to the leftmost column. Memoized: called per
      # column.
      def name_column(columns, stats)
        @name_column ||= columns.each_with_index.filter_map do |column, index|
          stat = stats[column]
          next unless stat[:filled].positive? && %w[String Text Select].include?(stat[:data_type]) && !stat[:not_a_name]

          header = if column.match?(NAME) then 3
                   elsif column.match?(NAMEISH) && !column.match?(NOT_A_PLACE_NAME) then 2
                   else 0
                   end

          fill = stat[:filled].fdiv(stat[:rows])
          unique = stat[:all_distinct].fdiv(stat[:filled])
          score = header + (fill >= 0.9 ? 1 : fill) + (unique >= 0.9 ? 1 : unique)

          [score, -index, column]
        end.max&.last
      end

      # The column of image addresses, if any: links whose header says photo
      # or image, or links that are mostly to image files. The first one.
      def photo_column(columns, stats)
        return @photo_column if defined?(@photo_column)

        @photo_column = columns.find do |column|
          stat = stats[column]
          (stat[:links] && column.match?(PHOTO)) || stat[:image_links]
        end
      end

      # The column that tells this file's rows apart, so importing the file
      # again skips the places already here: one headed "id" (or similar)
      # whose values don't repeat; else one filled in every row with values
      # that don't repeat and look like ids — links to record pages (LOC's
      # https://www.loc.gov/item/ga0141/), or codes under an id-like header.
      # Never the name or photo column, or GUIDs (skipped as internal). One
      # at most.
      def identifier_column(columns, stats)
        return @identifier_column if defined?(@identifier_column)

        taken = [name_column(columns, stats), photo_column(columns, stats)]
        unique = ->(column) { stats[column][:filled].positive? && stats[column][:duplicates].zero? && !taken.include?(column) }

        @identifier_column = columns.find { |column| column.match?(IDENTIFIER) && unique.(column) } ||
                             columns.find { |column| inferred_identifier?(column, stats[column]) && unique.(column) }
      end

      def inferred_identifier?(column, stat)
        return false unless stat[:filled] == stat[:rows] && stat[:rows] > 1
        return false if stat[:guid] || stat[:image_links] || skip_reason(column, stat)

        (stat[:links] || stat[:codes]) && column.match?(IDISH)
      end

      # Why a column defaults to skip, or nil when it doesn't.
      def skip_reason(column, stat)
        return 'Same value in every row' if stat[:rows] > 1 && stat[:filled] == stat[:rows] && stat[:all_distinct] == 1
        return 'Looks like GIS bookkeeping' if column.match?(GIS_BOOKKEEPING)
        return 'Internal ids (GUIDs)' if stat[:guid]
        return 'Timestamps in milliseconds' if stat[:epoch_ms]

        nil
      end

      # A bare "id"-style header makes a poor field name; call it what it is.
      GENERIC_IDENTIFIER = /\A(id|fid|gid|objectid|uuid)\z/i

      def describe(column, stat, geometry, columns, stats)
        role = suggest_role(column, stat, geometry, columns, stats)

        {
          'name' => column,
          'role' => role,
          'data_type' => stat[:data_type],
          # What the values suggest, kept when an existing field's type
          # replaces data_type, so renaming away from that field restores it.
          'inferred_type' => stat[:data_type],
          'label' => role == 'identifier' && column.match?(GENERIC_IDENTIFIER) ? 'Source ID' : column,
          'filled' => stat[:filled],
          'distinct' => stat[:distinct],
          'duplicates' => stat[:duplicates].positive? ? stat[:duplicates] : nil,
          'samples' => stat[:samples],
          'options' => stat[:options],
          'misfits' => stat[:misfits].presence,
          'checkmarks' => stat[:checkmarks] || nil,
          # Category terms written all in lower case are proposed capitalized
          # (the curator can keep them as written); the example shows how,
          # and the counts say how many of the terms it touches.
          'capitalize' => stat[:lowercase_sample] ? true : nil,
          'capitalize_example' => stat[:lowercase_sample] && [stat[:lowercase_sample], Values.title_case(stat[:lowercase_sample], stat[:casing])],
          'capitalize_terms' => stat[:lowercase_sample] ? stat[:lowercase_terms] : nil,
          'terms' => role == 'types' ? stat[:terms] : nil,
          'note' => role == 'skip' ? skip_reason(column, stat) : nil,
          'identifier_note' => role == 'identifier' ? 'Every row has its own value, so importing this file again skips the places already here.' : nil
        }.compact
      end

      # Every category column feeds the one Types filter, so a header that
      # only contains a category word is proposed for at most one column, and
      # only when no column is plainly "Type"/"Category": the one whose terms
      # repeat and that has the most of them (NPS's ResType over BND_TYPE).
      def category_column(columns, stats)
        return @category_column if defined?(@category_column)
        return @category_column = nil if columns.any? { |column| column.match?(TYPES) }

        @category_column = columns.each_with_index.filter_map do |column, index|
          stat = stats[column]
          next unless (category_header?(column) || kml_folder?(column)) && stat[:categorical] && stat[:terms] >= 2 && !skip_reason(column, stat)

          [stat[:terms], -index, column]
        end.max&.last
      end

      # A KML file's folders ("Day 1", "Churches") usually sort its places
      # into kinds; proposed like a category header when they repeat.
      def kml_folder?(column)
        reader.format == 'kml' && column == KmlReader::FOLDER
      end

      # "Building types", "ResType", "site_type": a category word among the
      # header's words (camelCase split), and nothing saying it's a file's or
      # a record's type.
      def category_header?(column)
        words = column.gsub(/(\p{Ll})(\p{Lu})/, '\\1 \\2').downcase.split(/[^\p{L}\p{N}]+/)

        words.any? { |word| word.match?(TYPEISH_WORD) && !word.match?(NOT_TYPEISH_WORD) } &&
          (words & NOT_A_CATEGORY).empty?
      end

      def suggest_role(column, stat, geometry, columns, stats)
        return 'latitude' if geometry['mode'] == 'latlon' && column == geometry['latitude']
        return 'longitude' if geometry['mode'] == 'latlon' && column == geometry['longitude']
        return 'geometry' if %w[wkt geojson].include?(geometry['mode']) && column == geometry['column']
        return 'skip' if stat[:filled].zero?
        # The features carry their own geometry; coordinate columns are copies.
        return 'skip' if geometry['mode'] == 'feature' && (column.match?(Geometry::LATITUDE) || column.match?(Geometry::LONGITUDE))
        return 'name' if column == name_column(columns, stats)
        return 'photo' if column == photo_column(columns, stats)
        return 'identifier' if column == identifier_column(columns, stats)
        return 'types' if column.match?(TYPES) || column == category_column(columns, stats)
        return 'skip' if skip_reason(column, stat)

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
            problems << "#{row_label(row)}: #{error}" if problems.size < 5
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

      def row_label(row)
        prefix = Reader.row_name(reader.format)
        "#{prefix} #{row[:line] || (row[:index] + 2)}"
      end

      def warnings(rows, columns, stats)
        warnings = reader.warnings.dup
        warnings << 'The file has no rows.' if rows.empty?
        warnings << 'No column looks like a place name; choose one before importing.' unless name_column(columns, stats)
        warnings
      end
    end
  end
end
