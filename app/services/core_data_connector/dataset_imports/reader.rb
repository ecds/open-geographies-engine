# frozen_string_literal: true

require 'csv'
require 'json'

module CoreDataConnector
  module DatasetImports
    # Reads a curator's own dataset file into uniform rows:
    #
    #   { index: <0-based row number>, properties: { column => value }, geometry: <GeoJSON hash or nil> }
    #
    # Values are stripped strings (nil when empty). `geometry` is only set for
    # formats that carry it structurally (a GeoJSON feature); a CSV's
    # coordinates live in its columns and are resolved by Geometry against
    # the curator's column mapping.
    #
    # Supported: CSV (comma, semicolon or tab separated; any common encoding),
    # Excel (.xlsx) and OpenDocument (.ods) workbooks, GeoJSON (a
    # FeatureCollection, a single Feature, or a bare geometry) and zipped
    # Shapefiles. Everything else is refused with a message that says what to
    # do instead.
    #
    # Rows also carry `line`: where the curator will find the row in their own
    # file (the spreadsheet row number, or the feature's position).
    class Reader
      class UnsupportedFormat < StandardError; end
      class Invalid < StandardError; end

      MAX_ROWS = 50_000
      MAX_BYTES = 50 * 1024 * 1024

      CSV_EXTENSIONS = %w[.csv .tsv .txt].freeze
      GEOJSON_EXTENSIONS = %w[.geojson .json].freeze
      SPREADSHEET_EXTENSIONS = { '.xlsx' => :xlsx, '.ods' => :ods }.freeze
      SHAPEFILE_EXTENSIONS = %w[.zip].freeze

      HINTS = {
        '.xls' => 'Older Excel files (.xls) are not read: in Excel, use File → Save As → Excel Workbook (.xlsx) or CSV, then upload that.',
        '.shp' => 'A shapefile is several files: zip the layer’s .shp, .dbf, .shx and .prj together and upload the .zip.',
        '.kml' => 'KML is not read directly yet: convert it to GeoJSON (for example with QGIS or geojson.io), then upload that.',
        '.kmz' => 'KMZ is not read directly yet: convert it to GeoJSON (for example with QGIS or geojson.io), then upload that.'
      }.freeze

      def self.open(path, filename:)
        extension = File.extname(filename.to_s).downcase

        raise Invalid, "The file is larger than #{MAX_BYTES / (1024 * 1024)} MB." if File.size(path) > MAX_BYTES

        if CSV_EXTENSIONS.include?(extension)
          CsvReader.new(path)
        elsif GEOJSON_EXTENSIONS.include?(extension)
          GeojsonReader.new(path)
        elsif SPREADSHEET_EXTENSIONS.key?(extension)
          SpreadsheetReader.new(path, extension: SPREADSHEET_EXTENSIONS[extension])
        elsif SHAPEFILE_EXTENSIONS.include?(extension)
          ShapefileReader.new(path)
        else
          raise UnsupportedFormat, HINTS.fetch(extension) {
            "Upload a .csv, .xlsx, .ods, .geojson or zipped shapefile (.zip) (got #{extension.presence || 'no extension'})."
          }
        end
      end

      attr_reader :path

      def initialize(path)
        @path = path
      end

      # Column names in file order.
      def columns
        raise NotImplementedError
      end

      def format
        raise NotImplementedError
      end

      # Things the curator should know about how the file was read.
      def warnings
        []
      end

      # Yields each row. Stops with Invalid past MAX_ROWS.
      def each_row(&)
        raise NotImplementedError
      end

      protected

      def clean(value)
        return nil if value.nil?

        value = value.to_s.strip
        value.empty? ? nil : value
      end

      def check_row_limit!(index)
        raise Invalid, "The file has more than #{MAX_ROWS} rows; split it and upload the parts." if index >= MAX_ROWS
      end

      # Unique, non-blank column names: an empty header becomes "Column 3",
      # a repeated one "Name (2)".
      def normalize_headers(headers)
        seen = Hash.new(0)

        headers.each_with_index.map do |header, index|
          name = clean(header) || "Column #{index + 1}"
          seen[name] += 1
          seen[name] > 1 ? "#{name} (#{seen[name]})" : name
        end
      end

      # Text in UTF-8 without a byte-order mark, whatever the file was saved as.
      def read_text
        raw = File.binread(path)
        raw = raw.byteslice(3..) if raw.start_with?("\xEF\xBB\xBF".b)

        text = raw.dup.force_encoding(Encoding::UTF_8)
        text = raw.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace) unless text.valid_encoding?
        text
      end
    end
  end
end
