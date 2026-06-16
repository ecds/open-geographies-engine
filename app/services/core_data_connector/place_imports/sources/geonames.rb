module CoreDataConnector
  module PlaceImports
    module Sources
      # GeoNames area import: one query set per admin unit (country +
      # adminCode1/adminCode2), or a single bbox query set when the area is
      # a drawn geometry. Filters: feature_classes / feature_codes (GeoNames
      # fcl/fcode), name (free-text q).
      class Geonames < Base
        PAGE_SIZE = 1000

        # The free tier rejects startRow beyond 5000; deeper result sets
        # need narrower areas or filters.
        MAX_START_ROW = 5000

        # Stay friendly to the hourly credit limit.
        PAGE_DELAY = 0.5

        def count
          @count ||= query_sets.sum { |query_set| total_for(query_set) }
        end

        def each_record
          seen = Set.new

          query_sets.each do |query_set|
            total = total_for(query_set)
            start_row = 0

            while start_row < total
              if start_row > MAX_START_ROW
                warning = "GeoNames paging ceiling reached for #{query_set.inspect}: " \
                          "#{total - start_row} of #{total} records not fetched. " \
                          'Narrow the area or filters to import the remainder.'
                warnings << warning

                break
              end

              page = fetch_page(query_set, start_row)
              break if page.empty?

              page.each do |geoname|
                identifier = geoname['geonameId'].to_s

                # Admin units can overlap (and a record can sit on a
                # boundary); first unit wins.
                next if seen.include?(identifier)

                seen << identifier

                yield normalize(geoname)
              end

              start_row += PAGE_SIZE

              sleep PAGE_DELAY if start_row < total
            end
          end
        end

        private

        def username
          access[:username].presence || ENV.fetch('GEONAMES_USERNAME', nil)
        end

        def client
          @client ||= Authority::Geonames.new
        end

        # One options hash per searchJSON invocation (minus paging).
        def query_sets
          @query_sets ||= begin
            base = {
              username:,
              q: filters['name'].presence,
              feature_classes: filters['feature_classes'],
              feature_codes: filters['feature_codes']
            }.compact

            if area.admin_units.present?
              area.admin_units.map do |unit|
                unit = unit.deep_stringify_keys

                base.merge(
                  country: unit['country'],
                  admin_code1: unit['admin_code1'],
                  admin_code2: unit['admin_code2']
                ).compact
              end
            elsif area.bbox.present?
              [base.merge(bbox: area.bbox)]
            else
              raise ArgumentError, 'GeoNames import requires admin units or an area geometry'
            end
          end
        end

        def total_for(query_set)
          @totals ||= {}

          @totals[query_set] ||= begin
            response = request(query_set.merge(max_rows: 1))
            response['totalResultsCount'].to_i
          end
        end

        def fetch_page(query_set, start_row)
          response = request(query_set.merge(max_rows: PAGE_SIZE, start_row:))
          response['geonames'] || []
        end

        def request(options)
          response = raise_response_errors!(client.search_area(options))

          # GeoNames reports its own errors (bad credentials, rate limits)
          # as 200s with a status document.
          status = response['status'] if response.is_a?(Hash)
          raise "GeoNames error: #{status['message']}" if status.present?

          response
        end

        def normalize(geoname)
          longitude = geoname['lng'].to_f
          latitude = geoname['lat'].to_f

          {
            'identifier' => geoname['geonameId'].to_s,
            'name' => geoname['name'].presence || geoname['toponymName'],
            'longitude' => longitude,
            'latitude' => latitude,
            'in_area' => area.contains?(longitude, latitude),
            'extra' => geoname.slice('fcl', 'fclName', 'fcode', 'fcodeName', 'countryCode', 'adminName1', 'population')
          }
        end
      end
    end
  end
end
