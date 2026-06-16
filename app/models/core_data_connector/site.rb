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
  # config expands them into the Typesense connection block (public endpoint
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
      'footer' => { 'allow_login' => true }
    }.freeze

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

    # Validations
    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true,
                     length: { maximum: 63 },
                     format: { with: /\A[a-z0-9][a-z0-9\-]*\z/, message: 'only lowercase letters, numbers, and hyphens' },
                     exclusion: { in: RESERVED_SLUGS, message: 'is reserved' }
    validate :validate_search_collections

    def self.permitted_params
      [:project_id, :name, :slug,
       { config: {} }, { area: {} },
       { branding: {} }, { navigation: {} }]
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

    # The navbar document served to the renderer: the stored items, or a
    # sensible default (Explore + Posts) pointing at the default locale's routes.
    def to_navigation(default_locale = 'en')
      items = (navigation || {}).deep_stringify_keys['items']

      items = default_navigation_items(default_locale) if items.blank?

      { 'items' => items }
    end

    # The Typesense endpoint browsers reach (often differs from the internal
    # endpoint Rails indexes against, e.g. behind a proxy with TLS).
    def self.typesense_public_connection
      {
        'host' => ENV.fetch('TYPESENSE_PUBLIC_HOST') { ENV.fetch('TYPESENSE_HOST', 'localhost') },
        'port' => ENV.fetch('TYPESENSE_PUBLIC_PORT') { ENV.fetch('TYPESENSE_PORT', 8108) }.to_i,
        'protocol' => ENV.fetch('TYPESENSE_PUBLIC_PROTOCOL') { ENV.fetch('TYPESENSE_PROTOCOL', 'http') }
      }
    end

    # Emits the config.json document for this site: the stored config with
    # the platform-derived sections (core_data connection, search/Typesense
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

    # The starter navbar for a site that hasn't customized navigation:
    # Explore (the places search) and Posts, pointed at the default locale.
    def default_navigation_items(default_locale)
      [
        { '_template' => 'URL', 'label' => 'Explore', 'href' => "/#{default_locale}/search/places" },
        { '_template' => 'URL', 'label' => 'Posts', 'href' => "/#{default_locale}/posts" }
      ]
    end

    # Expands a stored search entry: the search_collection_id reference
    # becomes the full Typesense block (public connection + collection name +
    # search-only key), with any stored typesense values kept as overrides.
    # Facet include lists default to the entry's configured facets.
    def expand_search_entry(entry)
      expanded = entry.deep_dup
      collection_id = expanded.delete('search_collection_id')

      collection = search_collections_by_id[collection_id.to_i] if collection_id.present?

      typesense = expanded['typesense'] || {}

      if collection.present?
        typesense = self.class.typesense_public_connection
                        .merge(
                          'index_name' => collection.name,
                          'api_key' => collection.search_only_key
                        )
                        .merge(typesense)
                        .compact
      end

      facet_names = (expanded['facets'] || []).map { |facet| facet['name'] }.compact

      if facet_names.present? && typesense.dig('facets', 'include').blank?
        typesense['facets'] = (typesense['facets'] || {}).merge('include' => facet_names)
      end

      expanded['typesense'] = typesense if typesense.present?
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
