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
    # large file is never held as a whole document; rows keep only their own
    # values. What one file can cost is bounded: 500 columns, 25 MB for one
    # placemark as written, 3 million points in all. Nokogiri comes with Rails
    # (rails-html-sanitizer), so the gemspec declares nothing new. No network access, no
    # DTDs: a file declaring one is refused (KML never does), and entities are
    # never expanded. In a KMZ, network links to other .kml files inside the
    # same zip are followed (GDAL writes one file per layer that way); links to
    # the web are not, with a warning. GroundOverlays (a scanned map or plan
    # laid over the earth) are collected as `overlays` — name, image, corners,
    # years, opacity — for the import to add as map layers; Screen and Photo
    # overlays are skipped with a warning.
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
      # The work a file can cause is bounded by its points, not its bytes: a
      # small KMZ can unpack to one enormous shape. One placemark may be this
      # large as written (a detailed outline of a county is a few MB)…
      MAX_PLACEMARK_BYTES = 25 * 1024 * 1024
      # …and the whole file may hold this many points.
      MAX_POSITIONS = 3_000_000
      # Network links followed inside a KMZ, nested.
      MAX_LINK_DEPTH = 5

      OTHER_OVERLAYS = %w[ScreenOverlay PhotoOverlay].freeze
      # An overlay's image, read from the KMZ for the map layer.
      MAX_OVERLAY_IMAGE_BYTES = 50 * 1024 * 1024
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

      # The GroundOverlays: [{ name:, folder:, href:, source: { entry: } (in the
      # KMZ) | { url: } (on the web) | nil (not in the upload), corners: [top
      # left, top right, bottom right, bottom left] as [lon, lat] or nil,
      # start_year:, end_year:, opacity: }].
      def overlays
        load!
        @overlays
      end

      # The bytes of an overlay's image inside the KMZ, or nil.
      def overlay_image(overlay)
        name = overlay.dig(:source, :entry)
        return nil unless @kmz && name

        Zip::File.open(path) do |zip|
          entry = zip.find_entry(name)
          return nil unless entry && entry.size <= MAX_OVERLAY_IMAGE_BYTES

          stream = entry.get_input_stream
          bytes = stream.read(MAX_OVERLAY_IMAGE_BYTES + 1)
          bytes && bytes.bytesize <= MAX_OVERLAY_IMAGE_BYTES ? bytes : nil
        ensure
          stream&.close
        end
      rescue Zip::Error
        nil
      end

      # Each row's properties are built as it's yielded: the rows are kept
      # with only their own values, since placemarks whose ExtendedData keys
      # differ would otherwise hold every column each (rows × columns).
      def each_row
        load!

        @rows.each_with_index do |row, index|
          properties = @columns.to_h { |column| [column, nil] }
          @built_in_columns.each { |column| properties[column] = row[:properties][column] }
          row[:data].each { |key, value| properties[@column_names[key]] = value }

          yield({ index:, line: index + 1, properties:, geometry: row[:geometry] })
        end
      end

      # Counts what the parser reads (a KMZ entry unpacking, or the file),
      # against the unpacked limit and the size of the placemark being read.
      def count_unpacked!(bytes)
        @unpacked += bytes
        limit!(unpacked_message) if @unpacked > MAX_UNPACKED_BYTES
        limit!(placemark_message) if @placemark_start && @unpacked - @placemark_start > MAX_PLACEMARK_BYTES
      end

      private

      def load!
        return if @rows

        @rows = []
        @data_columns = {} # an ordered set of ExtendedData keys
        @counts = Hash.new(0)
        @overlays = []
        @unpacked = 0
        @positions = 0
        @placemark_start = nil
        @limit_error = nil
        @deep_targets = Set.new

        if @kmz
          read_kmz
        else
          File.open(path, 'rb') { |file| read_document(LimitedStream.new(file, self), folder: nil, entry: nil, depth: 0) }
        end

        raise Invalid, 'The file has no placemarks (KML places), so there is nothing to import.' if @rows.empty?

        build_columns
        check_cell_limit!(@rows.size, @columns.size)
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
            @placemark_start = @unpacked
            element = fragment(node)
            # The size check fires inside the parser's read, which the
            # subtree read may report as no XML rather than an error.
            raise Invalid, @limit_error if @limit_error

            @placemark_start = nil
            @rows << placemark(element, current)
            skip_to = node.depth unless node.empty_element?
          when 'NetworkLink'
            network_link(fragment(node), current, entry, depth)
            skip_to = node.depth unless node.empty_element?
          when 'GroundOverlay'
            @overlays << ground_overlay(fragment(node), current, entry)
            skip_to = node.depth unless node.empty_element?
          when *OTHER_OVERLAYS
            @counts[:other_overlays] += 1
            skip_to = node.depth unless node.empty_element?
          end
        end
      rescue Nokogiri::XML::SyntaxError => e
        # The size checks raise inside the parser's read, which libxml2
        # reports as an I/O error.
        raise Invalid, @limit_error if @limit_error

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

          if linked.nil?
            @counts[:local_links] += 1
          elsif !target.downcase.end_with?('.kml')
            @counts[:other_links] += 1
          elsif @visited.include?(target)
            # Read already (or a cycle): nothing more to read.
          elsif depth >= MAX_LINK_DEPTH
            # Reported unless a shallower link reaches it after all.
            @deep_targets << target
          else
            @visited << target
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
        data.each_key do |key|
          next if @data_columns.key?(key)

          @data_columns[key] = true
          check_column_limit!(@data_columns.size + BUILT_IN.size)
        end

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
        tuples = text.gsub(/\s*,\s*/, ',').split(/\s+/).reject(&:empty?)
        count_positions!(tuples.size)

        tuples.map do |tuple|
          tuple.split(',').first(2).map { |value| number(value) }
        end
      end

      # gx:Track: <gx:coord>lon lat alt</gx:coord> per point.
      def track_positions(element)
        coords = element.element_children.select { |c| local_name(c) == 'coord' }
        count_positions!(coords.size)

        coords.map do |coord|
          coord.text.split(/\s+/).reject(&:empty?).first(2).map { |value| number(value) }
        end
      end

      def count_positions!(count)
        @positions += count
        return if @positions <= MAX_POSITIONS

        raise Invalid, "The file's shapes have more than #{MAX_POSITIONS.to_fs(:delimited)} points in all. Simplify them " \
                       '(in QGIS: Vector → Geometry Tools → Simplify) or split the file, and upload that.'
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

      # --- overlays ------------------------------------------------------------

      def ground_overlay(element, folder, entry)
        href = clean(child(child(element, 'Icon'), 'href')&.text)
        dates = (value = time_text(element)) && Values.fuzzy_date(value)
        dates = nil if dates == :invalid

        {
          name: clean(child(element, 'name')&.text) || "Overlay #{@overlays.size + 1}",
          folder:,
          href:,
          source: overlay_source(href, entry),
          corners: overlay_corners(element),
          start_year: dates && Date.parse(dates['start_date']).year,
          end_year: dates && dates['end_date'] && Date.parse(dates['end_date']).year,
          opacity: overlay_opacity(child(element, 'color')&.text)
        }
      end

      def overlay_source(href, entry)
        return nil if href.nil?
        return { url: href } if href.match?(%r{\Ahttps?://}i)
        return nil unless @kmz

        target = resolve(entry, href)
        target && @zip.find_entry(target) ? { entry: target } : nil
      end

      # Where the image's corners go. A LatLonBox (north, south, east, west and
      # a rotation, degrees counter-clockwise about its centre — turned in a
      # plane scaled by the latitude's cosine, as the earth is there), or a
      # gx:LatLonQuad's four corners (lower left, lower right, upper right,
      # upper left). nil when neither is readable or a corner is off the earth.
      def overlay_corners(element)
        quad = child(element, 'LatLonQuad')
        corners = if quad
                    points = coordinates(quad)
                    points.size == 4 ? [points[3], points[2], points[1], points[0]] : nil
                  else
                    box_corners(child(element, 'LatLonBox'))
                  end

        return nil unless corners&.all? { |lon, lat| lon.is_a?(Numeric) && lat.is_a?(Numeric) && lon.abs <= 180 && lat.abs <= 90 }

        corners.map { |lon, lat| [lon.round(7), lat.round(7)] }
      end

      def box_corners(box)
        return nil unless box

        north, south, east, west = %w[north south east west].map { |side| number(child(box, side)&.text.to_s.strip) }
        return nil unless [north, south, east, west].all?(Numeric)

        rotation = number(child(box, 'rotation')&.text.to_s.strip)
        corners = [[west, north], [east, north], [east, south], [west, south]]
        return corners unless rotation.is_a?(Numeric) && !rotation.zero?

        cx = (east + west) / 2.0
        cy = (north + south) / 2.0
        scale = Math.cos(cy * Math::PI / 180)
        angle = rotation * Math::PI / 180

        corners.map do |lon, lat|
          dx = (lon - cx) * scale
          dy = lat - cy
          [cx + ((dx * Math.cos(angle)) - (dy * Math.sin(angle))) / scale, cy + (dx * Math.sin(angle)) + (dy * Math.cos(angle))]
        end
      end

      # KML colors are aabbggrr: the alpha is how opaque the image draws.
      def overlay_opacity(color)
        hex = clean(color)
        return nil unless hex&.match?(/\A\h{8}\z/)

        alpha = hex[0, 2].to_i(16) / 255.0
        alpha >= 1 ? nil : alpha.round(2)
      end

      # --- columns and warnings ------------------------------------------------

      # The columns in file terms: the placemark's own values that any
      # placemark has, then its ExtendedData. Column names are unique,
      # ignoring case (one field each). An ExtendedData key keeps its name
      # when it's free; one that is also a placemark value the file uses (a
      # Data "address" beside <address>), or another key's name in other
      # case, is told apart as "address (data)", then "address (data 2)".
      def build_columns
        filled = ->(column) { @rows.any? { |row| row[:properties][column] } }
        used = BUILT_IN.select(&filled)
        taken = used.to_set { |column| column.downcase }
        names = {}

        @data_columns.each_key do |key|
          next if taken.include?(key.downcase)

          names[key] = key
          taken << key.downcase
        end

        @data_columns.each_key do |key|
          next if names.key?(key)

          name = "#{key} (data)"
          number = 2
          while taken.include?(name.downcase)
            name = "#{key} (data #{number})"
            number += 1
          end
          names[key] = name
          taken << name.downcase
        end

        @column_names = @data_columns.keys.to_h { |key| [key, names[key]] }

        leading = [NAME, DESCRIPTION, ADDRESS] & used
        trailing = [DATES, FOLDER] & used
        @built_in_columns = leading + trailing
        @columns = leading + @column_names.values + trailing
        @columns.unshift(NAME) unless @columns.any? { |column| column.casecmp?(NAME) }
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
        if @counts[:other_links].positive?
          @warnings << "#{pluralize(@counts[:other_links], 'link')} to other kinds of file inside the KMZ #{were(@counts[:other_links])} not followed " \
                       '(only .kml files inside it are read); upload those files on their own.'
        end
        deep = (@deep_targets - @visited.to_a).size
        if deep.positive?
          @warnings << "#{pluralize(deep, 'layer')} linked more than #{MAX_LINK_DEPTH} levels deep #{were(deep)} not read; " \
                       'upload those .kml files on their own.'
        end
        usable = @overlays.count { |overlay| overlay[:source] && overlay[:corners] }
        if usable.positive?
          @warnings << "#{pluralize(usable, 'image overlay')} (GroundOverlay: a scanned map or plan laid over the map) " \
                       "will be added to the atlas's map layers when you import."
        end
        unusable = @overlays.size - usable
        if unusable.positive?
          @warnings << "#{pluralize(unusable, 'image overlay')} can't be added: its image isn't in the upload or its corners " \
                       "can't be read. Save the project as a KMZ (which carries the images) and upload that."
        end
        if @counts[:other_overlays].positive?
          @warnings << "#{pluralize(@counts[:other_overlays], 'screen or photo overlay')} #{were(@counts[:other_overlays])} not imported."
        end
        @warnings << "#{pluralize(@counts[:models], 'placemark')} with a 3D model instead of a point or shape #{@counts[:models] == 1 ? 'is' : 'are'} imported without a location." if @counts[:models].positive?
      end

      def unpacked_message
        "The KMZ unpacks to more than #{MAX_UNPACKED_BYTES / (1024 * 1024)} MB; split it into smaller files."
      end

      def placemark_message
        "Placemark #{@rows.size + 1} is larger than #{MAX_PLACEMARK_BYTES / (1024 * 1024)} MB as written (a shape with " \
          'hundreds of thousands of points). Simplify it (in QGIS: Vector → Geometry Tools → Simplify) or split the file, ' \
          'and upload that.'
      end

      # Stops the read with `message`. Raised inside the parser's read, it
      # surfaces as an XML error, so the message is kept to report instead.
      def limit!(message)
        @limit_error ||= message
        raise Invalid, @limit_error
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
