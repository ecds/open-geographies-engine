# frozen_string_literal: true

require 'nokogiri'
require 'zip'

module CoreDataConnector
  module DatasetImports
    # KML (.kml) and KMZ (.kmz, a zip holding doc.kml): Google Earth, My Maps,
    # QGIS and GDAL exports. Each Placemark is a row:
    #
    # - Name, Description (HTML turned into text), Address;
    # - Dates, from a TimeStamp (one date) or a TimeSpan ("1819–1886"), read
    #   as a fuzzy date; the time of day is dropped;
    # - every ExtendedData value, typed (SchemaData/SimpleData) or not
    #   (Data/value), as a column of its own;
    # - Folder: the innermost folder the placemark is in (or the name of the
    #   network link it was reached through), which the upload proposes as
    #   the category when its values repeat.
    #
    # Geometry: Point, LineString, LinearRing (as a line), Polygon with holes,
    # MultiGeometry (MultiPoint/MultiLineString/MultiPolygon when its parts
    # share a type, else a GeometryCollection) and gx:Track / gx:MultiTrack (as
    # lines). Altitude is dropped. A placemark without one is a place without
    # a location.
    #
    # The file is read one placemark at a time (Nokogiri's pull reader), so a
    # large file is never held as a whole document. Nokogiri comes with Rails
    # (rails-html-sanitizer), so the gemspec declares nothing new. No network access, no
    # DTDs: a file declaring one is refused (KML never does), and entities are
    # never expanded. In a KMZ, network links to other .kml files inside the
    # same zip are followed (GDAL writes one file per layer that way); links to
    # the web are not, and image overlays are skipped — each with a warning.
    class KmlReader < Reader
      PARSE_OPTIONS = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
      FRAGMENT_OPTIONS = Nokogiri::XML::ParseOptions::RECOVER | Nokogiri::XML::ParseOptions::NONET

      # Columns every placemark can have, in this order; ExtendedData columns
      # come between Address and the time columns.
      NAME = 'Name'
      DESCRIPTION = 'Description'
      ADDRESS = 'Address'
      # Not "Date": a field labelled that collides with the index's own
      # `date` property.
      DATES = 'Dates'
      FOLDER = 'Folder'
      BUILT_IN = [NAME, DESCRIPTION, ADDRESS, DATES, FOLDER].freeze

      # A KMZ may unpack to much more than its 50 MB; reading stops past this.
      MAX_UNPACKED_BYTES = 250 * 1024 * 1024
      # Network links followed inside a KMZ, nested.
      MAX_LINK_DEPTH = 5

      OVERLAYS = %w[GroundOverlay ScreenOverlay PhotoOverlay].freeze
      BLOCK_TAGS = %w[p div li tr h1 h2 h3 h4 h5 h6 blockquote table ul ol dl dt dd pre].freeze

      class LimitedStream
        def initialize(io, reader)
          @io = io
          @reader = reader
        end

        def read(length = nil, buffer = nil)
          chunk = @io.read(length)
          @reader.count_unpacked!(chunk.bytesize) if chunk
          buffer ? buffer.replace(chunk || '') : chunk
        end
      end

      def initialize(path, kmz: false)
        super(path)
        @kmz = kmz
      end

      def format = 'kml'

      def columns
        load!
        @columns
      end

      def warnings
        load!
        @warnings
      end

      def each_row
        load!

        @rows.each_with_index do |row, index|
          yield({ index:, line: index + 1, properties: row[:properties], geometry: row[:geometry] })
        end
      end

      def count_unpacked!(bytes)
        @unpacked += bytes
        raise Invalid, unpacked_message if @unpacked > MAX_UNPACKED_BYTES
      end

      private

      def load!
        return if @rows

        @rows = []
        @data_columns = []
        @counts = Hash.new(0)
        @unpacked = 0

        if @kmz
          read_kmz
        else
          File.open(path, 'rb') { |file| read_document(file, folder: nil, entry: nil, depth: 0) }
        end

        raise Invalid, 'The file has no placemarks (KML places), so there is nothing to import.' if @rows.empty?

        build_columns
        build_warnings
      end

      # --- containers ----------------------------------------------------------

      def read_kmz
        Zip::File.open(path) do |zip|
          @zip = zip
          entries = zip.entries.reject { |e| e.directory? || e.name.start_with?('__MACOSX/') }
          main = entries.find { |e| e.name.casecmp?('doc.kml') } || entries.find { |e| e.name.downcase.end_with?('.kml') }
          raise Invalid, 'The KMZ holds no .kml file. A KMZ is a zip with doc.kml inside; check the file, or upload the .kml itself.' unless main

          @visited = Set[main.name]
          read_entry(main, folder: nil, depth: 0)
        end
      rescue Zip::Error => e
        raise Invalid, "The KMZ could not be opened (#{e.message.truncate(80)})."
      end

      def read_entry(entry, folder:, depth:)
        stream = entry.get_input_stream
        read_document(LimitedStream.new(stream, self), folder:, entry: entry.name, depth:)
      ensure
        stream&.close
      end

      # Walks one KML document: folders (for the Folder column), placemarks
      # (rows), network links (followed inside a KMZ) and overlays (counted).
      def read_document(io, folder:, entry:, depth:)
        reader = Nokogiri::XML::Reader(io, nil, nil, PARSE_OPTIONS)
        folders = [] # [{ depth:, name: }] for each open Folder
        skip_to = nil # depth of an element whose subtree was read whole

        reader.each do |node|
          if skip_to
            skip_to = nil if node.node_type == Nokogiri::XML::Reader::TYPE_END_ELEMENT && node.depth == skip_to
            next
          end

          if node.node_type == Nokogiri::XML::Reader::TYPE_DOCUMENT_TYPE
            raise Invalid, 'The file declares a DOCTYPE, which KML files never do; it was not read. Export it again from the program that made it.'
          end

          if node.node_type == Nokogiri::XML::Reader::TYPE_END_ELEMENT
            folders.pop if local_name(node) == 'Folder' && folders.last&.dig(:depth) == node.depth
            next
          end

          next unless node.node_type == Nokogiri::XML::Reader::TYPE_ELEMENT

          name = local_name(node)
          current = folders.reverse.find { |f| f[:name] }&.dig(:name) || folder

          case name
          when 'Folder'
            folders << { depth: node.depth, name: nil } unless node.empty_element?
          when 'name'
            # A folder's own name: its first <name> child.
            top = folders.last
            top[:name] = clean(element_text(node)) if top && top[:name].nil? && node.depth == top[:depth] + 1
          when 'Placemark'
            check_row_limit!(@rows.size)
            @rows << placemark(fragment(node), current)
            skip_to = node.depth unless node.empty_element?
          when 'NetworkLink'
            network_link(fragment(node), current, entry, depth)
            skip_to = node.depth unless node.empty_element?
          when *OVERLAYS
            @counts[:overlays] += 1
            skip_to = node.depth unless node.empty_element?
          end
        end
      rescue Nokogiri::XML::SyntaxError => e
        # The size check raises inside the parser's read, which libxml2
        # reports as an I/O error.
        raise Invalid, unpacked_message if @unpacked > MAX_UNPACKED_BYTES

        where = entry && @kmz ? " (#{entry})" : ''
        raise Invalid, "The KML#{where} is not valid XML: #{e.message.to_s.strip.truncate(160)}"
      end

      def network_link(element, folder, entry, depth)
        href = clean(child(child(element, 'Link') || child(element, 'Url'), 'href')&.text)
        name = clean(child(element, 'name')&.text)
        return if href.nil?

        if href.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
          @counts[:web_links] += 1
        elsif !@kmz
          @counts[:local_links] += 1
        else
          target = resolve(entry, href)
          linked = target && @zip.find_entry(target)

          if linked.nil? || !target.downcase.end_with?('.kml')
            @counts[:local_links] += 1
          elsif depth < MAX_LINK_DEPTH && @visited.add?(target)
            read_entry(linked, folder: name || folder, depth: depth + 1)
          end
        end
      end

      # A relative href inside a KMZ, from the entry that holds it.
      def resolve(entry, href)
        path = href.sub(/[?#].*\z/, '')
        return nil if path.empty? || path.start_with?('/')

        parts = File.dirname(entry.to_s).split('/').reject { |p| p == '.' || p.empty? }
        path.split('/').each do |part|
          next if part == '.' || part.empty?
          return nil if part == '..' && parts.empty?

          part == '..' ? parts.pop : parts << part
        end

        parts.join('/')
      end

      # --- placemarks ----------------------------------------------------------

      def placemark(element, folder)
        properties = {}
        properties[NAME] = clean(child(element, 'name')&.text)
        properties[DESCRIPTION] = description_text(child(element, 'description')&.text)
        properties[ADDRESS] = clean(child(element, 'address')&.text)

        properties[DATES] = time_text(element)
        properties[FOLDER] = folder

        data = extended_data(element).to_h
        data.each_key { |key| @data_columns << key unless @data_columns.include?(key) }

        { properties:, data:, geometry: placemark_geometry(element) }
      end

      # [[key, value]] in file order: typed SimpleData and untyped Data.
      def extended_data(element)
        data = child(element, 'ExtendedData')
        return [] unless data

        data.element_children.flat_map do |item|
          case local_name(item)
          when 'Data'
            key = clean(item['name']) || clean(child(item, 'displayName')&.text)
            key ? [[key, clean(child(item, 'value')&.text)]] : []
          when 'SchemaData'
            item.element_children.filter_map do |simple|
              next unless local_name(simple) == 'SimpleData' && clean(simple['name'])

              [clean(simple['name']), clean(simple.text)]
            end
          else
            []
          end
        end
      end

      # A placemark's time as one value the upload reads as a fuzzy date:
      # "1750" (TimeStamp), "1819–1886" (TimeSpan), or one end of an open span.
      def time_text(element)
        span = child(element, 'TimeSpan')
        if span
          from = time_value(child(span, 'begin')&.text)
          to = time_value(child(span, 'end')&.text)
          return [from, to].compact.join('–').presence if from.nil? || to.nil? || from != to

          return from
        end

        time_value(child(child(element, 'TimeStamp'), 'when')&.text)
      end

      # KML times are XML Schema dates: 1819, 1819-03, 1819-03-01, or with a
      # time of day (1819-03-01T09:00:00Z), which is dropped.
      def time_value(text)
        clean(text)&.sub(/T.*\z/, '')
      end

      # --- geometry ------------------------------------------------------------

      GEOMETRY_TYPES = %w[Point LineString LinearRing Polygon MultiGeometry Track MultiTrack Model].freeze

      def placemark_geometry(element)
        shape = element.element_children.find { |c| GEOMETRY_TYPES.include?(local_name(c)) }
        return nil unless shape

        geometry(shape)
      end

      def geometry(element)
        case local_name(element)
        when 'Point'
          position = coordinates(element).first
          position && { 'type' => 'Point', 'coordinates' => position }
        when 'LineString', 'LinearRing'
          line(coordinates(element))
        when 'Polygon'
          polygon(element)
        when 'Track'
          line(track_positions(element))
        when 'MultiTrack'
          collect(element.element_children.select { |c| local_name(c) == 'Track' }.filter_map { |t| line(track_positions(t)) })
        when 'MultiGeometry'
          collect(element.element_children.filter_map { |c| GEOMETRY_TYPES.include?(local_name(c)) ? geometry(c) : nil })
        when 'Model'
          @counts[:models] += 1
          nil
        end
      end

      def line(positions)
        return nil if positions.empty?
        return { 'type' => 'Point', 'coordinates' => positions.first } if positions.size == 1

        { 'type' => 'LineString', 'coordinates' => positions }
      end

      def polygon(element)
        outer = ring(child(element, 'outerBoundaryIs'))
        return nil unless outer

        holes = element.element_children.select { |c| local_name(c) == 'innerBoundaryIs' }.filter_map { |b| ring(b) }
        { 'type' => 'Polygon', 'coordinates' => [outer, *holes] }
      end

      # A boundary's LinearRing, closed if the file left it open.
      def ring(boundary)
        positions = coordinates(child(boundary, 'LinearRing'))
        return nil if positions.empty?

        positions << positions.first if positions.size > 1 && positions.first != positions.last
        positions
      end

      # A MultiGeometry's parts as one GeoJSON geometry: Multi* when they're
      # all the same kind, else a collection.
      def collect(parts)
        parts = parts.flat_map { |part| part['type'] == 'GeometryCollection' ? part['geometries'] : [part] }
        return nil if parts.empty?

        kinds = parts.map { |part| part['type'].delete_prefix('Multi') }.uniq
        return { 'type' => 'GeometryCollection', 'geometries' => parts } unless kinds.size == 1

        members = parts.flat_map { |part| part['type'].start_with?('Multi') ? part['coordinates'] : [part['coordinates']] }
        { 'type' => "Multi#{kinds.first}", 'coordinates' => members }
      end

      # "lon,lat[,alt] lon,lat[,alt] …" → [[lon, lat], …]. A value that isn't
      # a number is kept as written, so the import reports the row.
      def coordinates(element)
        text = child(element, 'coordinates')&.text.to_s
        text.gsub(/\s*,\s*/, ',').split(/\s+/).reject(&:empty?).map do |tuple|
          tuple.split(',').first(2).map { |value| number(value) }
        end
      end

      # gx:Track: <gx:coord>lon lat alt</gx:coord> per point.
      def track_positions(element)
        element.element_children.select { |c| local_name(c) == 'coord' }.map do |coord|
          coord.text.split(/\s+/).reject(&:empty?).first(2).map { |value| number(value) }
        end
      end

      def number(value)
        Float(value)
      rescue ArgumentError, TypeError
        value
      end

      # --- text ----------------------------------------------------------------

      # A description as plain text: KML descriptions are often HTML (Google
      # Earth balloons); line breaks and paragraphs kept, links as
      # "text (address)", images and scripts dropped.
      def description_text(value)
        text = clean(value)
        return text if text.nil? || !text.match?(%r{</?[a-z][^>]*>}i)

        out = +''
        html_text(Nokogiri::HTML4::DocumentFragment.parse(text), out)
        clean(out.gsub(/[ \t ]+/, ' ').gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n"))
      end

      def html_text(node, out)
        node.children.each do |child|
          if child.text?
            out << child.text
          elsif child.element?
            tag = child.name.downcase
            next if %w[script style img].include?(tag)

            if tag == 'br'
              out << "\n"
            elsif tag == 'a'
              label = child.text.strip
              href = child['href'].to_s.strip
              out << label
              out << " (#{href})" if href.match?(%r{\A(https?://|mailto:)}i) && href != label
            else
              out << "\n" if BLOCK_TAGS.include?(tag)
              html_text(child, out)
              out << "\n" if BLOCK_TAGS.include?(tag)
            end
          end
        end
      end

      # --- columns and warnings ------------------------------------------------

      # The columns in file terms: the placemark's own values that any
      # placemark has, then its ExtendedData. An ExtendedData key that is also
      # a placemark value the file uses (a Data "address" beside <address>)
      # is told apart as "address (data)"; otherwise it keeps its name.
      def build_columns
        filled = ->(column) { @rows.any? { |row| row[:properties][column] } }
        used = BUILT_IN.select(&filled)
        names = @data_columns.to_h { |key| [key, used.any? { |b| b.casecmp?(key) } ? "#{key} (data)" : key] }

        leading = [NAME, DESCRIPTION, ADDRESS] & used
        trailing = [DATES, FOLDER] & used
        @columns = leading + names.values + trailing
        @columns.unshift(NAME) unless @columns.any? { |column| column.casecmp?(NAME) }

        @rows.each do |row|
          properties = @columns.to_h { |column| [column, nil] }
          (leading + trailing).each { |column| properties[column] = row[:properties][column] }
          row[:data].each { |key, value| properties[names[key]] = value }
          row[:properties] = properties
        end
      end

      def build_warnings
        @warnings = []
        if @counts[:web_links].positive?
          @warnings << "#{pluralize(@counts[:web_links], 'link')} to KML on the web (NetworkLink) #{were(@counts[:web_links])} not followed; download those files and upload them too."
        end
        if @counts[:local_links].positive?
          @warnings << "The file links to #{pluralize(@counts[:local_links], 'other file')} that #{@counts[:local_links] == 1 ? 'isn’t' : 'aren’t'} in the upload; " \
                       'save the whole project as a KMZ (or upload each .kml) to include them.'
        end
        if @counts[:overlays].positive?
          @warnings << "#{pluralize(@counts[:overlays], 'image overlay')} (GroundOverlay) #{were(@counts[:overlays])} not imported; a scanned map goes under Settings → Map layers → Add a historic map."
        end
        @warnings << "#{pluralize(@counts[:models], 'placemark')} with a 3D model instead of a point or shape #{@counts[:models] == 1 ? 'is' : 'are'} imported without a location." if @counts[:models].positive?
      end

      def unpacked_message
        "The KMZ unpacks to more than #{MAX_UNPACKED_BYTES / (1024 * 1024)} MB; split it into smaller files."
      end

      def pluralize(count, word)
        "#{count} #{count == 1 ? word : "#{word}s"}"
      end

      def were(count) = count == 1 ? 'was' : 'were'

      # --- XML helpers ---------------------------------------------------------

      def fragment(node)
        document = Nokogiri::XML(node.outer_xml, nil, 'UTF-8', FRAGMENT_OPTIONS)
        document.remove_namespaces!
        document.root
      end

      def element_text(node)
        fragment(node)&.text
      end

      def child(element, name)
        element&.element_children&.find { |c| local_name(c) == name }
      end

      # The element's name without any namespace prefix (gx:Track → Track;
      # remove_namespaces! keeps a prefix that was never declared).
      def local_name(node)
        node.name.to_s.split(':').last
      end
    end
  end
end
