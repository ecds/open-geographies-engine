# frozen_string_literal: true

require 'json'

module CoreDataConnector
  module DatasetImports
    # Turns one row into a GeoJSON geometry according to the column mapping:
    #
    #   { 'mode' => 'feature' }                                     a GeoJSON feature's own geometry
    #   { 'mode' => 'latlon', 'latitude' => col, 'longitude' => col } two coordinate columns
    #   { 'mode' => 'wkt', 'column' => col }                        a WKT column ("POINT (-84.38 33.77)")
    #   { 'mode' => 'geojson', 'column' => col }                    a column holding GeoJSON text
    #   { 'mode' => 'column', 'column' => col }                     either of those, decided per value
    #   { 'mode' => 'none' }                                        no geometry
    #
    # Coordinates must be longitude/latitude in degrees (WGS 84). A value
    # outside that range almost always means a projected coordinate system,
    # which is reported rather than guessed at.
    module Geometry
      LATITUDE = /\A(lat|latitude|y|lat_?dd|decimal_?latitude|lat_?y|y_?coord(inate)?)\z/i
      LONGITUDE = /\A(lon|lng|long|longitude|x|lon_?dd|long_?dd|decimal_?longitude|lon_?x|x_?coord(inate)?)\z/i
      GEOMETRY_COLUMN = /\A(geometry|geom|the_geom|wkt|shape|geojson|footprint|location)\z/i
      WKT = /\A\s*(SRID=\d+;\s*)?(POINT|LINESTRING|POLYGON|MULTIPOINT|MULTILINESTRING|MULTIPOLYGON|GEOMETRYCOLLECTION)\b/i
      TYPES = %w[Point MultiPoint LineString MultiLineString Polygon MultiPolygon GeometryCollection].freeze

      # Formats whose rows carry their own geometry.
      FEATURE_FORMATS = %w[geojson shapefile].freeze

      class Error < StandardError; end

      module_function

      # Returns [geometry_hash, nil], [nil, nil] when the row has no
      # geometry, or [nil, message] when it has one that can't be used.
      def resolve(row, mapping)
        geometry = case mapping['mode']
                   when 'feature' then row[:geometry]
                   when 'latlon' then point(row[:properties][mapping['latitude']], row[:properties][mapping['longitude']])
                   when 'wkt' then from_wkt(row[:properties][mapping['column']])
                   when 'geojson' then from_geojson_text(row[:properties][mapping['column']])
                   when 'column' then from_text(row[:properties][mapping['column']])
                   end

        return [nil, nil] if geometry.nil?

        validate!(geometry)
        [geometry, nil]
      rescue Error => e
        [nil, e.message]
      end

      # The mapping a file most likely wants, from its headers and a sample
      # of its rows.
      def detect(format, columns, rows)
        return { 'mode' => 'feature' } if FEATURE_FORMATS.include?(format) && rows.any? { |row| row[:geometry] }

        latitude = columns.find { |c| c.match?(LATITUDE) }
        longitude = columns.find { |c| c.match?(LONGITUDE) }
        return { 'mode' => 'latlon', 'latitude' => latitude, 'longitude' => longitude } if latitude && longitude

        column = columns.find { |c| c.match?(GEOMETRY_COLUMN) } ||
                 columns.find { |c| rows.any? { |row| row[:properties][c].to_s.match?(WKT) } }
        return { 'mode' => 'none' } unless column

        sample = rows.lazy.map { |row| row[:properties][column] }.find(&:present?).to_s
        { 'mode' => sample.lstrip.start_with?('{') ? 'geojson' : 'wkt', 'column' => column }
      end

      def point(latitude, longitude)
        return nil if latitude.blank? && longitude.blank?
        raise Error, 'has a latitude but no longitude, or the reverse' if latitude.blank? || longitude.blank?

        { 'type' => 'Point', 'coordinates' => [number(longitude, 'longitude'), number(latitude, 'latitude')] }
      end

      def from_text(text)
        text.to_s.lstrip.start_with?('{') ? from_geojson_text(text) : from_wkt(text)
      end

      # The mapping implied by the curator's column roles.
      def mapping_for(format, columns)
        role = ->(name) { columns.find { |c| c['role'] == name }&.dig('name') }

        if role.call('latitude') && role.call('longitude')
          { 'mode' => 'latlon', 'latitude' => role.call('latitude'), 'longitude' => role.call('longitude') }
        elsif role.call('geometry')
          { 'mode' => 'column', 'column' => role.call('geometry') }
        elsif FEATURE_FORMATS.include?(format)
          { 'mode' => 'feature' }
        else
          { 'mode' => 'none' }
        end
      end

      def from_wkt(text)
        return nil if text.blank?

        parser = RGeo::WKRep::WKTParser.new(RGeo::Cartesian.simple_factory(srid: 4326), support_ewkt: true)
        RGeo::GeoJSON.encode(parser.parse(text)).as_json
      rescue RGeo::Error::ParseError, RGeo::Error::InvalidGeometry => e
        raise Error, "has WKT that could not be read (#{e.message.truncate(80)})"
      end

      def from_geojson_text(text)
        return nil if text.blank?

        value = JSON.parse(text)
        value = value['geometry'] if value['type'] == 'Feature'
        value
      rescue JSON::ParserError
        raise Error, 'has geometry text that is not GeoJSON'
      end

      def validate!(geometry)
        raise Error, 'has a geometry of unknown type' unless geometry.is_a?(Hash) && TYPES.include?(geometry['type'])

        coordinates = positions(geometry)
        raise Error, 'has an empty geometry' if coordinates.empty?

        outside = coordinates.find { |lon, lat| !lon.is_a?(Numeric) || !lat.is_a?(Numeric) || lon.abs > 180 || lat.abs > 90 }
        return unless outside

        raise Error, "has coordinates outside longitude/latitude range (#{outside.first(2).join(', ')}); " \
                     'the file may use a projected coordinate system — re-export it as EPSG:4326'
      end

      # Every [lon, lat] position in a geometry.
      def positions(geometry)
        if geometry['type'] == 'GeometryCollection'
          Array(geometry['geometries']).flat_map { |g| positions(g) }
        else
          flatten_positions(geometry['coordinates'])
        end
      end

      def flatten_positions(value)
        return [] unless value.is_a?(Array)
        return [value] if value.first.is_a?(Numeric) || value.first.nil? && value.size >= 2

        value.flat_map { |item| flatten_positions(item) }
      end

      def number(value, label)
        text = value.to_s.strip
        text = text.tr(',', '.') if text.match?(/\A-?\d+,\d+\z/)
        Float(text)
      rescue ArgumentError, TypeError
        raise Error, "has a #{label} that is not a number (#{value.to_s.truncate(24)})"
      end
    end
  end
end
