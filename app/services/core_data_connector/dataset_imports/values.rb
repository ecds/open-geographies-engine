# frozen_string_literal: true

module CoreDataConnector
  module DatasetImports
    # Reading a cell as a field type, shared by the preview (which counts the
    # values each type couldn't take, so the curator sees it before importing)
    # and the import job (which stores what it reads). Everything arrives as
    # text; `cast` answers the stored value, nil for a blank, or :invalid.
    #
    # Dates come in two kinds:
    #   Date       a full day: 1983-03-15 (or 1983/03/15)
    #   FuzzyDate  what historical data mostly has — a year (1911), a month
    #              (1983-03, also NPS's "1983-03-"), a day, a decade (1890s),
    #              a range (1861-1865), circa (c. 1890) — stored as Core
    #              Data's fuzzy date, which shows "1911" or "March 1983"
    #              rather than inventing a day.
    #
    # A checkmark column — rows marked "X" (or ✓, *), the rest blank — reads as
    # Yes/No with blanks as No.
    module Values
      TRUE_VALUES = %w[true yes y 1].freeze
      FALSE_VALUES = %w[false no n 0].freeze
      CHECKMARKS = %w[x ✓ ✔ *].freeze

      # Between the terms of a category cell.
      TERM_SEPARATOR = /\s*[;|]\s*/

      INTEGER = /\A-?\d+\z/
      DECIMAL = /\A-?\d+([.,]\d+)?\z/

      FULL_DATE = %r{\A(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T ][\d:.]+Z?)?\z}
      YEAR = /\A(\d{4})\z/
      MONTH = %r{\A(\d{4})[-/](\d{1,2})[-/]?\z}
      DECADE = /\A(\d{3})0s\z/
      RANGE = /\A(\d{4})\s*(?:-|–|—|to)\s*(\d{4})\z/
      CIRCA = /\A(?:c\.?|ca\.?|circa|about)\s*(\d{4})\z/i

      ACCURACY = { year: 0, month: 1, date: 2 }.freeze

      # Words a category label keeps in lower case after its first word.
      MINOR_WORDS = %w[a an and as at but by de del des du for from in into la le nor of on or per the to via von].freeze

      module_function

      # The stored value for `value` as `data_type`, nil when blank, :invalid
      # when the text isn't one. `checkmarks: true` (a Boolean column of marks
      # and blanks) answers false for a blank.
      def cast(value, data_type, checkmarks: false)
        if value.nil? || value.strip.empty?
          return data_type == 'Boolean' && checkmarks ? false : nil
        end

        value = value.strip

        case data_type
        when 'Number' then number(value)
        when 'Boolean' then boolean(value)
        when 'Date' then date(value)
        when 'FuzzyDate' then fuzzy_date(value)
        else value
        end
      end

      # Values `data_type` couldn't take: { count:, example: }, or nil when
      # every value fits. For the preview.
      def misfits(values, data_type)
        checkmarks = data_type == 'Boolean' && checkmark_column?(values)
        bad = values.select { |v| cast(v, data_type, checkmarks:) == :invalid }

        bad.empty? ? nil : { 'count' => bad.size, 'example' => bad.first.truncate(40) }
      end

      # Marks and blanks only: "X" on 7 of 182 rows.
      def checkmark_column?(values)
        filled = values.reject { |v| v.nil? || v.strip.empty? }
        filled.any? && filled.all? { |v| CHECKMARKS.include?(v.strip.downcase) }
      end

      def number(value)
        return value.to_i if value.match?(INTEGER)
        return Float(value.tr(',', '.')) if value.match?(DECIMAL)

        :invalid
      end

      def boolean(value)
        down = value.downcase
        return true if TRUE_VALUES.include?(down) || CHECKMARKS.include?(down)
        return false if FALSE_VALUES.include?(down)

        :invalid
      end

      def date(value)
        match = FULL_DATE.match(value)
        return :invalid unless match

        Date.new(match[1].to_i, match[2].to_i, match[3].to_i).iso8601
      rescue Date::Error
        :invalid
      end

      def fuzzy_date(value)
        if (match = FULL_DATE.match(value))
          day = Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
          return fuzzy(day, day, :date)
        end

        if (match = YEAR.match(value))
          year = match[1].to_i
          return fuzzy(Date.new(year, 1, 1), Date.new(year, 12, 31), :year)
        end

        if (match = MONTH.match(value))
          start = Date.new(match[1].to_i, match[2].to_i, 1)
          return fuzzy(start, start.end_of_month, :month)
        end

        if (match = DECADE.match(value))
          decade = match[1].to_i * 10
          return fuzzy(Date.new(decade, 1, 1), Date.new(decade + 9, 12, 31), :year, range: true, description: value)
        end

        if (match = RANGE.match(value))
          from, to = match[1].to_i, match[2].to_i
          return :invalid if to < from

          return fuzzy(Date.new(from, 1, 1), Date.new(to, 12, 31), :year, range: true)
        end

        if (match = CIRCA.match(value))
          year = match[1].to_i
          return fuzzy(Date.new(year, 1, 1), Date.new(year, 12, 31), :year, description: value)
        end

        :invalid
      rescue Date::Error
        :invalid
      end

      # A category cell can list several terms: "houses; Greek Revival
      # architectural elements".
      def terms(value)
        value.to_s.split(TERM_SEPARATOR).reject(&:blank?)
      end

      # True when a term is written all in lower case (`houses`, `railroad
      # companies`): a label a curator would rather show capitalized.
      def lowercase_term?(term)
        term.match?(/\p{Ll}/) && !term.match?(/\p{Lu}/)
      end

      # Capitalizes a term written all in lower case and leaves one with
      # capitals in it (AME Church, NHL, Greek Revival architectural
      # elements) as written. Decided per term, so a Library of Congress
      # column mixing both comes out consistent.
      def capitalize_term(term)
        lowercase_term?(term) ? title_case(term) : term
      end

      # `church of god` -> `Church of God`.
      def title_case(value)
        index = -1

        value.gsub(/\p{L}[\p{L}\p{M}'’]*/) do |word|
          index += 1
          index.positive? && MINOR_WORDS.include?(word) ? word : word[0].upcase + word[1..]
        end
      end

      # Core Data's fuzzy date document.
      def fuzzy(start, finish, accuracy, range: false, description: nil)
        {
          'start_date' => start.iso8601,
          'end_date' => finish.iso8601,
          'accuracy' => ACCURACY.fetch(accuracy),
          'range' => range,
          'description' => description
        }.compact
      end
    end
  end
end
