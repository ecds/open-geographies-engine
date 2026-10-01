# frozen_string_literal: true

require 'csv'
require 'net/http'

module CoreDataConnector
  module DatasetImports
    # Finding where a place is from its address, for uploaded rows that have
    # no coordinates: a curator's spreadsheet of buildings with street
    # addresses ("100 East Bay Street", Savannah). The curator says which
    # columns make the address (or types a city or state that applies to
    # every row); the preview looks the rows up so the curator sees what was
    # found before importing, and the import does the same for every row.
    #
    # One provider today: the U.S. Census Bureau's batch geocoder — free, no
    # key, public-domain results, U.S. street addresses only. A match is
    # `exact` or `approximate` (the Census's Non_Exact: "1002 Drayton Street
    # (House)" → 1002 DRAYTON ST); an intersection ("Bay & Bull Streets") is
    # a `tie` and a description ("Cockspur Island") `not_found`, both left
    # without a location. A match in another town than the row's city
    # (approximate matching can drop the city: "Corner of Louisville Road &
    # West Broad Street", Savannah → a Louisville Road 50 miles inland) is
    # `other_town`, also left without one. `OG_GEOCODER=none` turns lookups
    # off.
    module Geocoder
      Result = Struct.new(:status, :latitude, :longitude, :matched, keyword_init: true) do
        def found?(exact_only: false)
          exact_only ? status == 'exact' : %w[exact approximate].include?(status)
        end
      end

      class Unavailable < StandardError; end

      PROVIDER = 'the U.S. Census Bureau'

      # Header hints for the columns an address is made of.
      STREET = /\A(street_?)?address(_?1)?\z|\Astreet\z|\Aaddr\z|\Alocation\z|\Asite_?address\z|\Aproperty_?address\z/i
      CITY = /\A(city|town|municipality|locality|place_?name_?city)\z/i
      STATE = /\A(state|st|state_?code|province|region)\z/i
      ZIP = /\A(zip|zip_?code|zipcode|postal_?code|postcode)\z/i
      PARTS = %w[street city state zip].freeze

      # A place named by its address ("621 Ruben Street (House)", "Building
      # at 12 Main St" doesn't count): used when its street column is empty.
      NAMED_BY_ADDRESS = /\A\d+[A-Za-z]?(?:-\d+[A-Za-z]?)?\s+\S/

      module_function

      def available?
        ENV.fetch('OG_GEOCODER', 'census') != 'none'
      end

      # The columns most likely to make up an address, by their headers.
      def suggest(columns)
        {
          'street' => columns.find { |c| c.match?(STREET) } || columns.find { |c| c.match?(/address|street/i) },
          'city' => columns.find { |c| c.match?(CITY) },
          'state' => columns.find { |c| c.match?(STATE) },
          'zip' => columns.find { |c| c.match?(ZIP) }
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

      # { key => [street, city, state, zip] } → { key => Result }.
      def locate(addresses)
        return {} if addresses.empty?
        raise Unavailable, 'Address lookup is turned off on this server.' unless available?

        addresses.each_slice(CensusBatch::CHUNK).each_with_object({}) do |chunk, results|
          results.merge!(CensusBatch.locate(chunk.to_h))
        end
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
              out << [index, *parts]
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
                Result.new(status:, latitude:, longitude:, matched: row[4])
              when 'Tie'
                Result.new(status: 'tie')
              else
                Result.new(status: 'not_found')
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
    end
  end
end
