module CoreDataConnector
  # An atlas's own pages, as the console edits them and the renderer shows
  # them: the home page and any number of standalone pages (About, Credits,
  # …), stored on Site#content as
  #
  #   { 'home'  => { description, sections: [...] },
  #     'pages' => [{ slug, title, description, sections: [...] }, ...],
  #     'translations' => { 'es' => { 'home' => {...}, 'pages' => [...] }, ... } }
  #
  # `translations` holds the atlas's pages in its other languages, in the same
  # shape: a translated page has the address (slug) of one of the atlas's
  # pages, and a page or home page left untranslated shows in the atlas's
  # default language. Only languages the renderer routes (LOCALES) are kept.
  #
  # A section is one of SECTION_FIELDS' types. Text is Markdown, stored as
  # the curator wrote it; the renderer turns it into HTML and sanitizes it, so
  # what is stored is always the editable source.
  #
  # Validation is structural (known section types, sizes, unique slugs) and
  # about links: button links and image sources must be site paths or
  # http(s) (and mailto: for links), never javascript:/data: URLs, even though
  # the renderer sanitizes as well. #to_h drops unknown keys and coerces
  # checkboxes; Site runs it before saving.
  class SiteContent
    SECTION_FIELDS = {
      'hero' => %w[title subtitle image image_alt search search_placeholder button_text button_url],
      'text' => %w[title body],
      'text_image' => %w[title body image image_alt image_position button_text button_url],
      'call_to_action' => %w[title body button_text button_url]
    }.freeze

    SECTION_LABELS = {
      'hero' => 'Banner',
      'text' => 'Text',
      'text_image' => 'Text and image',
      'call_to_action' => 'Call to action'
    }.freeze

    BOOLEAN_FIELDS = %w[search].freeze
    LINK_FIELDS = %w[button_url].freeze
    IMAGE_FIELDS = %w[image].freeze
    MARKDOWN_FIELDS = %w[body].freeze
    CHOICES = { 'image_position' => %w[left right] }.freeze

    # The languages an atlas can be in: the [lang] prefixes the renderer's
    # routing knows (its src/config.defaults.json i18n.locales), with the
    # name the console shows.
    LOCALES = {
      'en' => 'English',
      'es' => 'Español',
      'fr' => 'Français',
      'de' => 'Deutsch',
      'it' => 'Italiano',
      'pt' => 'Português'
    }.freeze

    MAX_PAGES = 50
    MAX_SECTIONS = 30
    MAX_MARKDOWN = 50_000
    MAX_STRING = 1_000

    SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]*\z/

    # Site paths ("/en/search/places", but not protocol-relative "//host"),
    # in-page anchors, http(s) and mailto:.
    LINK_FORMAT = %r{\A(?:/(?!/)|#|https?://|mailto:)}i

    # Site paths (the renderer resolves /core_data/public/... uploads against
    # the console) and http(s).
    IMAGE_FORMAT = %r{\A(?:/(?!/)|https?://)}i

    CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/

    def self.safe_link?(value)
      value.blank? || (value.is_a?(String) && value.strip.match?(LINK_FORMAT) && !value.match?(CONTROL_CHARACTERS))
    end

    def self.safe_image?(value)
      value.blank? || (value.is_a?(String) && value.strip.match?(IMAGE_FORMAT) && !value.match?(CONTROL_CHARACTERS))
    end

    # The home page a new atlas starts with: a banner with the atlas's title
    # (left blank so it follows the site title), its description, a search box
    # and a button into the map.
    def self.default_home(description: nil, search_href: nil)
      {
        'description' => description.presence,
        'sections' => [
          {
            'id' => 'hero',
            'type' => 'hero',
            'subtitle' => description.presence,
            'search' => true,
            'search_placeholder' => 'Search places',
            'button_text' => search_href.present? ? 'Explore the map' : nil,
            'button_url' => search_href.presence
          }.compact
        ]
      }.compact
    end

    def initialize(document)
      document = document.to_unsafe_h if document.respond_to?(:to_unsafe_h)
      @document = document.is_a?(Hash) ? document.deep_stringify_keys : {}
    end

    # Messages for everything that can't be saved, phrased for the curator.
    def errors
      errors = []

      home = @document['home']
      pages = @document['pages']

      errors << 'The home page must be an object.' unless home.nil? || home.is_a?(Hash)
      errors << 'Pages must be a list.' unless pages.nil? || pages.is_a?(Array)
      return errors unless errors.empty?

      page_errors(home, 'The home page', errors, home: true) if home

      pages = pages || []
      errors << "An atlas can have at most #{MAX_PAGES} pages." if pages.size > MAX_PAGES

      pages.each_with_index do |page, index|
        unless page.is_a?(Hash)
          errors << "Page #{index + 1} must be an object."
          next
        end

        page_errors(page, page_name(page, index), errors, home: false)
      end

      slugs = pages.filter_map { |page| page['slug'] if page.is_a?(Hash) }.reject(&:blank?)
      slugs.tally.each { |slug, count| errors << "More than one page has the address \"#{slug}\"." if count > 1 }

      translation_errors(@document['translations'], slugs, errors)

      errors
    end

    # The document with unknown keys dropped, strings stripped, blank values
    # removed and checkboxes as booleans.
    def to_h
      home = @document['home']
      pages = @document['pages']

      {
        'home' => home.is_a?(Hash) ? normalize_page(home, home: true) : nil,
        'pages' => pages.is_a?(Array) ? pages.select { |page| page.is_a?(Hash) }.map { |page| normalize_page(page, home: false) } : [],
        'translations' => normalize_translations(@document['translations'])
      }.compact
    end

    private

    def translation_errors(translations, slugs, errors)
      return if translations.nil?

      unless translations.is_a?(Hash)
        errors << 'Translations must be an object.'
        return
      end

      translations.each do |locale, translation|
        unless LOCALES.key?(locale)
          errors << "Pages can be translated into #{LOCALES.values.join(', ')}; \"#{locale}\" isn't one of them."
          next
        end

        language = LOCALES[locale]

        unless translation.is_a?(Hash)
          errors << "The #{language} pages must be an object."
          next
        end

        page_errors(translation['home'], "The #{language} home page", errors, home: true) if translation['home'].is_a?(Hash)
        errors << "The #{language} home page must be an object." unless translation['home'].nil? || translation['home'].is_a?(Hash)

        pages = translation['pages']
        next if pages.nil?

        unless pages.is_a?(Array)
          errors << "The #{language} pages must be a list."
          next
        end

        pages.each_with_index do |page, index|
          unless page.is_a?(Hash)
            errors << "#{language} page #{index + 1} must be an object."
            next
          end

          name = "The #{language} version of #{page_name(page, index).sub(/\APage/, 'page')}"
          page_errors(page, name, errors, home: false)
          errors << "#{name} doesn't match one of the atlas's pages (address \"#{page['slug']}\")." if page['slug'].present? && !slugs.include?(page['slug'])
        end

        translated = pages.filter_map { |page| page['slug'] if page.is_a?(Hash) }.reject(&:blank?)
        translated.tally.each { |slug, count| errors << "There is more than one #{language} version of the page \"#{slug}\"." if count > 1 }
      end
    end

    # Translations in supported languages, normalized like the default
    # pages; a language with nothing translated is dropped.
    def normalize_translations(translations)
      return nil unless translations.is_a?(Hash)

      normalized = translations.slice(*LOCALES.keys).filter_map do |locale, translation|
        next unless translation.is_a?(Hash)

        home = translation['home'].is_a?(Hash) ? normalize_page(translation['home'], home: true) : nil
        pages = Array(translation['pages']).select { |page| page.is_a?(Hash) }.map { |page| normalize_page(page, home: false) }
        document = { 'home' => home, 'pages' => pages.presence }.compact

        [locale, document] if document.any?
      end.to_h

      normalized.presence
    end

    def page_name(page, index)
      title = page['title'].presence || page['slug'].presence
      title ? "Page \"#{title}\"" : "Page #{index + 1}"
    end

    def page_errors(page, name, errors, home:)
      unless home
        slug = page['slug']

        if slug.blank?
          errors << "#{name} needs an address (e.g. about)."
        elsif !slug.is_a?(String) || !slug.match?(SLUG_FORMAT) || slug.length > 63
          errors << "#{name}: the address can only use lowercase letters, numbers and hyphens."
        end

        errors << "#{name} needs a title." if page['title'].blank?
      end

      string_errors(page.slice('title', 'description'), name, errors)

      sections = page['sections']
      return if sections.nil?

      unless sections.is_a?(Array)
        errors << "#{name}: sections must be a list."
        return
      end

      errors << "#{name} can have at most #{MAX_SECTIONS} sections." if sections.size > MAX_SECTIONS

      sections.each_with_index do |section, index|
        section_errors(section, "#{name}, section #{index + 1}", errors)
      end
    end

    def section_errors(section, name, errors)
      unless section.is_a?(Hash) && SECTION_FIELDS.key?(section['type'])
        errors << "#{name}: unknown section type."
        return
      end

      name = "#{name} (#{SECTION_LABELS[section['type']]})"

      string_errors(section.slice(*SECTION_FIELDS[section['type']]).except(*BOOLEAN_FIELDS), name, errors)

      LINK_FIELDS.each do |field|
        next if SiteContent.safe_link?(section[field])

        errors << "#{name}: the button link must start with /, https://, http:// or mailto:."
      end

      IMAGE_FIELDS.each do |field|
        next if SiteContent.safe_image?(section[field])

        errors << "#{name}: the image must be an uploaded image or an https:// address."
      end

      CHOICES.each do |field, choices|
        value = section[field]
        errors << "#{name}: #{field.humanize.downcase} must be one of #{choices.join(', ')}." if value.present? && !choices.include?(value)
      end
    end

    def string_errors(values, name, errors)
      values.each do |field, value|
        next if value.nil?

        unless value.is_a?(String)
          errors << "#{name}: #{field.humanize.downcase} must be text."
          next
        end

        limit = MARKDOWN_FIELDS.include?(field) ? MAX_MARKDOWN : MAX_STRING
        errors << "#{name}: #{field.humanize.downcase} is longer than #{limit} characters." if value.length > limit
      end
    end

    def normalize_page(page, home:)
      fields = home ? %w[description] : %w[slug title description]
      normalized = normalize_strings(page.slice(*fields))
      normalized['sections'] = Array(page['sections']).filter_map { |section| normalize_section(section) }
      normalized
    end

    def normalize_section(section)
      return nil unless section.is_a?(Hash) && SECTION_FIELDS.key?(section['type'])

      normalized = { 'id' => section['id'].to_s.first(64).presence, 'type' => section['type'] }.compact
      fields = SECTION_FIELDS[section['type']]

      normalized.merge!(normalize_strings(section.slice(*(fields - BOOLEAN_FIELDS))))

      (fields & BOOLEAN_FIELDS).each do |field|
        normalized[field] = ActiveModel::Type::Boolean.new.cast(section[field]) || false if section.key?(field)
      end

      normalized
    end

    # Markdown keeps its inner whitespace (line breaks are meaningful);
    # everything else is stripped. Blank values are dropped.
    def normalize_strings(values)
      values.each_with_object({}) do |(field, value), normalized|
        next unless value.is_a?(String)

        value = MARKDOWN_FIELDS.include?(field) ? value.gsub(/\r\n?/, "\n").strip : value.strip
        normalized[field] = value if value.present?
      end
    end
  end
end
