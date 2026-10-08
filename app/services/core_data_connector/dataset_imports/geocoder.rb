# frozen_string_literal: true

require 'csv'
require 'digest'
require 'json'
require 'net/http'

module CoreDataConnector
  module DatasetImports
    # Finding where a place is from its address, for uploaded rows that have
    # no coordinates: a curator's spreadsheet of buildings with street
    # addresses ("100 East Bay Street", Savannah). The curator says which
    # columns make the address (or types a city, state or country that
    # applies to every row); the preview looks the rows up so the curator
    # sees what was found before importing, and the import does the same for
    # every row.
    #
    # Two providers, chosen per row by its country:
    #
    # - The U.S. Census Bureau's batch geocoder for U.S. addresses: free, no
    #   key, public-domain results, thousands of rows a request. A match is
    #   `exact` or `approximate` (the Census's Non_Exact: "1002 Drayton
    #   Street (House)" → 1002 DRAYTON ST); an intersection ("Bay & Bull
    #   Streets") is a `tie` and a description ("Cockspur Island")
    #   `not_found`, both left without a location. A match in another town
    #   than the row's city (approximate matching can drop the city) is
    #   `other_town`, also left without one.
    # - OpenStreetMap's Nominatim for every other country, and for rows with
    #   no country that the Census didn't find (a spreadsheet of Nairobi
    #   buildings works without anyone saying "Kenya"). See Nominatim below
    #   for its limits.
    #
    # `OG_GEOCODER=none` turns lookups off; `OG_NOMINATIM_URL=none` keeps
    # them to U.S. addresses.
    module Geocoder
      Result = Struct.new(:status, :latitude, :longitude, :matched, :source, keyword_init: true) do
        def found?(exact_only: false)
          exact_only ? status == 'exact' : %w[exact approximate].include?(status)
        end
      end

      class Unavailable < StandardError; end

      CENSUS = 'the U.S. Census Bureau'
      OPENSTREETMAP = 'OpenStreetMap'

      # Header hints for the columns an address is made of.
      STREET = /\A(street_?)?address(_?1)?\z|\Astreet\z|\Aaddr\z|\Alocation\z|\Asite_?address\z|\Aproperty_?address\z/i
      CITY = /\A(city|town|municipality|locality|place_?name_?city)\z/i
      STATE = /\A(state|st|state_?code|province|region|county)\z/i
      ZIP = /\A(zip|zip_?code|zipcode|postal_?code|postcode)\z/i
      COUNTRY = /\A(country|country_?name|country_?code|nation)\z/i
      PARTS = %w[street city state zip country].freeze

      # What a curator calls the United States, in a Country column or typed.
      UNITED_STATES = /\A(u\.?\s?s\.?(\s?a\.?)?|united\s+states(\s+of\s+america)?|america)\z/i

      # A place named by its address ("621 Ruben Street (House)", "Building
      # at 12 Main St" doesn't count): used when its street column is empty.
      NAMED_BY_ADDRESS = /\A\d+[A-Za-z]?(?:-\d+[A-Za-z]?)?\s+\S/

      module_function

      def available?
        ENV.fetch('OG_GEOCODER', 'census') != 'none'
      end

      # The providers this server looks addresses up with, for the console.
      def provider_label
        Nominatim.available? ? "#{CENSUS} (U.S. addresses) and #{OPENSTREETMAP} (everywhere else)" : "#{CENSUS} (U.S. addresses only)"
      end

      # The columns most likely to make up an address, by their headers.
      def suggest(columns)
        {
          'street' => columns.find { |c| c.match?(STREET) } || columns.find { |c| c.match?(/address|street/i) },
          'city' => columns.find { |c| c.match?(CITY) },
          'state' => columns.find { |c| c.match?(STATE) },
          'zip' => columns.find { |c| c.match?(ZIP) },
          'country' => columns.find { |c| c.match?(COUNTRY) }
        }.compact
      end

      # The address parts for a row: each part from its column, or the text
      # the curator typed for it ({ 'street' => 'Location', 'city_value' =>
      # 'Savannah', 'state_value' => 'GA' }). With no street, a name that is
      # an address stands in for it.
      def parts_for(properties, config, name = nil)
        parts = PARTS.map do |part|
          column = config[part].presence
          value = column ? properties[column] : config["#{part}_value"]
          value.to_s.squish
        end

        parts[0] = name.to_s.squish if parts[0].blank? && name.to_s.match?(NAMED_BY_ADDRESS)
        parts
      end

      def usable?(config)
        config.is_a?(Hash) && config['street'].present?
      end

      # Which provider a row's address goes to: a U.S. address to the Census;
      # another country's to OpenStreetMap; no country, the Census first and
      # OpenStreetMap for what it didn't find.
      def route(parts)
        country = parts[4].to_s.strip
        return :census_first if country.empty?

        country.match?(UNITED_STATES) ? :census : :openstreetmap
      end

      # { key => [street, city, state, zip, country] } → { key => Result }.
      #
      # OpenStreetMap answers one address a second, so `openstreetmap_limit`
      # caps how many go to it: past it a row's Result is `beyond` (the
      # preview's "later", the import's "over_limit").
      def locate(addresses, openstreetmap_limit: Nominatim.limit, beyond: 'over_limit')
        return {} if addresses.empty?
        raise Unavailable, 'Address lookup is turned off on this server.' unless available?

        routes = addresses.to_h { |key, parts| [key, route(parts)] }
        results = {}

        census = addresses.reject { |key, _parts| routes[key] == :openstreetmap }
        begin
          census.each_slice(CensusBatch::CHUNK) { |chunk| results.merge!(CensusBatch.locate(chunk.to_h)) }
        rescue Unavailable
          # With OpenStreetMap to fall back on, rows without a country still
          # get a lookup; a U.S. row has nowhere else to go.
          raise unless Nominatim.available? && census.keys.none? { |key| routes[key] == :census }
        end

        return results unless Nominatim.available?

        rest = addresses.select do |key, _parts|
          routes[key] == :openstreetmap || (routes[key] == :census_first && !results[key]&.found? && results[key]&.status != 'tie')
        end
        results.merge!(Nominatim.locate(rest, limit: openstreetmap_limit, beyond:))
      end

      # The U.S. Census Bureau's batch endpoint: a CSV of "id, street, city,
      # state, zip" in, a CSV of matches out (up to 10,000 rows a request;
      # chunks are kept smaller so a request stays short).
      module CensusBatch
        URL = URI('https://geocoding.geo.census.gov/geocoder/locations/addressbatch')
        CHUNK = 1000

        module_function

        def locate(addresses)
          ids = {}
          csv = CSV.generate do |out|
            addresses.each_with_index do |(key, parts), index|
              ids[index.to_s] = key
              out << [index, *parts.first(4)]
            end
          end

          parse(post(csv), ids, addresses)
        end

        def post(csv)
          request = Net::HTTP::Post.new(URL)
          request.set_form([
            ['addressFile', StringIO.new(csv), { filename: 'addresses.csv', content_type: 'text/csv' }],
            ['benchmark', 'Public_AR_Current']
          ], 'multipart/form-data')

          response = Net::HTTP.start(URL.host, URL.port, use_ssl: true, open_timeout: 10, read_timeout: 180) do |http|
            http.request(request)
          end

          raise Unavailable, "The address lookup answered #{response.code}." unless response.is_a?(Net::HTTPSuccess)

          response.body.to_s.force_encoding('UTF-8')
        rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
          raise Unavailable, "The address lookup couldn't be reached (#{e.class.name.demodulize})."
        end

        # "id","input","Match","Exact","matched address","lon,lat","tiger id","side"
        def parse(body, ids, addresses)
          CSV.parse(body, liberal_parsing: true).each_with_object({}) do |row, results|
            key = ids[row[0].to_s]
            next unless key

            results[key] =
              case row[2]
              when 'Match'
                longitude, latitude = row[5].to_s.split(',').map(&:to_f)
                status = row[3] == 'Exact' ? 'exact' : 'approximate'
                status = 'other_town' if other_town?(row[4], addresses[key][1])
                Result.new(status:, latitude:, longitude:, matched: row[4], source: 'census')
              when 'Tie'
                Result.new(status: 'tie', source: 'census')
              else
                Result.new(status: 'not_found', source: 'census')
              end
          end
        end

        # "100 E BAY ST, SAVANNAH, GA, 31401": its town, against the row's.
        def other_town?(matched, city)
          return false if city.blank?

          town = matched.to_s.split(',')[-3].to_s.strip
          town.present? && !town.casecmp?(city.strip)
        end
      end

      # OpenStreetMap's Nominatim (https://nominatim.org): any country, one
      # address at a time. The public server (nominatim.openstreetmap.org)
      # asks for at most one request a second, an identifying User-Agent and
      # no bulk geocoding, so requests are spaced a second apart (per
      # process), answers are cached for 30 days, and an import sends it at
      # most PUBLIC_LIMIT addresses. A server of one's own (OG_NOMINATIM_URL)
      # has no cap unless OG_NOMINATIM_MAX_ROWS sets one.
      #
      # Each address is asked for in parts first (street, city, state,
      # postcode, country), then, if that finds nothing, as one line. A
      # match on a house number is `exact`; on a street or a place, or from
      # the one-line search, `approximate`, which the curator reviews.
      # Results are OpenStreetMap data (© OpenStreetMap contributors, ODbL):
      # the console says so.
      module Nominatim
        PUBLIC_URL = 'https://nominatim.openstreetmap.org'
        PUBLIC_LIMIT = 500
        INTERVAL = 1.0
        CACHE_TTL = 30.days
        LOCK = Mutex.new

        @last_request = 0.0

        class << self
          def url
            ENV.fetch('OG_NOMINATIM_URL', PUBLIC_URL).to_s.chomp('/')
          end

          def available?
            url != 'none' && url.present?
          end

          def public?
            url == PUBLIC_URL
          end

          # Addresses one import may send.
          def limit
            Integer(ENV['OG_NOMINATIM_MAX_ROWS'].presence || (public? ? PUBLIC_LIMIT : 1_000_000), exception: false) || PUBLIC_LIMIT
          end

          def locate(addresses, limit: self.limit, beyond: 'over_limit')
            addresses.each_with_index.to_h do |(key, parts), index|
              [key, index < limit ? lookup(parts) : Result.new(status: beyond, source: 'openstreetmap')]
            end
          end

          def lookup(parts)
            key = "og-nominatim:v1:#{Digest::SHA256.hexdigest(parts.map { |p| p.to_s.downcase }.join("\u001f"))}"
            cached = Rails.cache.read(key)
            return Result.new(**cached.symbolize_keys) if cached.is_a?(Hash)

            result = classify(search(structured(parts)), :structured)
            result = classify(search(q: parts.compact_blank.join(', ')), :line) unless result.found?
            Rails.cache.write(key, result.to_h, expires_in: CACHE_TTL)
            result
          end

          # [street, city, state, zip, country] as Nominatim's structured
          # query.
          def structured(parts)
            street, city, state, zip, country = parts
            { street:, city:, state:, postalcode: zip, country: }.compact_blank
          end

          # The first hit as a Result: a house-number match from the
          # structured search is exact, anything else approximate.
          def classify(hit, kind)
            return Result.new(status: 'not_found', source: 'openstreetmap') unless hit.is_a?(Hash) && hit['lat'] && hit['lon']

            exact = kind == :structured && hit.dig('address', 'house_number').present?
            Result.new(status: exact ? 'exact' : 'approximate', latitude: hit['lat'].to_f, longitude: hit['lon'].to_f,
                       matched: hit['display_name'], source: 'openstreetmap')
          end

          def search(params)
            uri = URI("#{url}/search")
            uri.query = URI.encode_www_form(params.merge(format: 'jsonv2', addressdetails: 1, limit: 1)
                                                  .merge(ENV['OG_NOMINATIM_EMAIL'].present? ? { email: ENV['OG_NOMINATIM_EMAIL'] } : {}))
            request = Net::HTTP::Get.new(uri, 'User-Agent' => user_agent, 'Accept' => 'application/json')

            response = throttled do
              Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
            end

            raise Unavailable, "OpenStreetMap's address lookup answered #{response.code}." unless response.is_a?(Net::HTTPSuccess)

            Array(JSON.parse(response.body.to_s)).first
          rescue JSON::ParserError
            nil
          rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
            raise Unavailable, "OpenStreetMap's address lookup couldn't be reached (#{e.class.name.demodulize})."
          end

          # Who's asking, as the usage policy wants: the platform, and how to
          # reach its operator.
          def user_agent
            contact = ENV['OG_NOMINATIM_EMAIL'].presence || ENV['CORE_DATA_PUBLIC_URL'].presence
            "OpenGeographies/1.0 (atlas address lookup#{"; #{contact}" if contact})"
          end

          # At most one request each INTERVAL from this process.
          def throttled
            LOCK.synchronize do
              wait = @last_request + INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              sleep(wait) if wait.positive?
              yield
            ensure
              @last_request = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end
      end
    end
  end
end
