# frozen_string_literal: true

require 'json'

module CoreDataConnector
  module DatasetImports
    class GeojsonReader < Reader
      def format = 'geojson'

      def columns
        load!
        @columns
      end

      def each_row
        load!

        @features.each_with_index do |feature, index|
          check_row_limit!(index)
          properties = @columns.to_h { |column| [column, flatten(feature.dig('properties', column))] }
          yield({ index:, properties:, geometry: feature['geometry'] })
        end
      end

      private

      def load!
        return if @features

        document = JSON.parse(read_text)

        @features = case document['type']
                    when 'FeatureCollection' then Array(document['features'])
                    when 'Feature' then [document]
                    when String then [{ 'type' => 'Feature', 'properties' => {}, 'geometry' => document }]
                    else raise Invalid, 'This JSON is not GeoJSON (no FeatureCollection, Feature or geometry "type").'
                    end

        raise Invalid, 'The GeoJSON has no features.' if @features.empty?

        @columns = @features.each_with_object([]) do |feature, columns|
          (feature['properties'] || {}).each_key { |key| columns << key.to_s unless columns.include?(key.to_s) }
        end
      rescue JSON::ParserError => e
        raise Invalid, "The file is not valid JSON: #{e.message.truncate(160)}"
      end

      # Nested properties (objects, arrays) are kept as their JSON text.
      def flatten(value)
        case value
        when Hash, Array then value.to_json
        else clean(value)
        end
      end
    end
  end
end
