# frozen_string_literal: true

require 'csv'

module CoreDataConnector
  module DatasetImports
    class CsvReader < Reader
      SEPARATORS = [',', ';', "\t"].freeze

      def format = 'csv'

      def columns
        load!
        @columns
      end

      def each_row
        load!

        index = 0
        @table.each_with_index do |values, position|
          next if values.all? { |v| clean(v).nil? }

          check_row_limit!(index)
          properties = @columns.each_with_index.to_h { |column, i| [column, clean(values[i])] }
          yield({ index:, line: position + 2, properties:, geometry: nil })
          index += 1
        end
      end

      private

      def load!
        return if @table

        text = read_text
        first_line = text.each_line.first.to_s
        separator = SEPARATORS.max_by { |sep| first_line.count(sep) }

        rows = CSV.parse(text, col_sep: separator, liberal_parsing: true)
        raise Invalid, 'The file is empty.' if rows.empty?

        @columns = normalize_headers(rows.first)
        @table = rows.drop(1)
      rescue CSV::MalformedCSVError => e
        raise Invalid, "The CSV could not be read: #{e.message}"
      end
    end
  end
end
