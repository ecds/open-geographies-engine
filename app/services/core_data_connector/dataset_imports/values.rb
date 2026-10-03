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
      # The Library of Congress's quarter-century notation (HABS building
      # dates): "18q2" is the second quarter of the 1800s, 1825–1849.
      QUARTER = /\A(\d{2})q([1-4])\z/i
      # "ca. 1825- ca. 1830": a range with circa on either end, kept as written.
      CIRCA_RANGE = /\A(?:c\.?|ca\.?|circa|about)\s*(\d{4})\s*(?:-|–|—|to)\s*(?:(?:c\.?|ca\.?|circa|about)\s*)?(\d{4})\z/i
      # Two dates as a span: "1819-03-01 – 1886-05", "1819-03/1886" (ISO 8601's
      # interval), "March 1819 to 1886" is not read. Each end a year, a month
      # or a day; a dash between them needs spaces around it, an en/em dash
      # or slash doesn't.
      DATE_SPAN = %r{\A(\d{4}[-/\d]*?)\s*(?:–|—|/(?=\d{4})|\s-\s|\sto\s)\s*(\d{4}[-/\d]*)\z}

      ACCURACY = { year: 0, month: 1, date: 2 }.freeze

      # Words a category label keeps in lower case after its first word.
      WORD = /\p{L}[\p{L}\p{M}'’]*/
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

        if (match = CIRCA_RANGE.match(value))
          from, to = match[1].to_i, match[2].to_i
          return :invalid if to < from

          return fuzzy(Date.new(from, 1, 1), Date.new(to, 12, 31), :year, range: true, description: value)
        end

        if (match = QUARTER.match(value))
          from = match[1].to_i * 100 + (match[2].to_i - 1) * 25
          return fuzzy(Date.new(from, 1, 1), Date.new(from + 24, 12, 31), :year, range: true)
        end

        if (match = DATE_SPAN.match(value))
          from = date_end(match[1])
          to = date_end(match[2])
          return :invalid unless from && to && to[1] >= from[0]

          # The coarser end says how exact the span is.
          accuracy = [from[2], to[2]].min_by { |a| ACCURACY.fetch(a) }
          return fuzzy(from[0], to[1], accuracy, range: true)
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

      # { lower-cased term => the spelling to use } for a column's terms. A
      # term the file also writes with capitals somewhere keeps that spelling
      # (LOC lists both "Greek Revival architectural elements" and "greek
      # revival architectural elements"); otherwise the first one wins.
      def preferred_spellings(terms)
        terms.each_with_object({}) do |term, spellings|
          key = term.downcase
          spellings[key] = term if !spellings.key?(key) || (lowercase_term?(spellings[key]) && !lowercase_term?(term))
        end
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
      def capitalize_term(term, casing = {})
        lowercase_term?(term) ? title_case(term, casing) : term
      end

      # How the file's own capitalized terms write each word after the
      # first: { "architectural" => "architectural", "revival" => "Revival" }.
      # A lower-case term then follows the source's convention: LOC's
      # "classical revival architectural elements" becomes "Classical
      # Revival architectural elements", like its "Greek Revival
      # architectural elements". The first spelling seen wins.
      def word_casing(terms)
        terms.reject { |term| lowercase_term?(term) }.each_with_object({}) do |term, casing|
          term.scan(WORD).drop(1).each { |word| casing[word.downcase] ||= word }
        end
      end

      # `church of god` -> `Church of God`.
      def title_case(value, casing = {})
        index = -1

        value.gsub(WORD) do |word|
          index += 1
          next word[0].upcase + word[1..] if index.zero?
          next casing[word] if casing.key?(word)

          MINOR_WORDS.include?(word) ? word : word[0].upcase + word[1..]
        end
      end

      # Core Data's fuzzy date document.
      # One end of a span: [first day, last day, accuracy] for a year, a
      # month or a day, else nil.
      def date_end(text)
        if (match = FULL_DATE.match(text))
          day = Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
          [day, day, :date]
        elsif (match = MONTH.match(text))
          start = Date.new(match[1].to_i, match[2].to_i, 1)
          [start, start.end_of_month, :month]
        elsif (match = YEAR.match(text))
          year = match[1].to_i
          [Date.new(year, 1, 1), Date.new(year, 12, 31), :year]
        end
      rescue Date::Error
        nil
      end

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
