module CoreDataConnector
  # Web-sized copies of the images a curator uploads for an atlas
  # (Site#assets), so a visitor doesn't download a 10 MB, 6000-pixel banner
  # photo to fill a phone screen.
  #
  # At upload, each JPEG, PNG, WebP or AVIF gets copies at the widths in
  # WIDTHS below its own width, plus one at its own width up to 2000 px; the
  # renderer offers them through srcset and the browser fetches the one its
  # screen needs. Copies are turned upright (EXIF orientation), converted to
  # sRGB and carry no metadata (camera details, GPS). Opaque images become
  # JPEG, which every browser and link-preview crawler reads; images with
  # transparency become WebP. SVG and ICO are left as uploaded (vector, or
  # already tiny), and so are GIFs and animated images (copies would freeze
  # them on their first frame).
  #
  # Copies are blobs attached to the site as `asset_variants`, so the image
  # library lists only what the curator uploaded, and are served by the same
  # public route. The original's blob metadata records its upright size and
  # its copies, largest last:
  #
  #   { "width" => 6000, "height" => 4000,
  #     "og_variants" => [{ "key", "filename", "width", "height" }, ...] }
  #
  # When re-encoding a JPEG or PNG at its own size saves nothing, the
  # original stands in for that largest copy.
  #
  # Uses libvips (FairData's Dockerfile installs it) through ruby-vips. Where
  # libvips can't be loaded, images are stored and served as uploaded, and
  # the renderer falls back to a plain src.
  module SiteImages
    WIDTHS = [160, 320, 640, 1024, 1440, 2000].freeze
    RESIZABLE_TYPES = %w[image/png image/jpeg image/webp image/avif].freeze
    STAND_IN_TYPES = %w[image/png image/jpeg].freeze

    # A 10 MB upload can still decode to an enormous canvas (a flat-color
    # PNG); this bounds the work and memory one upload can cause.
    MAX_PIXELS = 100_000_000

    # Bound for `thumbnail`'s height so only the width constrains it.
    UNBOUNDED = 10_000_000

    class Error < StandardError; end
    class Unreadable < Error; end
    class TooLarge < Error; end

    def self.available?
      return @available unless @available.nil?

      @available = begin
        require 'vips'
        # One-off operations on large images: nothing worth caching, and the
        # cache would hold decoded pixels in a long-lived server process.
        Vips.cache_set_max(0)
        true
      rescue LoadError => e
        Rails.logger.warn("[open_geographies] libvips unavailable, uploaded images are served as uploaded: #{e.message}")
        false
      end
    end

    # Stores the file at `path` and attaches it to `site` as an asset, with
    # web-sized copies when it's an image libvips can resize. Returns the
    # original's blob. Raises Unreadable or TooLarge (with a message for the
    # curator) for an image it can't use; nothing is stored then.
    def self.upload(site, path, filename:, content_type:)
      built = build(path, content_type, File.size(path))

      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(path),
        filename:,
        content_type:,
        identify: false,
        # Already analyzed: ActiveStorage's own analyzer would merge its
        # (empty) result into the metadata recorded below.
        metadata: built ? { analyzed: true, identified: true } : {}
      )
      site.assets.attach(blob)

      store(site, blob, built) if built

      blob
    end

    # Removes an asset and its copies.
    def self.purge(site, attachment)
      keys = variant_entries(attachment.blob).map { |entry| entry['key'] } - [attachment.blob.key]
      site.asset_variants_attachments.joins(:blob).where(active_storage_blobs: { key: keys }).each(&:purge)
      attachment.purge
    end

    # Makes copies for a site's assets uploaded before they existed (or while
    # libvips was unavailable). Returns the number of images processed.
    def self.backfill(site)
      return 0 unless available?

      site.assets_attachments.includes(:blob).to_a.count do |attachment|
        blob = attachment.blob
        next false unless RESIZABLE_TYPES.include?(blob.content_type) && !blob.metadata.key?('og_variants')

        blob.open do |file|
          built = build(file.path, blob.content_type, blob.byte_size)
          store(site, blob, built) if built
        end

        true
      rescue Error => e
        Rails.logger.warn("[open_geographies] no copies for asset #{blob.key} (site #{site.id}): #{e.message}")
        false
      end
    end

    # What the renderer needs to pick a copy, keyed by the original's blob
    # key: { width, height, variants: [{ path, width, height }] }. Assets
    # without a recorded size (SVG, ICO, uploads made without libvips) are
    # left out; the renderer shows those as uploaded.
    def self.bundle(site)
      site.assets_attachments.includes(:blob).each_with_object({}) do |attachment, images|
        blob = attachment.blob
        next unless blob.metadata['width'] && blob.metadata['height']

        images[blob.key] = {
          'width' => blob.metadata['width'],
          'height' => blob.metadata['height'],
          'variants' => variant_entries(blob).map do |entry|
            {
              'path' => Site.asset_path_for(entry['key'], entry['filename']),
              'width' => entry['width'],
              'height' => entry['height']
            }
          end
        }
      end
    end

    # A small copy for previews in the console (at least 320 px wide when
    # there is one), or nil.
    def self.thumbnail_path(blob)
      entries = variant_entries(blob)
      entry = entries.find { |e| e['width'] >= 320 } || entries.last

      entry && Site.asset_path_for(entry['key'], entry['filename'])
    end

    def self.variant_entries(blob)
      Array(blob.metadata['og_variants'])
    end

    # Reads the image and encodes its copies in memory (nothing stored yet).
    # nil when the type isn't resized here or libvips isn't available.
    def self.build(path, content_type, byte_size)
      return nil unless RESIZABLE_TYPES.include?(content_type) && available?

      header = Vips::Image.new_from_file(path, access: :sequential, fail_on: :error)
      pixels = header.width * header.height

      if pixels > MAX_PIXELS
        raise TooLarge, "This image is #{header.width.to_fs(:delimited)} × #{header.height.to_fs(:delimited)} pixels " \
                        "(#{pixels / 1_000_000} megapixels); images can be at most #{MAX_PIXELS / 1_000_000} megapixels. " \
                        'Save a smaller copy and upload that.'
      end

      # Decode it all once, strictly: thumbnail's fast path (shrink-on-load)
      # only warns about a truncated file, and would make copies of a
      # half-grey picture.
      header.avg

      width, height = upright_size(header)
      return { width:, height:, copies: [] } if animated?(header)

      top = [width, WIDTHS.last].min
      base = upright_srgb(path, top)
      transparent = transparent?(base)
      base = base.extract_band(0, n: base.bands - 1) if base.has_alpha? && !transparent

      copies = (WIDTHS.select { |w| w < top } << top).map do |target|
        resized = target >= base.width ? base : base.thumbnail_image(target, height: UNBOUNDED)
        encode(resized, transparent)
      end

      # At its own size, the original wins when the copy isn't any smaller,
      # if it's a format every browser reads (it shares a srcset with them).
      original_largest = top == width && STAND_IN_TYPES.include?(content_type) &&
                         copies.last[:data].bytesize >= byte_size
      copies.pop if original_largest

      { width:, height:, copies:, original_largest: }
    rescue Vips::Error => e
      Rails.logger.info("[open_geographies] unreadable image upload: #{e.message.lines.first&.strip}")
      raise Unreadable, 'This image couldn\'t be read. Open it in an image editor, save it again as a JPEG or PNG, and upload that.'
    end

    # Creates the copies' blobs, attaches them to the site and records them
    # on the original.
    def self.store(site, original, built)
      stem = File.basename(original.filename.to_s, '.*').presence || 'image'

      blobs = built[:copies].map do |copy|
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(copy[:data]),
          filename: "#{stem}-#{copy[:width]}.#{copy[:extension]}",
          content_type: copy[:content_type],
          identify: false,
          metadata: { analyzed: true, identified: true, width: copy[:width], height: copy[:height] }
        )
      end
      site.asset_variants.attach(blobs) if blobs.any?

      entries = blobs.zip(built[:copies]).map do |blob, copy|
        { 'key' => blob.key, 'filename' => blob.filename.to_s, 'width' => copy[:width], 'height' => copy[:height] }
      end

      if built[:original_largest]
        entries << { 'key' => original.key, 'filename' => original.filename.to_s, 'width' => built[:width], 'height' => built[:height] }
      end

      original.update!(metadata: original.metadata.merge(
        'analyzed' => true,
        'width' => built[:width],
        'height' => built[:height],
        'og_variants' => entries
      ))
    end

    # The size the image displays at: EXIF orientations 5–8 turn it a
    # quarter, swapping width and height.
    def self.upright_size(image)
      orientation = image.get_typeof('orientation').zero? ? 1 : image.get('orientation')

      orientation.between?(5, 8) ? [image.height, image.width] : [image.width, image.height]
    end

    def self.animated?(image)
      !image.get_typeof('n-pages').zero? && image.get('n-pages') > 1
    end

    # The image at `width`, upright, in 8-bit sRGB (embedded profiles such as
    # a phone's Display P3 are converted, since the copies drop the profile),
    # held in memory so several sizes can be cut from one decode.
    def self.upright_srgb(path, width)
      Vips::Image.thumbnail(path, width, height: UNBOUNDED, size: :down, export_profile: 'srgb')
                 .colourspace(:srgb)
                 .copy_memory
    end

    # True when the image has an alpha channel that actually hides something.
    def self.transparent?(image)
      image.has_alpha? && image.extract_band(image.bands - 1).min < 255
    end

    def self.encode(image, transparent)
      keep = Vips.at_least_libvips?(8, 15) ? { keep: :none } : { strip: true }

      if transparent
        { data: image.webpsave_buffer(Q: 88, effort: 4, **keep), content_type: 'image/webp', extension: 'webp',
          width: image.width, height: image.height }
      else
        { data: image.jpegsave_buffer(Q: 82, optimize_coding: true, interlace: true, **keep), content_type: 'image/jpeg',
          extension: 'jpg', width: image.width, height: image.height }
      end
    end

    private_class_method :build, :store, :upright_size, :animated?, :upright_srgb, :transparent?, :encode
  end
end
