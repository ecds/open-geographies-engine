module CoreDataConnector
  module PlaceImports
    module Sources
      # Wikidata area import via SPARQL: a geo box query over P625
      # coordinates, optionally filtered by instance-of trees
      # (filters['types'] = ['Q33506', ...] matched through P31/P279*).
      # Admin-unit scoping (P131 containment) is a planned fast-follow; the
      # v1 picker is GeoNames-only.
      class Wikidata < Base
        PAGE_SIZE = 500

        # WDQS etiquette between paged queries.
        PAGE_DELAY = 1

        POINT_PATTERN = /\APoint\((-?\d+\.?\d*) (-?\d+\.?\d*)\)\z/

        def count
          @count ||= begin
            response = sparql(count_query)
            bindings = response.dig('results', 'bindings') || []

            bindings.first&.dig('count', 'value').to_i
          end
        end

        def each_record
          seen = Set.new
          offset = 0

          loop do
            response = sparql(page_query(offset:))
            bindings = response.dig('results', 'bindings') || []

            break if bindings.empty?

            bindings.each do |binding|
              record = normalize(binding)
              next if record.nil? || seen.include?(record['identifier'])

              seen << record['identifier']

              yield record
            end

            offset += PAGE_SIZE
            break if bindings.length < PAGE_SIZE

            sleep PAGE_DELAY
          end
        end

        private

        def client
          @client ||= Authority::Wikidata.new
        end

        def sparql(query)
          response = raise_response_errors!(client.sparql(query))

          raise 'Wikidata returned an unexpected response (possible query timeout)' unless response.is_a?(Hash) && response['results'].present?

          response
        end

        # Q-ids are validated before interpolation; bbox values are floats.
        def types
          @types ||= Array(filters['types']).map(&:to_s).select { |type| type.match?(/\AQ\d+\z/) }
        end

        def where_clause
          bbox = area.bbox
          raise ArgumentError, 'Wikidata import requires an area geometry (bbox)' if bbox.nil?

          clauses = [<<~SPARQL]
            SERVICE wikibase:box {
              ?item wdt:P625 ?coord .
              bd:serviceParam wikibase:cornerSouthWest "Point(#{bbox[:west].to_f} #{bbox[:south].to_f})"^^geo:wktLiteral .
              bd:serviceParam wikibase:cornerNorthEast "Point(#{bbox[:east].to_f} #{bbox[:north].to_f})"^^geo:wktLiteral .
            }
          SPARQL

          if types.present?
            clauses << "VALUES ?cls { #{types.map { |type| "wd:#{type}" }.join(' ')} }"
            clauses << '?item wdt:P31/wdt:P279* ?cls .'
          end

          clauses.join("\n")
        end

        def count_query
          <<~SPARQL
            SELECT (COUNT(DISTINCT ?item) AS ?count) WHERE {
              #{where_clause}
            }
          SPARQL
        end

        def page_query(offset:)
          <<~SPARQL
            SELECT DISTINCT ?item ?itemLabel ?coord WHERE {
              #{where_clause}
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en,[AUTO_LANGUAGE]". }
            }
            ORDER BY ?item
            LIMIT #{PAGE_SIZE}
            OFFSET #{offset.to_i}
          SPARQL
        end

        def normalize(binding)
          qid = binding.dig('item', 'value').to_s.split('/').last
          match = POINT_PATTERN.match(binding.dig('coord', 'value').to_s)

          return nil if qid.blank? || match.nil?

          longitude = match[1].to_f
          latitude = match[2].to_f

          label = binding.dig('itemLabel', 'value').presence

          {
            'identifier' => qid,
            # Items without an English label fall back to the Q-id label
            # WDQS emits; keep it — the identifier preserves provenance.
            'name' => label || qid,
            'longitude' => longitude,
            'latitude' => latitude,
            'in_area' => area.contains?(longitude, latitude),
            'extra' => { 'types' => types.presence }.compact
          }
        end
      end
    end
  end
end
