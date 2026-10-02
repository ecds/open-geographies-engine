# frozen_string_literal: true

require 'resolv'
require 'uri'

module CoreDataConnector
  # An atlas's own domain (atlas.example.org), besides its address on the
  # platform (<slug>.<base domain>, from OG_ATLAS_URL_TEMPLATE).
  #
  # A domain is stored as entered (cleaned up: no scheme, path, port or
  # trailing dot, lower case) but served only once it's *connected*: its DNS
  # names this atlas, either
  #
  # - a CNAME to the atlas's platform address (atlas.example.org →
  #   savannah.atlas.example.edu), for a subdomain, or
  # - a TXT record at _open-geographies.<domain> whose value is the atlas's
  #   slug, for a root domain (which can't have a CNAME; it points at the
  #   renderer with A/ALIAS records).
  #
  # The DNS is the proof: only whoever controls a domain can make it name an
  # atlas, so a curator can't take someone else's domain by typing it in,
  # and an atlas isn't sent to its new domain before the domain reaches it.
  # Several atlases may have entered the same domain; the one its DNS names
  # gets it, taking it from another atlas if the DNS has moved.
  #
  # Development servers also accept <name>.<name>.localhost domains, which
  # connect without DNS (browsers resolve them to this machine), first come
  # first served.
  module SiteDomains
    TXT_PREFIX = '_open-geographies'
    LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    DNS_TIMEOUT = 3

    # The outcome of a DNS check: connected or not, how (:cname, :txt,
    # :local) and a sentence for the curator.
    Check = Struct.new(:connected, :how, :message, keyword_init: true)

    # The domain in `value` as stored: lower case, without a scheme, user,
    # path, query, port or trailing dot ("HTTPS://Atlas.Example.org/about"
    # → "atlas.example.org"); nil when blank.
    def self.normalize(value)
      text = value.to_s.strip.downcase
      return nil if text.empty?

      text = text.sub(%r{\A[a-z][a-z0-9+.-]*://}, '')
      text = text.split(%r{[/?#]}, 2).first.to_s
      text = text.split('@').last.to_s
      text = text.sub(/:\d*\z/, '')
      text.sub(/\.+\z/, '').presence
    end

    # Why `domain` can't be an atlas's domain, as a sentence; nil when it can.
    def self.problem(domain)
      return nil if domain.blank?
      return 'Write the domain in plain letters (an accented domain in its xn-- form).' unless domain.ascii_only?

      labels = domain.split('.', -1)

      if domain.length > 253 || labels.size < 2 || !labels.all? { |label| LABEL.match?(label) } || labels.last.match?(/\A\d+\z/)
        return "“#{domain}” isn’t a domain name. Write it like atlas.example.org."
      end

      if labels.last == 'localhost'
        return 'Local (.localhost) domains only work on a development server.' unless local_names_allowed?
        return "#{domain} is an atlas address on this server. Use a name like atlas.test.localhost." if labels.size < 3
      end

      base = base_domain
      if base
        return "#{domain} is where every atlas on this platform lives. Use a domain of your own." if domain == base

        if domain.end_with?(".#{base}") && !domain.delete_suffix(".#{base}").include?('.')
          return "#{domain} is an atlas address on this platform. Use a domain of your own."
        end
      end

      return "#{domain} is the console’s address." if domain == console_host

      nil
    end

    # The platform's base domain, from OG_ATLAS_URL_TEMPLATE
    # ("https://{slug}.atlas.example.edu" → "atlas.example.edu"); nil when
    # the template is unset or doesn't put the slug in a subdomain.
    def self.base_domain
      template = ENV['OG_ATLAS_URL_TEMPLATE'].presence
      return nil unless template

      host = URI.parse(template.gsub('{slug}', 'og-slug')).host.to_s.downcase
      host.start_with?('og-slug.') ? host.delete_prefix('og-slug.') : nil
    rescue URI::InvalidURIError
      nil
    end

    # An atlas's address on the platform, the CNAME target for its domain.
    def self.platform_host(slug)
      base = base_domain
      base && slug.present? ? "#{slug}.#{base}" : nil
    end

    # The DNS records that connect `domain` to the atlas `slug`, for the
    # console's instructions.
    def self.instructions(domain, slug)
      return nil if domain.blank?

      {
        cname: platform_host(slug),
        txt_name: "#{TXT_PREFIX}.#{domain}",
        txt_value: slug,
        local: local_name?(domain)
      }
    end

    # Checks whether `site`'s domain names it. Doesn't save anything (see
    # Site#check_domain!).
    def self.check(site)
      domain = site.domain
      return nil if domain.blank?

      holder = Site.where(domain:).where.not(id: site.id).where.not(domain_verified_at: nil).exists?

      if local_name?(domain)
        return Check.new(connected: false, message: "#{domain} is already connected to another atlas.") if holder

        return Check.new(connected: true, how: :local, message: "#{domain} is connected.")
      end

      how = dns_names(domain, site.slug)
      return Check.new(connected: true, how:, message: "#{domain} is connected: its DNS points at this atlas.") if how

      message = if holder
                  "#{domain} is connected to another atlas. It moves to this one when its DNS points here."
                else
                  "#{domain}’s DNS doesn’t point at this atlas yet. DNS changes can take a few hours to reach everywhere; check again later."
                end

      Check.new(connected: false, message:)
    end

    # :cname or :txt when the DNS for `domain` names the atlas `slug`, else
    # nil (no record, another target, or no answer in time).
    def self.dns_names(domain, slug)
      target = platform_host(slug)

      Resolv::DNS.open do |dns|
        dns.timeouts = DNS_TIMEOUT

        if target
          cnames = dns.getresources(domain, Resolv::DNS::Resource::IN::CNAME).map { |record| record.name.to_s.downcase.chomp('.') }
          return :cname if cnames.include?(target)
        end

        values = dns.getresources("#{TXT_PREFIX}.#{domain}", Resolv::DNS::Resource::IN::TXT).map { |record| record.strings.join.strip.downcase }
        return :txt if values.include?(slug)
      end

      nil
    rescue Resolv::ResolvError, SocketError, SystemCallError
      nil
    end

    def self.local_name?(domain)
      domain.to_s.end_with?('.localhost') && local_names_allowed?
    end

    def self.local_names_allowed?
      Rails.env.local?
    end

    def self.console_host
      url = ENV['CORE_DATA_PUBLIC_URL'].presence
      url && URI.parse(url).host&.downcase
    rescue URI::InvalidURIError
      nil
    end
  end
end
