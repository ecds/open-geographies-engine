require 'rgeo/geo_json'

module CoreDataConnector
  module PlaceImports
    # Resolves the wizard's area document for authority imports:
    #
    #   {
    #     "geometry_json" => <GeoJSON geometry/Feature/FeatureCollection>,
    #     "admin_units"   => [{ "geoname_id" =>, "country" =>,
    #                           "admin_code1" =>, "admin_code2" => }, ...]
    #   }
    #
    # Authority APIs only support box (or admin-code) queries, so a drawn
    # polygon is queried by its bounding box and results are post-filtered
    # here with #contains?.
    class Area
      attr_reader :document

      def initialize(document)
        @document = (document || {}).deep_stringify_keys
      end

      def admin_units
        document['admin_units'] || []
      end

      # The bounding box of the area geometry, as string-keyed and
      # symbol-keyed-friendly floats; nil when the document has no geometry.
      def bbox
        return @bbox if defined?(@bbox)

        @bbox = compute_bbox
      end

      # Point-in-polygon post-filter. True when the area has no polygonal
      # geometry (bbox- or admin-scoped imports take every result).
      def contains?(longitude, latitude)
        return true if polygon.nil?

        polygon.contains?(factory.point(longitude, latitude))
      rescue StandardError
        # An exotic/invalid polygon shouldn't drop records silently — fall
        # back to the bbox the query already applied.
        true
      end

      private

      # Unwraps Feature/FeatureCollection documents (map-draw tools emit
      # these) down to a plain geometry hash.
      def geometry
        return @geometry if defined?(@geometry)

        @geometry =
          case document.dig('geometry_json', 'type')
          when 'Feature'
            document.dig('geometry_json', 'geometry')
          when 'FeatureCollection'
            features = document.dig('geometry_json', 'features') || []
            features.first&.dig('geometry')
          else
            document['geometry_json']
          end
      end

      def compute_bbox
        coordinates = geometry&.dig('coordinates')
        return nil if coordinates.blank?

        longitudes = []
        latitudes = []

        walk = lambda do |node|
          if node.is_a?(Array) && node.length >= 2 && node[0].is_a?(Numeric)
            longitudes << node[0].to_f
            latitudes << node[1].to_f
          elsif node.is_a?(Array)
            node.each { |child| walk.call(child) }
          end
        end

        walk.call(coordinates)

        return nil if longitudes.empty?

        {
          west: longitudes.min,
          south: latitudes.min,
          east: longitudes.max,
          north: latitudes.max
        }
      end

      # Projected factory: the geographic spherical factory does not support
      # containment analysis.
      def factory
        @factory ||= RGeo::Geographic.simple_mercator_factory
      end

      def polygon
        return @polygon if defined?(@polygon)

        @polygon =
          if geometry.present? && %w[Polygon MultiPolygon].include?(geometry['type'])
            RGeo::GeoJSON.decode(geometry.to_json, geo_factory: factory, json_parser: :json)
          end
      end
    end
  end
end
