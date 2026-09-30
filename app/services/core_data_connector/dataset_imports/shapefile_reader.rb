# frozen_string_literal: true

require 'zip'

module CoreDataConnector
  module DatasetImports
    # A zipped Shapefile: the .shp (geometry) and .dbf (attributes) of one
    # layer, with its .prj (coordinate system) and .cpg (text encoding) when
    # present. Read directly — the format is small and fixed — so the host
    # needs no GIS library; rubyzip is already in its bundle.
    #
    # Geometry must be longitude/latitude. A .prj that declares a projected
    # system (PROJCS) is refused with instructions to re-export; the
    # alternative, reprojecting here, would mean shipping PROJ. A file with no
    # .prj is read as longitude/latitude and the usual range check reports it
    # if that's wrong.
    #
    # Supported shape types: points, multipoints, polylines and polygons,
    # including their Z and M variants (the extra values are dropped).
    # Polygon rings are grouped the way the format defines them — clockwise
    # rings are outer boundaries, counter-clockwise ones are holes — and
    # written with GeoJSON's winding (outer counter-clockwise).
    class ShapefileReader < Reader
      POINT = [1, 11, 21].freeze
      MULTIPOINT = [8, 18, 28].freeze
      POLYLINE = [3, 13, 23].freeze
      POLYGON = [5, 15, 25].freeze
      MULTIPATCH = 31

      def format = 'shapefile'

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

        @records.each_with_index do |properties, index|
          check_row_limit!(index)
          yield({ index:, line: index + 1, properties:, geometry: @geometries[index] })
        end
      end

      private

      def load!
        return if @records

        @warnings = []

        Zip::File.open(path) do |zip|
          layers = zip.entries.map(&:name).reject { |n| n.start_with?('__MACOSX/') }.grep(/\.shp\z/i).sort
          raise Invalid, 'The zip has no .shp file. Zip the layer’s .shp, .dbf, .shx and .prj files together.' if layers.empty?

          shp_name = layers.first
          base = shp_name.sub(/\.shp\z/i, '')
          @warnings << "The zip holds #{layers.size} layers; importing “#{File.basename(base)}”." if layers.size > 1

          dbf = entry(zip, base, 'dbf') or raise Invalid, "The zip has no #{File.basename(base)}.dbf, which holds the layer’s attributes."
          check_projection!(entry(zip, base, 'prj')&.get_input_stream&.read)
          encoding = entry(zip, base, 'cpg')&.get_input_stream&.read.to_s.strip

          @geometries = read_shp(zip.find_entry(shp_name).get_input_stream.read.b)
          @columns, @records = read_dbf(dbf.get_input_stream.read.b, encoding)
        end

        return if @geometries.size == @records.size

        @warnings << "The .shp has #{@geometries.size} shapes but the .dbf has #{@records.size} rows; only the first #{[@geometries.size, @records.size].min} are read."
        count = [@geometries.size, @records.size].min
        @geometries = @geometries.first(count)
        @records = @records.first(count)
      rescue Zip::Error => e
        raise Invalid, "The zip could not be opened (#{e.message.truncate(80)})."
      end

      def entry(zip, base, extension)
        zip.entries.find { |e| e.name.casecmp?("#{base}.#{extension}") }
      end

      def check_projection!(prj)
        return if prj.blank?
        return unless prj.lstrip.match?(/\APROJCS/i)

        name = prj[/\APROJCS\["([^"]+)"/i, 1] || 'a projected system'
        raise Invalid, "This shapefile uses a projected coordinate system (#{name.tr('_', ' ')}). Re-export it in " \
                       'longitude/latitude: in QGIS, Export → Save Features As… with CRS EPSG:4326 (WGS 84), then zip ' \
                       'the new files and upload them.'
      end

      # --- .shp ----------------------------------------------------------------

      def read_shp(data)
        raise Invalid, 'The .shp file is not a shapefile.' unless data.bytesize >= 100 && data[0, 4].unpack1('N') == 9994

        geometries = []
        offset = 100

        while offset + 8 <= data.bytesize
          length = data[offset + 4, 4].unpack1('N') * 2
          geometries << shape(data.byteslice(offset + 8, length))
          offset += 8 + length
        end

        geometries
      end

      def shape(content)
        type = content[0, 4].unpack1('V')

        if POINT.include?(type)
          { 'type' => 'Point', 'coordinates' => content[4, 16].unpack('E2') }
        elsif MULTIPOINT.include?(type)
          count = content[36, 4].unpack1('V')
          points = content[40, 16 * count].unpack("E#{2 * count}").each_slice(2).to_a
          points.size == 1 ? { 'type' => 'Point', 'coordinates' => points.first } : { 'type' => 'MultiPoint', 'coordinates' => points }
        elsif POLYLINE.include?(type)
          lines = parts(content)
          lines.size == 1 ? { 'type' => 'LineString', 'coordinates' => lines.first } : { 'type' => 'MultiLineString', 'coordinates' => lines }
        elsif POLYGON.include?(type)
          polygons(parts(content))
        elsif type == MULTIPATCH
          raise Invalid, 'MultiPatch (3D surface) shapefiles aren’t supported; export the layer as polygons.'
        end
      end

      # The point lists of a polyline or polygon record, one per part.
      def parts(content)
        part_count = content[36, 4].unpack1('V')
        point_count = content[40, 4].unpack1('V')
        starts = content[44, 4 * part_count].unpack("V#{part_count}")
        points = content[44 + (4 * part_count), 16 * point_count].unpack("E#{2 * point_count}").each_slice(2).to_a

        starts.each_with_index.map { |start, i| points[start...(starts[i + 1] || point_count)] }.reject(&:empty?)
      end

      def polygons(rings)
        return nil if rings.empty?

        outers, holes = rings.partition { |ring| clockwise?(ring) }
        # A file with the winding reversed throughout: treat every ring as a boundary.
        outers, holes = [rings, []] if outers.empty?

        shells = outers.map { |ring| [ring.reverse] }
        holes.each do |hole|
          shell = shells.find { |candidate| inside?(hole.first, candidate.first) }
          shell ? shell << hole.reverse : shells << [hole]
        end

        shells.size == 1 ? { 'type' => 'Polygon', 'coordinates' => shells.first } : { 'type' => 'MultiPolygon', 'coordinates' => shells }
      end

      def clockwise?(ring)
        ring.each_cons(2).sum { |(x1, y1), (x2, y2)| (x2 - x1) * (y2 + y1) }.positive?
      end

      # Ray casting: is the point inside the ring?
      def inside?(point, ring)
        x, y = point
        inside = false

        ring.each_cons(2) do |(x1, y1), (x2, y2)|
          next unless (y1 > y) != (y2 > y)

          inside = !inside if x < ((x2 - x1) * (y - y1) / (y2 - y1)) + x1
        end

        inside
      end

      # --- .dbf ----------------------------------------------------------------

      def read_dbf(data, encoding)
        count = data[4, 4].unpack1('V')
        header_length = data[8, 2].unpack1('v')
        record_length = data[10, 2].unpack1('v')

        fields = []
        position = 32
        while position + 32 <= header_length && data.getbyte(position) != 0x0D
          fields << { name: decode(data[position, 11].unpack1('Z*'), encoding), type: data[position + 11],
                      length: data.getbyte(position + 16) }
          position += 32
        end

        columns = normalize_headers(fields.map { |f| f[:name] })
        records = []

        count.times do |i|
          record = data.byteslice(header_length + (i * record_length), record_length)
          break if record.nil? || record.bytesize < record_length
          next if record[0] == '*' # deleted

          offset = 1
          values = fields.map do |field|
            raw = record.byteslice(offset, field[:length])
            offset += field[:length]
            value(raw, field[:type], encoding)
          end

          records << columns.zip(values).to_h
        end

        [columns, records]
      end

      def value(raw, type, encoding)
        text = raw.to_s.strip

        case type
        when 'N', 'F'
          number(text)
        when 'D'
          text.match?(/\A\d{8}\z/) ? "#{text[0, 4]}-#{text[4, 2]}-#{text[6, 2]}" : nil
        when 'L'
          return 'true' if %w[T t Y y].include?(text)
          return 'false' if %w[F f N n].include?(text)

          nil
        else
          clean(decode(raw, encoding))
        end
      end

      # DBF numbers are fixed-width text, often padded with a double's full
      # precision ("33.772599999999997"); keep the value, drop the noise.
      def number(text)
        return nil if text.empty? || text.start_with?('*')

        value = Float(text)
        (value % 1).zero? && value.abs < 1e15 ? value.to_i.to_s : value.to_s
      rescue ArgumentError
        text
      end

      # Text in the encoding the .cpg names; UTF-8 when it's valid otherwise,
      # else Windows-1252 (the usual encoding of files with no .cpg).
      def decode(bytes, encoding)
        name = encoding.to_s.upcase
        source = if name.include?('UTF') then Encoding::UTF_8
                 elsif name.match?(/8859-?1\z|LATIN1/) then Encoding::ISO_8859_1
                 elsif name.match?(/1252/) then Encoding::Windows_1252
                 end

        text = bytes.dup.force_encoding(source || Encoding::UTF_8)
        text = bytes.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace) unless text.valid_encoding?
        text.encode(Encoding::UTF_8)
      rescue EncodingError
        bytes.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace)
      end
    end
  end
end
