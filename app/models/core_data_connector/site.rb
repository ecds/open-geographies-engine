module CoreDataConnector
  # A site is a published frontend for a project: one record holds everything
  # the renderer's config.json needs (layers, search apps, detail-page config,
  # locales, content settings, WordPress host), and #to_site_config emits that
  # document. The shared dynamic renderer (core-data-places) resolves it by slug
  # per request — no per-site build or hand-edited config files.
  #
  # The config column is a free-form JSON document intentionally: projects
  # share no common schema, so sites must be able to express any
  # model/field/relationship graph. Structure comes from introspection at
  # edit time (console pick-lists over the project's descriptors), never from
  # columns that hardcode a particular project's shape.
  #
  # Search entries reference SearchCollection records by id; the emitted
  # config expands them into the renderer's elasticsearch block (shared index
  # from the deployment environment + the collection's search-only key), so
  # site editors never handle search credentials.
  class Site < ApplicationRecord
    # The frontend's branding document is console-owned: edited here and served
    # to the shared dynamic renderer per request (via the public atlas-by-slug
    # endpoint), no longer a TinaCMS collection. These defaults fill any field
    # the console hasn't set, so a site with empty branding still emits a
    # complete, valid document — the palette matches the old content template,
    # and the title defaults to the atlas name (so a freshly provisioned atlas
    # reads its own name in the header instead of "My Atlas").
    DEFAULT_BRANDING = {
      'font_header' => 'Inter',
      'font_body' => 'Inter',
      'primary_color' => '#0a3a4d',
      'secondary_color' => '#5f93a8',
      'tertiary_color' => '#072836',
      'background_color' => '#ffffff',
      'background_alternate' => '#eef3f5',
      'content_color' => '#111827',
      'content_alternate' => '#4b5563',
      'content_inverse' => '#ffffff',
      'content_inverse_alternate' => '#d1d5db',
      'header' => { 'hide_title' => false },
      'footer' => { 'allow_login' => false }
    }.freeze

    # Branding values that end up in the renderer's CSS or in href/src
    # attributes. Validated so a stored value can only ever be a color, a
    # size or a safe URL (see #validate_branding).
    BRANDING_COLORS = %w[
      primary_color secondary_color tertiary_color background_color background_alternate
      content_color content_alternate content_inverse content_inverse_alternate
    ].freeze
    BRANDING_SIZES = %w[header_size page_header_size].freeze
    BRANDING_CAPITALIZATION = %w[none normal uppercase small-caps].freeze
    COLOR_FORMAT = /\A#(?:\h{3}|\h{4}|\h{6}|\h{8})\z/
    SIZE_FORMAT = /\A\d{1,3}(?:\.\d+)?(?:px|rem|em)\z/

    # Images a curator can upload for the atlas (logo, favicon, page images).
    # Served publicly by Public::V1::AssetsController.
    ASSET_CONTENT_TYPES = %w[
      image/png image/jpeg image/gif image/webp image/avif image/svg+xml
      image/x-icon image/vnd.microsoft.icon
    ].freeze
    MAX_ASSET_BYTES = 10.megabytes

    # A search's date field (search[].dates.field): a top-level document key.
    DATE_FIELD = /\A[a-z0-9_]+\z/

    # What every search looks in (the renderer's own default); a search's
    # `search_fields` are added after these.
    DEFAULT_SEARCH_ATTRIBUTES = [
      { 'field' => 'name', 'weight' => 3 },
      { 'field' => 'names', 'weight' => 2 },
      'description',
      'short_description'
    ].freeze

    # Fonts the console offers (must match the set the frontend loads).
    BRANDING_FONTS = [
      'Afacad', 'Baskervville', 'Crimson Text SemiBold', 'DM Sans',
      'DM Serif Display', 'Inter', 'Libre Bodoni', 'Open Sans'
    ].freeze

    # Slugs that must never be claimed by an atlas: the slug becomes a subdomain
    # (`<slug>.<base-domain>`), so a tenant must not be able to take the apex's
    # infra hostnames. Kept in sync with the renderer middleware's
    # RESERVED_SUBDOMAINS.
    RESERVED_SLUGS = %w[
      www api app console coredata admin staging assets static cdn mail ftp root
    ].freeze

    # Relationships
    belongs_to :project

    # Its history: a version per save of its content, branding, menu and
    # settings (SiteVersion), deleted with it.
    has_many :versions, -> { order(id: :desc) }, class_name: 'CoreDataConnector::SiteVersion', dependent: :delete_all

    after_create { SiteVersion.record!(self, created: true) }
    after_update { SiteVersion.record!(self) }

    # Uploaded images for the atlas's pages and branding, and the web-sized
    # copies made of them (SiteImages).
    has_many_attached :assets
    has_many_attached :asset_variants

    # A site is born on a project and stays there. Authorization runs against
    # the project a site belongs to *before* an update is applied, so allowing
    # project_id to change would let an owner of A re-parent a site onto B —
    # and the public by-slug endpoint would then publish it under B's data.
    attr_readonly :project_id

    # An atlas is private until published: the public atlas-by-slug endpoint
    # serves a draft only to a request carrying its preview token (the
    # curator's shareable preview link). Regenerating the token revokes
    # every link handed out so far.
    has_secure_token :preview_token, length: 32

    # Validations
    validates :published, inclusion: { in: [true, false] }
    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true,
                     length: { maximum: 63 },
                     format: { with: /\A[a-z0-9][a-z0-9\-]*\z/, message: 'only lowercase letters, numbers, and hyphens' },
                     exclusion: { in: RESERVED_SLUGS, message: 'is reserved' }
    validate :validate_search_collections
    validate :validate_content
    validate :validate_branding
    validate :validate_navigation
    validate :validate_domain
    validate :validate_locales, if: :will_save_change_to_config?

    before_save :normalize_content

    # A domain is connected to the atlas its DNS names (SiteDomains), and the
    # DNS names the atlas by its slug: a new domain, or a new slug, has to be
    # checked again before the atlas is served there.
    before_save :disconnect_domain, if: -> { will_save_change_to_domain? || will_save_change_to_slug? }

    def self.permitted_params
      [:project_id, :name, :slug, :published,
       { config: {} }, { area: {} },
       { branding: {} }, { navigation: {} }, { content: {} }]
    end

    # The atlas's own domain, stored without scheme, path, port or case
    # (SiteDomains.normalize). Set through SitesController#update_domain,
    # which checks the DNS; not one of the permitted params.
    def domain=(value)
      super(SiteDomains.normalize(value))
    end

    # True when the domain is connected: its DNS named this atlas when last
    # checked. Only then is the atlas served there.
    def domain_connected?
      domain.present? && domain_verified_at.present?
    end

    # The connected domain, or nil.
    def connected_domain
      domain_connected? ? domain : nil
    end

    # Checks the domain's DNS (SiteDomains.check) and records the answer:
    # connected, taking the domain from any other atlas it was connected to
    # (the DNS has moved), or not connected. Returns the check, or nil when
    # there's no domain.
    def check_domain!
      result = SiteDomains.check(self)
      return nil unless result

      self.class.transaction do
        if result.connected
          self.class.where(domain:).where.not(id:).where.not(domain_verified_at: nil).update_all(domain_verified_at: nil)
          update_columns(domain_verified_at: Time.current)
        else
          update_columns(domain_verified_at: nil)
        end
      end

      result
    rescue ActiveRecord::RecordNotUnique
      reload
      SiteDomains::Check.new(connected: false, message: "#{domain} was just connected to another atlas.")
    end

    # The atlas's public address: its connected domain, else its platform
    # address (OG_ATLAS_URL_TEMPLATE with the slug). The domain keeps the
    # template's scheme and port, so a development server's
    # http://…localhost:4321 stays one. Nil when no template is configured.
    def public_url
      url = platform_url
      return url unless url && domain_connected?

      uri = URI.parse(url)
      uri.host = domain
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    # The atlas's address on the platform (<slug>.<base domain>), which
    # redirects to its domain once one is connected.
    def platform_url
      ENV['OG_ATLAS_URL_TEMPLATE'].presence&.gsub('{slug}', slug.to_s)
    end

    # The domain's state for the console: nil, 'pending' or 'connected'.
    def domain_status
      return nil if domain.blank?

      domain_connected? ? 'connected' : 'pending'
    end

    # True when `token` is this site's preview token (compared in constant
    # time).
    def preview_token?(token)
      token.present? && preview_token.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, preview_token)
    end

    # The public path of an uploaded asset (host-relative; the renderer
    # resolves it against the console's public URL). The filename is
    # cosmetic: the blob key alone identifies the file.
    def self.asset_path(blob)
      asset_path_for(blob.key, blob.filename.to_s)
    end

    def self.asset_path_for(key, filename)
      "/core_data/public/v1/assets/#{key}/#{ERB::Util.url_encode(filename)}"
    end

    # The branding document served to the renderer:
    # stored values over the defaults, with the title defaulting to the
    # atlas name. Header/footer are merged one level deep so setting a logo
    # doesn't drop the hide_title default.
    def to_branding
      stored = (branding || {}).deep_dup.deep_stringify_keys

      document = DEFAULT_BRANDING.deep_merge(stored)
      document['title'] = stored['title'].presence || name

      document
    end

    # "Explore", the starter menu's link into the map, in each language.
    EXPLORE_LABELS = { 'en' => 'Explore', 'es' => 'Explorar', 'fr' => 'Explorer', 'de' => 'Erkunden', 'it' => 'Esplora', 'pt' => 'Explorar' }.freeze

    # The navbar document served to the renderer, in `locale` (one of the
    # atlas's languages): the stored items, or a default (Explore, then each
    # page) when none are stored. Items that point at a page ({ _template:
    # 'Page', page: <slug> }) become links to it, labelled with its title (the
    # translated one) unless the item has its own label; an item whose page
    # no longer exists is dropped. An item's `labels` ({ es: 'Inicio' }) name
    # it per language, and site links move to the language's prefix.
    def to_navigation(locale = default_locale)
      locale = locale.to_s
      content = to_content
      pages = localized_pages(content, locale).index_by { |page| page['slug'] }
      translated = locale == default_locale ? pages.keys : Array(content.dig('translations', locale, 'pages')).pluck('slug')
      items = (navigation || {}).deep_stringify_keys['items']

      items = default_navigation_items(locale, pages.values) if items.blank?

      { 'items' => items.filter_map { |item| resolve_navigation_item(item, pages, locale, translated) } }
    end

    # The navbar in each of the atlas's languages.
    def to_navigations
      locales.index_with { |locale| to_navigation(locale) }
    end

    # The atlas's languages (config.i18n.locales), default first, limited to
    # the ones the renderer routes (SiteContent::LOCALES).
    def locales
      listed = Array((config || {}).dig('i18n', 'locales')).map(&:to_s) & SiteContent::LOCALES.keys
      ([default_locale] + listed).uniq
    end

    def default_locale
      (config || {}).dig('i18n', 'default_locale').presence || 'en'
    end

    # The atlas's pages (see SiteContent), normalized, with a starter home
    # page when none has been written yet: a banner with the atlas's
    # description (or the legacy config.home.tagline), a search box and a
    # button into the first search.
    def to_content
      document = SiteContent.new(content).to_h

      document['home'] ||= SiteContent.default_home(
        description: (config || {}).dig('home', 'tagline').presence || project&.description,
        search_href: default_search_href(default_locale)
      )

      document
    end

    # The sizes and web-sized copies of the site's uploaded images, for the
    # renderer's srcset (see SiteImages.bundle).
    def to_images
      SiteImages.bundle(self)
    end

    # Emits the config.json document for this site: the stored config with
    # the platform-derived sections (core_data connection, search/elasticsearch
    # blocks) filled in.
    def to_site_config
      site_config = (config || {}).deep_dup.deep_stringify_keys

      # A stored core_data.url wins over the environment default: a site can
      # front records hosted on a different Core Data instance (e.g. data on
      # a hosted instance, console/indexing here).
      site_config['core_data'] = {
        'url' => site_config.dig('core_data', 'url') || ENV.fetch('CORE_DATA_PUBLIC_URL', nil),
        'project_ids' => [project_id.to_s]
      }.compact

      site_config['i18n'] ||= { 'default_locale' => 'en', 'locales' => ['en'] }

      site_config['search'] = (site_config['search'] || []).map { |entry| expand_search_entry(entry) }

      site_config
    end

    private

    # The atlas's pages in `locale`: each page's translation, where it has
    # one (SiteContent translations), else the page as written.
    def localized_pages(content, locale)
      pages = content['pages']
      return pages if locale == default_locale

      translated = Array(content.dig('translations', locale, 'pages')).index_by { |page| page['slug'] }
      pages.map { |page| translated[page['slug']]&.merge('slug' => page['slug']) || page }
    end

    # The first search app's page, e.g. /en/search/places.
    def default_search_href(locale)
      name = Array((config || {})['search']).first&.dig('name')
      name.present? ? "/#{locale}/search/#{name}" : nil
    end

    # The starter navbar for a site that hasn't customized navigation:
    # Explore (the first search) and then every page, in order.
    def default_navigation_items(locale, pages)
      explore = default_search_href(locale)

      [
        (explore && { '_template' => 'URL', 'label' => EXPLORE_LABELS[locale] || 'Explore', 'href' => explore }),
        *pages.map { |page| { '_template' => 'Page', 'page' => page['slug'] } }
      ].compact
    end

    def resolve_navigation_item(item, pages, locale, translated)
      return item unless item.is_a?(Hash)
      return localize_navigation_item(item, locale) unless item['_template'] == 'Page'

      page = pages[item['page']]
      return nil unless page

      own = item_label(item, locale)
      label = own || (translated.include?(page['slug']) && locale != default_locale ? page['title'] : item['label'].presence || page['title'])

      { '_template' => 'URL', 'label' => label, 'href' => "/#{locale}/pages/#{page['slug']}" }
    end

    # A link item (and its dropdown options) in `locale`: its label for the
    # language, and a site link under the default language's prefix moved to
    # this one's (/en/search/places → /es/search/places).
    def localize_navigation_item(item, locale)
      localized = item.except('labels')
      localized['label'] = item_label(item, locale) || item['label']
      localized['href'] = item['href'].sub(%r{\A/#{Regexp.escape(default_locale)}(?=/|\z)}, "/#{locale}") if item['href'].is_a?(String)
      localized['options'] = item['options'].map { |option| option.is_a?(Hash) ? localize_navigation_item(option, locale) : option } if item['options'].is_a?(Array)
      localized.compact
    end

    # The item's own label in `locale`: its labels entry, or (in the default
    # language) its label.
    def item_label(item, locale)
      labels = item['labels']
      (labels.is_a?(Hash) && labels[locale].presence) || (locale == default_locale ? item['label'].presence : nil)
    end

    def validate_content
      SiteContent.new(content).errors.each { |message| errors.add(:content, message) }
    end

    def normalize_content
      self.content = SiteContent.new(content).to_h if will_save_change_to_content?
    end

    # The atlas's languages must be ones the renderer routes, and include the
    # default.
    def validate_locales
      i18n = (config || {})['i18n']
      return unless i18n.is_a?(Hash)

      listed = Array(i18n['locales']).map(&:to_s)
      unknown = listed - SiteContent::LOCALES.keys
      errors.add(:config, "An atlas's languages can be #{SiteContent::LOCALES.values.join(', ')} (not #{unknown.join(', ')})") if unknown.any?

      default = i18n['default_locale'].to_s
      errors.add(:config, "The default language must be one of the atlas's languages.") if default.present? && listed.any? && !listed.include?(default)
    end

    def validate_domain
      message = SiteDomains.problem(domain) if will_save_change_to_domain?
      errors.add(:domain, message) if message
    end

    def disconnect_domain
      self.domain_verified_at = nil
    end

    # Colors and sizes go into the renderer's CSS, URLs into src/href
    # attributes; each is held to a format that can't carry anything else.
    def validate_branding
      document = branding.respond_to?(:to_unsafe_h) ? branding.to_unsafe_h : branding
      return if document.blank?

      unless document.is_a?(Hash)
        errors.add(:branding, 'must be an object')
        return
      end

      document = document.deep_stringify_keys
      header = document['header'].is_a?(Hash) ? document['header'] : {}
      footer = document['footer'].is_a?(Hash) ? document['footer'] : {}

      BRANDING_COLORS.each do |key|
        value = document[key]
        errors.add(:branding, "#{key.humanize.downcase} must be a hex color such as #0a3a4d") if value.present? && !value.to_s.match?(COLOR_FORMAT)
      end

      %w[font_header font_body].each do |key|
        value = document[key]
        errors.add(:branding, "#{key.humanize.downcase} must be one of #{BRANDING_FONTS.join(', ')}") if value.present? && !BRANDING_FONTS.include?(value)
      end

      BRANDING_SIZES.each do |key|
        value = document[key]
        errors.add(:branding, "#{key.humanize.downcase} must be a size such as 48px") if value.present? && !value.to_s.match?(SIZE_FORMAT)
      end

      weight = document['header_font_weight']
      errors.add(:branding, 'header font weight must be 100-900') if weight.present? && !weight.to_s.match?(/\A[1-9]00\z/)

      capitalization = document['header_capitalization']
      errors.add(:branding, "header capitalization must be one of #{BRANDING_CAPITALIZATION.join(', ')}") if capitalization.present? && !BRANDING_CAPITALIZATION.include?(capitalization)

      # The footer's rights line, shown as written ("© {year} Emory
      # University", "Photographs: public domain"). None unless set: an
      # atlas of public-domain records shouldn't claim all rights by default.
      copyright = footer['copyright']
      errors.add(:branding, 'the copyright line must be text of at most 300 characters') if copyright.present? && !(copyright.is_a?(String) && copyright.length <= 300)

      images = [document['logo'], document['favicon'], document['share_image'], header['logo']]
      links = footer.values_at('terms_url', 'privacy_url', 'accessibility_url')

      Array(footer['logos']).each do |logo|
        next unless logo.is_a?(Hash)

        images << logo['image']
        links << logo['url']
      end

      errors.add(:branding, 'images must be uploaded images or https:// addresses') unless images.all? { |value| SiteContent.safe_image?(value) }
      errors.add(:branding, 'links must start with /, https://, http:// or mailto:') unless links.all? { |value| SiteContent.safe_link?(value) }
    end

    def validate_navigation
      document = navigation.respond_to?(:to_unsafe_h) ? navigation.to_unsafe_h : navigation
      return if document.blank?

      items = document.is_a?(Hash) ? document.deep_stringify_keys['items'] : nil
      return if items.nil?

      unless items.is_a?(Array)
        errors.add(:navigation, 'items must be a list')
        return
      end

      hrefs = items.flat_map do |item|
        next [] unless item.is_a?(Hash)

        [item['href'], *Array(item['options']).map { |option| option.is_a?(Hash) ? option['href'] : nil }]
      end

      errors.add(:navigation, 'links must start with /, https://, http:// or mailto:') unless hrefs.all? { |href| SiteContent.safe_link?(href) }

      # Per-language labels: { es: 'Inicio' }, short text, known languages.
      labelled = items.flat_map { |item| item.is_a?(Hash) ? [item, *Array(item['options']).grep(Hash)] : [] }
      labels_ok = labelled.all? do |item|
        labels = item['labels']
        labels.nil? || (labels.is_a?(Hash) && labels.all? { |locale, label| SiteContent::LOCALES.key?(locale.to_s) && (label.nil? || (label.is_a?(String) && label.length <= 200)) })
      end
      errors.add(:navigation, "menu labels per language must be short text, in #{SiteContent::LOCALES.values.join(', ')}") unless labels_ok
    end

    # Expands a stored search entry for the renderer: the search_collection_id
    # reference becomes the `elasticsearch` block — the shared v1 index name,
    # the collection's project model ids (the index holds every model of every
    # atlas, so a search must say which models it is over; the renderer
    # applies these as a server-side filter alongside project_id), and facet
    # attributes (the entry's configured facets, defaulting to the canonical
    # `types`) — with any stored elasticsearch values kept as overrides. No
    # credentials: this document is served to the browser; the renderer's
    # server-side handler holds the connection and injects the tenant filter.
    def expand_search_entry(entry)
      expanded = entry.deep_dup
      search_collection = search_collections_by_id[expanded.delete('search_collection_id')&.to_i]
      expanded.delete('typesense')

      # The field that places the search's records in time (the renderer's
      # year filter, date sorts and timeline): a top-level document key only.
      dates = expanded.delete('dates')
      if dates.is_a?(Hash) && dates['field'].is_a?(String) && dates['field'].match?(DATE_FIELD)
        expanded['dates'] = {
          'field' => dates['field'],
          'label' => dates['label'].presence&.to_s&.strip&.truncate(80),
          'timeline' => dates['timeline'] == true
        }.compact
      end

      elasticsearch = expanded['elasticsearch'] || {}

      # The text fields the curator chose to search besides the name
      # ("Address", "Nomination file"), as index paths; a stored
      # elasticsearch.search_attributes still wins.
      search_fields = Array(expanded.delete('search_fields')).select { |path| path.is_a?(String) && path.match?(/\A[a-z0-9_.]+\z/) }
      if search_fields.any? && elasticsearch['search_attributes'].blank?
        elasticsearch = elasticsearch.merge('search_attributes' => (DEFAULT_SEARCH_ATTRIBUTES + search_fields).uniq)
      end

      # The entry's `facets` (what the console edits) is the source of the
      # facet attributes; a stored elasticsearch.facet_attributes is only a
      # fallback for entries with no facets declared.
      facet_names = (expanded['facets'] || []).map { |facet| facet['name'] }.compact
      facet_names = Array(elasticsearch['facet_attributes']).presence || ['types'] if facet_names.empty?

      # index_name is always the platform's: the atlas's own index (or the
      # shared one), never a stored value.
      expanded['elasticsearch'] = {
        'model_ids' => search_collection&.project_model_ids&.map(&:to_s)
      }.compact.merge(elasticsearch).merge(
        'index_name' => ::OpenGeographiesPlatform::Indexing.index_name(project_id),
        'facet_attributes' => facet_names
      )

      expanded
    end

    def search_collections_by_id
      @search_collections_by_id ||= SearchCollection.where(project_id:).index_by(&:id)
    end

    # All referenced search collections must belong to this site's project.
    def validate_search_collections
      return if project_id.nil? || config.blank?

      referenced = (config['search'] || [])
                   .filter_map { |entry| entry['search_collection_id'] }
                   .map(&:to_i)

      invalid = referenced - SearchCollection.where(project_id:).pluck(:id)

      errors.add(:config, "references search collections not in this project: #{invalid.join(', ')}") if invalid.any?
    end
  end
end
