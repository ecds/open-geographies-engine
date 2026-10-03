module CoreDataConnector
  # In words, how one saved state of an atlas becomes another, part by part
  # (SiteVersion::PARTS): `compare(a, b)` → { part key => [lines] } for the
  # parts that differ, each line saying what changes going from a to b —
  # "Primary color: #0a3a4d → #1d4e5f", "Section “Visit us” (Call to action)
  # added", "Page “About” renamed “About us”". The console's History shows
  # what a save changed (previous → that version) and what restoring a version
  # would change (now → that version).
  module SiteVersionSummary
    MAX_LINES = 12

    SECTION_TYPES = { 'hero' => 'Banner', 'text' => 'Text', 'text_image' => 'Text and image', 'call_to_action' => 'Call to action' }.freeze
    SECTION_FIELDS = {
      'title' => 'title', 'subtitle' => 'subtitle', 'body' => 'text', 'image' => 'image', 'image_alt' => 'image description',
      'image_position' => 'image side', 'button_text' => 'button', 'button_url' => 'button link', 'search' => 'search box'
    }.freeze

    BRANDING = {
      'title' => 'Site title', 'description' => 'Site description', 'logo' => 'Logo', 'favicon' => 'Favicon',
      'share_image' => 'Share image', 'font_header' => 'Header font', 'font_body' => 'Body font',
      'primary_color' => 'Primary color', 'secondary_color' => 'Secondary color', 'tertiary_color' => 'Tertiary color',
      'background_color' => 'Background color', 'background_alternate' => 'Alternate background',
      'content_color' => 'Text color', 'content_alternate' => 'Secondary text color', 'content_inverse' => 'Text on dark',
      'content_inverse_alternate' => 'Secondary text on dark', 'header_size' => 'Header size', 'page_header_size' => 'Page header size',
      'header' => 'Header', 'footer' => 'Footer'
    }.freeze
    IMAGES = %w[logo favicon share_image].freeze
    FOOTER = {
      'credit' => 'credit line', 'copyright' => 'copyright line', 'logos' => 'partner logos', 'terms_url' => 'terms link',
      'privacy_url' => 'privacy link', 'accessibility_url' => 'accessibility link', 'allow_login' => 'sign-in link'
    }.freeze
    SEARCH = {
      'facets' => 'filters', 'search_fields' => 'also search in', 'dates' => 'time', 'result_card' => 'result cards',
      'map' => 'map', 'geosearch' => 'map search', 'route' => 'address', 'layout' => 'how results show', 'table' => 'table'
    }.freeze
    LANGUAGES = { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French', 'de' => 'German', 'it' => 'Italian', 'pt' => 'Portuguese' }.freeze

    module_function

    def compare(a, b)
      SiteVersion::PARTS.each_with_object({}) do |part, summary|
        before = SiteVersion.part_value(a, part)
        after = SiteVersion.part_value(b, part)
        next if SiteVersion.comparable(before) == SiteVersion.comparable(after)

        lines = begin
          case part[:key]
          when 'name' then ["“#{before}” → “#{after}”"]
          when 'home' then home(before, after)
          when 'pages' then pages(before, after)
          when 'translations' then translations(before, after)
          when 'menu' then menu(before, after)
          when 'branding' then branding(before, after)
          when 'layers' then named_list(before, after, 'Map layer')
          when 'search' then searches(before, after)
          when 'detail_pages' then detail_pages(before, after)
          when 'languages' then languages(before, after)
          else keys_changed(before, after)
          end
        rescue StandardError => e
          # Stored values in a shape these summaries don't expect (hand-edited
          # JSON, an older layout): the part still shows, just without detail.
          Rails.logger.warn("[open_geographies] history summary of #{part[:key]}: #{e.class}: #{e.message}")
          []
        end

        lines = ['Changed'] if lines.empty?
        lines = lines.first(MAX_LINES) + ["and #{lines.size - MAX_LINES} more"] if lines.size > MAX_LINES + 1
        summary[part[:key]] = lines
      end
    end

    # Values as the summaries read them, whatever was stored: an object, or a
    # list of objects.
    def object(value) = value.is_a?(Hash) ? value : {}

    def objects(value) = Array(value).grep(Hash)

    # --- content ---------------------------------------------------------------

    def home(before, after, prefix = '')
      before = object(before)
      after = object(after)
      lines = []
      lines << "#{prefix}Description changed" if before['description'] != after['description']
      lines + sections(before['sections'], after['sections'], prefix)
    end

    def pages(before, after, prefix = '')
      before = objects(before).index_by { |page| page['slug'] }
      after = objects(after).index_by { |page| page['slug'] }
      lines = []

      after.each do |slug, page|
        old = before[slug]
        title = page['title'].presence || slug

        if old.nil?
          lines << "#{prefix}Page “#{title}” added"
          next
        end

        lines << "#{prefix}Page “#{old['title'].presence || slug}” renamed “#{title}”" if old['title'] != page['title']
        lines << "#{prefix}Page “#{title}”: description changed" if old['description'] != page['description']
        lines.concat(sections(old['sections'], page['sections'], "#{prefix}Page “#{title}”: "))
      end
      before.each { |slug, page| lines << "#{prefix}Page “#{page['title'].presence || slug}” removed" unless after.key?(slug) }
      lines << "#{prefix}Pages reordered" if (before.keys & after.keys) != (after.keys & before.keys)

      lines
    end

    def translations(before, after)
      before = object(before)
      after = object(after)

      (before.keys | after.keys).flat_map do |locale|
        name = LANGUAGES[locale] || locale
        old = before[locale]
        new = after[locale]
        next ["#{name} added"] if old.nil?
        next ["#{name} removed"] if new.nil?

        old = object(old)
        new = object(new)

        lines = []
        if old['home'] != new['home']
          lines.concat(if old['home'].nil? then ["#{name}: home page added"]
                       elsif new['home'].nil? then ["#{name}: home page removed"]
                       else home(old['home'], new['home'], "#{name} home page: ").presence || ["#{name}: home page changed"]
                       end)
        end
        lines + pages(old['pages'], new['pages'], "#{name}: ")
      end
    end

    def sections(before, after, prefix = '')
      before = objects(before)
      after = objects(after)
      old_by_id = before.index_by { |section| section['id'] }
      new_by_id = after.index_by { |section| section['id'] }
      lines = []

      after.each_with_index do |section, index|
        old = old_by_id[section['id']]
        if old.nil?
          lines << "#{prefix}#{section_name(section, index)} added"
        elsif old != section
          fields = (old.keys | section.keys).select { |key| old[key] != section[key] && key != 'id' }
          labels = fields.map { |key| SECTION_FIELDS[key] || key.humanize(capitalize: false) }.uniq
          lines << "#{prefix}#{section_name(section, index)}: #{labels.join(', ')} changed"
        end
      end
      before.each_with_index { |section, index| lines << "#{prefix}#{section_name(section, index)} removed" unless new_by_id.key?(section['id']) }

      common = before.map { |s| s['id'] } & after.map { |s| s['id'] }
      lines << "#{prefix}Sections reordered" if common != (after.map { |s| s['id'] } & before.map { |s| s['id'] })

      lines
    end

    def section_name(section, index)
      type = SECTION_TYPES[section['type']] || section['type'].to_s.humanize
      title = section['title'].to_s.strip

      title.empty? ? "Section #{index + 1} (#{type})" : "Section “#{title.truncate(50)}” (#{type})"
    end

    # --- menu, branding -----------------------------------------------------------

    def menu(before, after)
      before = object(before)
      after = object(after)
      labels = ->(nav) { objects(nav['items']).map { |item| item['label'].presence || item['page'].presence || item['href'] || '…' } }
      lines = []

      if labels.(before) != labels.(after)
        lines << "Items: #{labels.(before).join(', ').presence || 'none'} → #{labels.(after).join(', ').presence || 'none'}"
      elsif before['items'] != after['items']
        lines << 'Links changed'
      end

      others = (before.keys | after.keys) - ['items']
      others.each { |key| lines << "#{LANGUAGES[key] || key.humanize} menu changed" if before[key] != after[key] }
      lines
    end

    def branding(before, after)
      before = object(before)
      after = object(after)

      (before.keys | after.keys).sort_by { |key| BRANDING.keys.index(key) || 99 }.flat_map do |key|
        old = before[key]
        new = after[key]
        next [] if old == new

        label = BRANDING[key] || key.humanize
        if IMAGES.include?(key)
          [old.blank? ? "#{label} added" : (new.blank? ? "#{label} removed" : "#{label} changed")]
        elsif key == 'footer' || key == 'header'
          old = object(old)
          new = object(new)
          sub = (old.keys | new.keys).select { |k| old[k] != new[k] }
          [sub.any? ? "#{label}: #{sub.map { |k| FOOTER[k] || k.humanize(capitalize: false) }.join(', ')} changed" : "#{label} changed"]
        else
          # Unset branding is the atlas's default (Site::DEFAULT_BRANDING).
          ["#{label}: #{short(old, 'default')} → #{short(new, 'default')}"]
        end
      end
    end

    # --- settings -----------------------------------------------------------------

    def named_list(before, after, noun)
      before = objects(before)
      after = objects(after)
      name = ->(item, index) { item['name'].presence || "#{index + 1}" }
      old = before.each_with_index.to_h { |item, i| [name.(item, i), item] }
      new = after.each_with_index.to_h { |item, i| [name.(item, i), item] }
      lines = []

      new.each do |key, item|
        if !old.key?(key)
          lines << "#{noun} “#{key}” added"
        elsif old[key] != item
          fields = (old[key].keys | item.keys).select { |k| old[key][k] != item[k] }
          lines << "#{noun} “#{key}”: #{fields.map { |f| f.humanize(capitalize: false) }.join(', ')} changed"
        end
      end
      old.each_key { |key| lines << "#{noun} “#{key}” removed" unless new.key?(key) }
      lines << "#{noun}s reordered" if (old.keys & new.keys) != (new.keys & old.keys)
      lines
    end

    def searches(before, after)
      before = objects(before).index_by { |search| search['name'] }
      after = objects(after).index_by { |search| search['name'] }
      lines = []

      after.each do |name, search|
        old = before[name]
        next lines << "Search “#{name}” added" if old.nil?

        fields = (old.keys | search.keys).select { |key| old[key] != search[key] }
        lines << "Search “#{name}”: #{fields.map { |f| SEARCH[f] || f.humanize(capitalize: false) }.uniq.join(', ')} changed" if fields.any?
      end
      before.each_key { |name| lines << "Search “#{name}” removed" unless after.key?(name) }
      lines
    end

    def detail_pages(before, after)
      before = object(before)
      after = object(after)
      models = object(before['models']).keys | object(after['models']).keys

      lines = models.flat_map do |model|
        old = object(object(before['models'])[model])
        new = object(object(after['models'])[model])
        model_lines = []
        hidden = Array(new['exclude']) - Array(old['exclude'])
        shown = Array(old['exclude']) - Array(new['exclude'])
        model_lines << "Hidden: #{hidden.join(', ')}" if hidden.any?
        model_lines << "Shown again: #{shown.join(', ')}" if shown.any?
        model_lines << "Photo field: #{short(old['photo_field'])} → #{short(new['photo_field'])}" if old['photo_field'] != new['photo_field']
        rest = ((old.keys | new.keys) - %w[exclude photo_field]).select { |key| old[key] != new[key] }
        model_lines << "#{rest.map { |key| key.humanize(capitalize: false) }.join(', ')} changed" if rest.any?
        model_lines
      end

      lines + keys_changed(before.except('models'), after.except('models'))
    end

    def languages(before, after)
      before = object(before)
      after = object(after)
      names = ->(locales) { Array(locales).map { |l| LANGUAGES[l] || l }.join(', ').presence || 'none' }
      lines = []
      lines << "Languages: #{names.(before['locales'])} → #{names.(after['locales'])}" if before['locales'] != after['locales']
      lines << "Default language: #{names.([before['default_locale']])} → #{names.([after['default_locale']])}" if before['default_locale'] != after['default_locale']
      lines << 'Section names and labels changed' if before['strings'] != after['strings']
      lines + keys_changed(before.except('locales', 'default_locale', 'strings'), after.except('locales', 'default_locale', 'strings'))
    end

    def keys_changed(before, after)
      before = before.is_a?(Hash) ? before : {}
      after = after.is_a?(Hash) ? after : {}
      changed = (before.keys | after.keys).select { |key| before[key] != after[key] }
      changed.any? ? ["#{changed.map { |key| key.humanize }.join(', ')} changed"] : []
    end

    def short(value, blank = 'none')
      return blank if value.blank?

      text = value.is_a?(String) ? value : value.to_json
      text.truncate(60)
    end
  end
end
