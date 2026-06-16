module CoreDataConnector
  module PlaceImports
    # Area-scoped bulk-import sources. Each source wraps an Authority::*
    # API client and yields normalized place records:
    #
    #   {
    #     'identifier' => <authority id, string>,
    #     'name'       => <primary name>,
    #     'longitude'  => Float, 'latitude' => Float,
    #     'in_area'    => <false when the record is inside the queried bbox
    #                      but outside the drawn polygon>,
    #     'extra'      => <source metadata kept on the web_identifier>
    #   }
    module Sources
      def self.for(web_authority, area:, filters: {})
        case web_authority.source_type
        when 'geonames'
          Geonames.new(web_authority, area:, filters:)
        when 'wikidata'
          Wikidata.new(web_authority, area:, filters:)
        else
          raise ArgumentError, "Bulk import is not supported for source: #{web_authority.source_type}"
        end
      end
    end
  end
end
