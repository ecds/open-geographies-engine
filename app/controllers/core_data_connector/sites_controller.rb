module CoreDataConnector
  class SitesController < ApplicationController
    # Search attributes
    search_attributes :name, :slug

    # Preloads
    preloads :project

    # GET /core_data/sites/:id/facets
    #
    # The facet attributes this site's searches can declare, derived from the
    # v1 index's mapping and promotion rules for the project's models (see
    # OpenGeographiesPlatform::FacetCatalog). The console's facet pick-list.
    def facets
      site = Site.find(params[:id])
      authorize site, :show?

      models = ProjectModel.where(project_id: site.project_id).order(:order)

      render json: { facets: ::OpenGeographiesPlatform::FacetCatalog.for_models(models).map(&:to_h) }, status: :ok
    end

    # GET /core_data/sites/:id/fields
    #
    # The fields each detail page / search panel can hide, per renderer model
    # (see OpenGeographiesPlatform::FieldCatalog). The console's "Hidden fields"
    # pick-list, stored as detail_pages.models.<model>.exclude.
    def fields
      site = Site.find(params[:id])
      authorize site, :show?

      models = ProjectModel.where(project_id: site.project_id).order(:order)

      render json: { models: ::OpenGeographiesPlatform::FieldCatalog.for_models(models) }, status: :ok
    end

    # GET /core_data/sites/:id/search_fields
    #
    # The text fields this site's searches can look in besides the name, with
    # where the index holds each (OpenGeographiesPlatform::FacetCatalog
    # .search_fields_for_models). The console's "Also search in" list,
    # stored per search as `search_fields`.
    def search_fields
      site = Site.find(params[:id])
      authorize site, :show?

      models = ProjectModel.where(project_id: site.project_id).order(:order)

      render json: { search_fields: ::OpenGeographiesPlatform::FacetCatalog.search_fields_for_models(models) }, status: :ok
    end

    # GET /core_data/sites/:id/config
    #
    # Emits the config.json document for the site: the stored config with the
    # platform-derived sections (Core Data connection, the shared search index)
    # filled in.
    #
    # The shared dynamic renderer resolves a site by slug through the public
    # endpoint (GET /core_data/public/v1/atlases/:slug); this authenticated,
    # id-addressed variant remains for console previews and tooling. Named
    # site_config because ActionController reserves #config.
    def site_config
      site = Site.find(params[:id])

      authorize site, :show?

      render json: site.to_site_config, status: :ok
    end

    # POST /core_data/sites/:id/build_tiles
    #
    # Queues PMTiles generation from the site's project geometries. The run is
    # tracked as a Job (job_type "build_tiles") so its status is visible in the
    # console. The generated archive is self-hosted (S3) and referenced by the
    # site config's pmtiles layer, served to the shared renderer's map.
    def build_tiles
      site = Site.find(params[:id])

      authorize site, :update?

      job = Job.create(
        project_id: site.project_id,
        user_id: current_user.id,
        job_type: Job::JOB_TYPE_BUILD_TILES,
        extra: {
          site_id: site.id,
          site_slug: site.slug
        }
      )

      render json: { job: { id: job.id, status: job.status } }, status: :ok
    end

    # GET /core_data/sites/:id/assets
    #
    # The images uploaded for this atlas, newest first: the console's image
    # picker for the logo, favicon and page sections.
    def assets
      site = Site.find(params[:id])
      authorize site, :show?

      attachments = site.assets_attachments.includes(:blob).order(created_at: :desc)

      render json: { assets: attachments.map { |attachment| asset_json(attachment.blob) } }, status: :ok
    end

    # POST /core_data/sites/:id/assets (multipart `file`)
    #
    # Uploads an image for the atlas. The type is read from the file's
    # contents, not the browser's claim, and must be one of
    # Site::ASSET_CONTENT_TYPES, or a TIFF, which is stored as a JPEG;
    # raster images get web-sized copies (SiteImages). Answers with the asset, including the public path the
    # pages and branding reference it by.
    def upload_asset
      site = Site.find(params[:id])
      authorize site, :update?

      upload = params.require(:file)
      filename = File.basename(upload.original_filename.to_s).presence || 'image'
      content_type = Marcel::MimeType.for(Pathname.new(upload.tempfile.path), name: filename)

      tiff = content_type == SiteImages::TIFF

      unless Site::ASSET_CONTENT_TYPES.include?(content_type) || tiff
        render json: { errors: [{ base: 'Upload a PNG, JPEG, GIF, WebP, AVIF, SVG, ICO or TIFF image.' }] }, status: :unprocessable_entity and return
      end

      if tiff && !SiteImages.converts_tiff?
        render json: { errors: [{ base: SiteImages::TIFF_UNSUPPORTED }] }, status: :unprocessable_entity and return
      end

      # TIFFs (archival scans) run larger; they're stored as a JPEG.
      limit = tiff ? SiteImages::MAX_TIFF_BYTES : Site::MAX_ASSET_BYTES
      if upload.size > limit
        kind = tiff ? 'TIFF images' : 'Images'
        render json: { errors: [{ base: "#{kind} can be at most #{limit / 1.megabyte} MB." }] }, status: :unprocessable_entity and return
      end

      blob = SiteImages.upload(site, upload.tempfile.path, filename:, content_type:)

      render json: { asset: asset_json(blob) }, status: :ok
    rescue SiteImages::Error => e
      render json: { errors: [{ base: e.message }] }, status: :unprocessable_entity
    end

    # POST /core_data/sites/:id/preview_token
    #
    # A new preview link for a draft atlas; links handed out before stop
    # working.
    def regenerate_preview_token
      site = Site.find(params[:id])
      authorize site, :update?

      site.regenerate_preview_token

      render json: { preview_token: site.preview_token }, status: :ok
    end

    # DELETE /core_data/sites/:id/assets/:key
    #
    # Removes an uploaded image and its copies. Pages or branding still
    # pointing at it show nothing where the image was.
    def destroy_asset
      site = Site.find(params[:id])
      authorize site, :update?

      attachment = site.assets_attachments.joins(:blob).find_by(active_storage_blobs: { key: params[:key] })
      return head :not_found unless attachment

      SiteImages.purge(site, attachment)

      head :no_content
    end

    private

    def asset_json(blob)
      {
        key: blob.key,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        width: blob.metadata['width'],
        height: blob.metadata['height'],
        path: Site.asset_path(blob),
        thumbnail_path: SiteImages.thumbnail_path(blob) || Site.asset_path(blob),
        created_at: blob.created_at
      }
    end

    # A site's project is fixed at creation (attr_readonly on the model):
    # authorization runs against the current project before an update, so a
    # project_id in an update body is dropped rather than raising.
    def prepare_params(item = nil)
      prepared = super

      item&.persisted? ? prepared.except('project_id', :project_id) : prepared
    end

  end
end
