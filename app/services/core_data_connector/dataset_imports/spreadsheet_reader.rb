# frozen_string_literal: true

require 'roo'

module CoreDataConnector
  module DatasetImports
    # Excel (.xlsx) and OpenDocument (.ods) workbooks, through roo (already in
    # the host's bundle). Reads the first sheet; its first non-empty row is the
    # header. Typed cells come back as the text a CSV of the same sheet would
    # hold, so the profiler treats every format alike: whole numbers without a
    # trailing ".0", dates as YYYY-MM-DD, booleans as true/false.
    class SpreadsheetReader < Reader
      def initialize(path, extension:)
        super(path)
        @extension = extension
      end

      def format = 'spreadsheet'

      def columns
        load!
        @columns
      end

      def warnings
        load!
        return [] if @sheet_names.size <= 1

        ["Using the first sheet, “#{@sheet_names.first}”; the workbook has #{@sheet_names.size} sheets."]
      end

      def each_row
        load!

        index = 0
        @rows.each do |line, values|
          next if values.all?(&:nil?)

          check_row_limit!(index)
          properties = @columns.each_with_index.to_h { |column, i| [column, values[i]] }
          yield({ index:, line:, properties:, geometry: nil })
          index += 1
        end
      end

      private

      def load!
        return if @rows

        book = Roo::Spreadsheet.open(path, extension: @extension)
        @sheet_names = book.sheets
        sheet = book.sheet(0)

        rows = []
        if sheet.first_row
          (sheet.first_row..sheet.last_row).each { |number| rows << [number, sheet.row(number).map { |v| cell(v) }] }
        end

        header_at = rows.index { |_number, values| values.any? }
        raise Invalid, "The first sheet, “#{@sheet_names.first}”, is empty." unless header_at

        @columns = normalize_headers(rows[header_at].last)
        @rows = rows.drop(header_at + 1)
      rescue Invalid
        raise
      rescue StandardError => e
        # roo raises whatever its parser hits on a file it doesn't expect (a
        # NoMethodError deep in its XML walk, for one); the curator only needs
        # to know the file can't be read and what to try.
        Rails.logger.warn("[DatasetImports] #{@extension} unreadable: #{e.class}: #{e.message}")
        raise Invalid, 'The workbook could not be read. Open it in Excel or LibreOffice, save it again as .xlsx ' \
                       '(or export the sheet as CSV), and upload that.'
      end

      def cell(value)
        case value
        when nil then nil
        when true, false then value.to_s
        when DateTime, Time then value.iso8601
        when Date then value.iso8601
        when Float then value.finite? && (value % 1).zero? && value.abs < 1e15 ? value.to_i.to_s : value.to_s
        else clean(value.to_s)
        end
      end
    end
  end
end
