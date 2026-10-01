# frozen_string_literal: true

module CoreDataConnector
  # Copies the photos a dataset import linked to onto the atlas's IIIF image
  # server (see PlacePhotos). Queued by ImportDatasetJob when the Photo
  # column is set to copy; extra: { project_model_id, photo_field_uuid,
  # import_job_id }.
  #
  # For each place of the model whose photo field holds a web address and
  # that has no Media record from that address yet:
  #   1. download it (RemoteFiles: public addresses only, size and time
  #      capped), at most one request a second to each source — the Library
  #      of Congress blocks for an hour past its limit — waiting out "busy"
  #      answers (429/503) a few times and a timeout once before giving up
  #      on that photo;
  #   2. save a Media record (FairData's MediaContent, which uploads the file
  #      to IIIF Cloud) named after the place, Media Type "image", Alt Text
  #      the place's name, `import_url` the source address;
  #   3. link it to the place through Places → Media (created from the
  #      canonical template if the atlas doesn't have it), ticked `featured`
  #      when the place has no featured media yet.
  # Then the places' IIIF manifests are rebuilt (the detail page's viewer).
  # Re-running copies only what's missing. Failures are listed per place.
  # When the image server refuses several uploads in a row the job stops:
  # that's a configuration problem, not a photo's. One scoped reindex at
  # the end puts the thumbnails in the atlas's search.
  class CopyPhotosJob < ApplicationJob
    PER_SOURCE_INTERVAL = 1.0
    BUSY_RETRIES = 3
    TIMEOUT_PAUSE = 5
    SERVER_FAILURE_LIMIT = 3
    PROGRESS_INTERVAL = 2.seconds
    SAMPLE_LIMIT = 20

    class ServerRefused < StandardError; end

    def perform(job_id)
      job = Job.find(job_id)
      job.update(status: Job::JOB_STATUS_PROCESSING)

      begin
        run(job)
      rescue StandardError => error
        Rails.logger.error(["#{self.class} - #{error.class}: #{error.message}", error.backtrace].join("\n"))
        job.update(status: Job::JOB_STATUS_FAILED, extra: job.extra.merge('error' => error.message.truncate(1000), 'counts' => @counts).compact)
      end
    end

    private

    def run(job)
      @job = job
      @counts = Hash.new(0)
      @failures = []
      @last_request = {}
      @server_failures = 0
      @linked_places = []

      raise 'Photos can\'t be copied: this server isn\'t set up to upload to an IIIF image server.' unless PlacePhotos.available?

      model = ProjectModel.find(job.extra['project_model_id'])
      field = UserDefinedFields::UserDefinedField.find_by!(uuid: job.extra['photo_field_uuid'])
      @relationship = Atlases::Template.ensure_relationship!(model, 'Media', template_model: 'Places')
      @media_model = @relationship.related_model
      @featured = @relationship.user_defined_fields.find { |f| f.data_type == 'Boolean' && f.column_name.downcase.include?('featured') }
      @media_fields = @media_model.user_defined_fields.index_by(&:column_name)

      places = Place.where(project_model_id: model.id).where('user_defined ? :uuid', uuid: field.uuid).to_a
      linked = existing_media(places)
      total = places.size
      last_reported_at = nil

      ::OpenGeographiesPlatform::Indexing.suspend do
        places.each_with_index do |place, index|
          copy(place, place.user_defined[field.uuid].to_s.strip, linked[place.id])

          now = Time.current
          next unless last_reported_at.nil? || now - last_reported_at >= PROGRESS_INTERVAL

          report(index + 1, total)
          last_reported_at = now
        end
      end

      rebuild_manifests

      reindex = @counts['copied'].positive? ? queue_reindex([model, @media_model]) : nil

      job.update(
        status: Job::JOB_STATUS_COMPLETED,
        extra: job.extra.merge(
          'progress' => { 'completed' => total, 'total' => total },
          'counts' => @counts,
          'failures' => @failures.presence,
          'server' => PlacePhotos.server,
          'reindex_job_id' => reindex&.id
        ).compact
      )
    end

    # { place id => { urls: Set of import_urls already linked, featured: bool } }
    def existing_media(places)
      Relationship.where(project_model_relationship: @relationship, primary_record_type: Place.to_s, primary_record_id: places.map(&:id))
                  .includes(:related_record)
                  .each_with_object(Hash.new { |h, k| h[k] = { urls: Set.new, featured: false } }) do |relationship, linked|
        entry = linked[relationship.primary_record_id]
        entry[:urls] << relationship.related_record&.import_url
        entry[:featured] ||= @featured.present? && relationship.user_defined&.dig(@featured.uuid) == true
      end
    end

    def copy(place, url, linked)
      return @counts['not_a_link'] += 1 unless url.match?(%r{\Ahttps?://}i)
      if linked && linked[:urls].include?(url)
        # Copied by an earlier run whose manifest wasn't built: build it now.
        @linked_places << place.id unless Manifest.exists?(manifestable: place, project_model_relationship_id: @relationship.id)
        return @counts['already_copied'] += 1
      end

      download = download(url)
      content_type = Marcel::MimeType.for(Pathname.new(download.file.path))
      return failure(place, url, 'The address isn\'t an image.') unless content_type.start_with?('image/')

      name = place.name.presence || "Place #{place.id}"
      media = MediaContent.new(
        project_model_id: @media_model.id,
        name:,
        import_url: url,
        import_url_processed: true,
        published: place.published,
        user_defined: media_values(name)
      )
      media.content = ActionDispatch::Http::UploadedFile.new(
        tempfile: download.file,
        type: content_type,
        filename: File.basename(URI.parse(url).path).presence || "photo.#{content_type.split('/').last}"
      )

      unless media.save
        server_refused!(media.errors.full_messages.to_sentence)
        return failure(place, url, "The image server refused it: #{media.errors.full_messages.to_sentence.truncate(200)}")
      end

      @server_failures = 0
      featured = @featured && !(linked && linked[:featured])
      Relationship.create!(
        project_model_relationship: @relationship,
        primary_record: place,
        related_record: media,
        user_defined: featured ? { @featured.uuid => true } : {}
      )

      @counts['copied'] += 1
      @linked_places << place.id
    rescue RemoteFiles::Error => e
      failure(place, url, e.message)
    ensure
      download&.close!
    end

    # The places' IIIF manifests (what the detail page's viewer shows),
    # built by IIIF Cloud from their media. FairData rebuilds them when a
    # Media record is saved, but these were saved before they were linked.
    # A failure here leaves the photos copied and on result cards; saving a
    # place's media again in FairData rebuilds it.
    def rebuild_manifests
      return if @linked_places.empty?

      @linked_places.each_slice(100) do |ids|
        Iiif::Manifest.new.reset_manifests_by_type(Place, id: ids, project_model_relationship_id: @relationship.id, limit: ENV['IIIF_MANIFEST_ITEM_LIMIT'])
      end
    rescue StandardError => e
      Rails.logger.error("#{self.class} - manifests not rebuilt: #{e.class}: #{e.message}")
      @counts['manifests_failed'] += 1
    end

    # Media Type "image" (required by the template) and the place's name as
    # alt text.
    def media_values(name)
      {
        @media_fields['Media Type']&.uuid => 'image',
        @media_fields['Alt Text']&.uuid => name
      }.compact.reject { |uuid, _| uuid.nil? }
    end

    # Busy answers are waited out a few times; a source that was slow once
    # (the LOC's image server stalls now and then) gets one more try.
    def download(url)
      attempts = 0
      timed_out = false

      begin
        throttle(url)
        RemoteFiles.fetch(url)
      rescue RemoteFiles::Busy => e
        attempts += 1
        raise RemoteFiles::Failed, "#{e.message} Tried #{attempts} times." if attempts > BUSY_RETRIES

        sleep(e.retry_after)
        retry
      rescue RemoteFiles::TimedOut
        raise if timed_out

        timed_out = true
        sleep(TIMEOUT_PAUSE)
        retry
      end
    end

    # At most one request a second to each source host.
    def throttle(url)
      host = URI.parse(url).host
      wait = @last_request[host] && (PER_SOURCE_INTERVAL - (monotonic - @last_request[host]))
      sleep(wait) if wait&.positive?
      @last_request[host] = monotonic
    rescue URI::InvalidURIError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def server_refused!(message)
      @server_failures += 1
      return if @server_failures < SERVER_FAILURE_LIMIT

      raise ServerRefused, "The image server (#{PlacePhotos.server}) refused #{SERVER_FAILURE_LIMIT} uploads in a row: #{message.truncate(300)}"
    end

    def failure(place, url, reason)
      @counts['failed'] += 1
      @failures << { 'place' => place.name, 'url' => url, 'reason' => reason } if @failures.size < SAMPLE_LIMIT
      nil
    end

    def report(completed, total)
      @job.update_columns(
        extra: @job.extra.merge('progress' => { 'completed' => completed, 'total' => total }, 'counts' => @counts),
        updated_at: Time.current
      )
    end

    def queue_reindex(models)
      Job.create(
        project_id: @job.project_id,
        user_id: @job.user_id,
        job_type: Job::JOB_TYPE_REINDEX,
        extra: { project_model_ids: models.map(&:id) }
      )
    end
  end
end
