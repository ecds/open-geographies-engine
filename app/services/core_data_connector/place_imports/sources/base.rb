module CoreDataConnector
  module PlaceImports
    module Sources
      class Base
        attr_reader :web_authority, :area, :filters, :access, :warnings

        def initialize(web_authority, area:, filters: {})
          @web_authority = web_authority
          @area = Area.new(area)
          @filters = (filters || {}).deep_stringify_keys
          @access = (web_authority.access || {}).symbolize_keys
          @warnings = []
        end

        # Total matching records as reported by the authority (the bbox
        # count — a drawn polygon filters further during iteration).
        def count
          raise NotImplementedError
        end

        # Yields every normalized record the area query returns, paging
        # internally. Records outside a drawn polygon are yielded with
        # 'in_area' => false so callers can count them against #count.
        def each_record
          raise NotImplementedError
        end

        # The wizard's pre-import preview: the total count plus up to limit
        # in-area records for the map.
        def preview(limit: 500)
          records = []

          catch(:preview_full) do
            each_record do |record|
              next unless record['in_area']

              records << record.except('in_area')

              throw :preview_full if records.length >= limit
            end
          end

          {
            'count' => count,
            'sample' => records,
            'warnings' => warnings.presence
          }.compact
        end

        private

        # Authority HTTP failures surface as { errors: [...] } from
        # Http::Requestable rather than exceptions; bulk imports need them
        # raised so the job fails (or the preview 422s) with the message.
        def raise_response_errors!(response)
          errors = response['errors'] if response.is_a?(Hash)

          raise errors.join('; ') if errors.present?

          response
        end
      end
    end
  end
end
