module CoreDataConnector
  module Public
    module V1
      # GET /core_data/public/v1/assets/:key(/:filename)
      #
      # Serves an image a curator uploaded for an atlas (Site#assets) to the
      # public, or one of its web-sized copies (Site#asset_variants): the
      # atlas's logo, favicon and page images, which the renderer references
      # by this path. Only blobs attached to a site as one of those are
      # served: the same blob table holds dataset uploads and job exports,
      # which this must never hand out.
      #
      # Not gated on the project being discoverable: an asset exists only to
      # be shown on the atlas, its key is an unguessable 28-character token,
      # and the console previews images through this same URL (an <img> can't
      # carry the console's token) for atlases that aren't published yet.
      #
      # Our own route rather than ActiveStorage's: on the merged host the
      # SPA catch-all is drawn ahead of ActiveStorage's routes, so
      # rails_blob_url answers with the console's index.html. The response is
      # immutable (a new upload is a new key) and, since SVG is allowed,
      # sandboxed: opened directly, an SVG can't run script on this origin.
      class AssetsController < ApplicationController
        include UnauthenticateableController

        def show
          blob = ActiveStorage::Blob.find_by(key: params[:key].to_s)

          attached = blob && ActiveStorage::Attachment.exists?(
            blob_id: blob.id,
            record_type: Site.name,
            name: %w[assets asset_variants]
          )

          return head :not_found unless attached

          response.headers['X-Content-Type-Options'] = 'nosniff'
          response.headers['Content-Security-Policy'] = "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox"
          response.headers['Cross-Origin-Resource-Policy'] = 'cross-origin'
          expires_in 1.year, public: true, immutable: true

          return unless stale?(etag: blob.checksum, public: true)

          send_data blob.download,
                    type: blob.content_type,
                    disposition: 'inline',
                    filename: blob.filename.sanitized
        end
      end
    end
  end
end
