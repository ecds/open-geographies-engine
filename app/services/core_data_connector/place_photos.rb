# frozen_string_literal: true

module CoreDataConnector
  # Photos a dataset links to (a spreadsheet's Photo column) can be copied
  # onto the atlas's IIIF image server — Emory's IIIF Cloud on FairData —
  # instead of being shown from the source. Each becomes a Media record
  # (FairData's MediaContent, which uploads to IIIF Cloud when saved) linked
  # to its place through the canonical Places → Media relationship and
  # marked `featured`, so the index carries it as the place's
  # featured_media with an IIIF thumbnail. CopyPhotosJob does the copying.
  #
  # Available when FairData is configured to upload to IIIF Cloud
  # (IIIF_CLOUD_URL, IIIF_CLOUD_API_KEY, IIIF_CLOUD_PROJECT_ID). Without it,
  # photo links are shown from the source as before.
  module PlacePhotos
    module_function

    def available?
      return false unless defined?(::TripleEyeEffable)

      config = ::TripleEyeEffable.config
      [config.url, config.api_key, config.project_id].all?(&:present?)
    end

    # The image server's host, for the console ("iiif-cloud.ecds.io").
    def server
      available? ? URI.parse(::TripleEyeEffable.config.url).host : nil
    rescue URI::InvalidURIError
      nil
    end
  end
end
