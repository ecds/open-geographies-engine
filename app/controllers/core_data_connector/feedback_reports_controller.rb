module CoreDataConnector
  # "Send feedback" from the atlas console.
  #
  #   POST  /core_data/feedback_reports   (multipart, or JSON without a screenshot)
  #         what_happened, expected, page_url, site_id, context[...], screenshot
  #         → 201 { feedback_report: {...} }
  #   GET   /core_data/feedback_reports?status=new&page=1
  #         → { feedback_reports: [...], total, page, per_page }   admins: all; others: their own
  #   GET   /core_data/feedback_reports/:id
  #   PATCH /core_data/feedback_reports/:id   { status: new|resolved }   admins
  #   GET   /core_data/feedback_reports/:id/screenshot   the image, to its sender and admins
  #
  # A report may name an atlas (site_id) only one the sender can see (404
  # otherwise, as for any atlas they can't); its project is taken from the
  # atlas. Twenty reports an hour per person (429 past that).
  class FeedbackReportsController < ApplicationController
    PER_PAGE = 25

    def index
      reports = policy_scope(FeedbackReport).includes(:user, :site, :project, screenshot_attachment: :blob).order(created_at: :desc)
      reports = reports.where(status: params[:status]) if FeedbackReport::STATUSES.include?(params[:status])

      page = [params[:page].to_i, 1].max
      total = reports.count

      render json: {
        feedback_reports: reports.offset((page - 1) * PER_PAGE).limit(PER_PAGE).map { |report| report_json(report) },
        total:,
        page:,
        per_page: PER_PAGE,
        counts: policy_scope(FeedbackReport).group(:status).count
      }, status: :ok
    end

    def show
      report = policy_scope(FeedbackReport).find(params[:id])
      authorize report, :show?

      render json: { feedback_report: report_json(report) }, status: :ok
    end

    def create
      authorize FeedbackReport.new, :create?

      if FeedbackReport.where(user_id: current_user.id).where('created_at > ?', 1.hour.ago).count >= FeedbackReport::HOURLY_LIMIT
        render json: { errors: [{ base: 'You’ve sent a lot of feedback in the last hour; please try again later.' }] }, status: :too_many_requests and return
      end

      site = params[:site_id].present? ? policy_scope(Site).find_by(id: params[:site_id]) : nil
      render json: { errors: [{ base: 'That atlas was not found.' }] }, status: :not_found and return if params[:site_id].present? && site.nil?

      report = FeedbackReport.new(
        user: current_user,
        site:,
        project_id: site&.project_id,
        what_happened: params[:what_happened],
        expected: params[:expected],
        page_url: params[:page_url],
        context: params[:context] || {}
      )

      if (problem = attach_screenshot(report, params[:screenshot]))
        render json: { errors: [{ screenshot: [problem] }] }, status: :unprocessable_entity and return
      end

      unless report.save
        render json: { errors: [report.errors.to_hash] }, status: :unprocessable_entity and return
      end

      FeedbackEmailJob.perform_later(report.id) if FeedbackReport.email_recipients.any?

      render json: { feedback_report: report_json(report) }, status: :created
    end

    def update
      report = policy_scope(FeedbackReport).find(params[:id])
      authorize report, :update?

      status = params[:status].to_s
      render json: { errors: [{ status: ['must be new or resolved'] }] }, status: :unprocessable_entity and return unless FeedbackReport::STATUSES.include?(status)

      report.update!(
        status:,
        resolved_at: status == 'resolved' ? (report.resolved_at || Time.current) : nil,
        resolved_by_id: status == 'resolved' ? (report.resolved_by_id || current_user.id) : nil
      )

      render json: { feedback_report: report_json(report) }, status: :ok
    end

    def screenshot
      report = policy_scope(FeedbackReport).find(params[:id])
      authorize report, :show?

      blob = report.screenshot.blob
      return head :not_found unless blob

      response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
      response.headers['X-Content-Type-Options'] = 'nosniff'
      response.headers['Cache-Control'] = 'private, no-store'

      send_data blob.download, type: blob.content_type, disposition: 'inline', filename: blob.filename.to_s
    end

    private

    # Attaches the screenshot, or answers why it can't be: its type read from
    # its bytes, a PNG, JPEG or WebP image of at most 10 MB.
    def attach_screenshot(report, upload)
      return nil if upload.blank?
      return 'Attach the screenshot as an image file.' unless upload.respond_to?(:tempfile)

      if upload.size > FeedbackReport::MAX_SCREENSHOT_BYTES
        return "The screenshot can be at most #{FeedbackReport::MAX_SCREENSHOT_BYTES / 1.megabyte} MB."
      end

      filename = File.basename(upload.original_filename.to_s).presence || 'screenshot.png'
      content_type = Marcel::MimeType.for(Pathname.new(upload.tempfile.path), name: filename)
      return 'The screenshot must be a PNG, JPEG or WebP image.' unless FeedbackReport::SCREENSHOT_TYPES.include?(content_type)

      report.screenshot.attach(io: File.open(upload.tempfile.path), filename:, content_type:, identify: false)
      nil
    end

    def report_json(report)
      {
        id: report.id,
        status: report.status,
        what_happened: report.what_happened,
        expected: report.expected,
        page_url: report.page_url,
        context: report.context,
        user: report.user && { id: report.user.id, name: report.user.name, email: report.user.email },
        site: report.site && { id: report.site.id, name: report.site.name, slug: report.site.slug },
        project: report.project && { id: report.project.id, name: report.project.name },
        screenshot: report.screenshot.attached? ? { byte_size: report.screenshot.blob.byte_size, content_type: report.screenshot.blob.content_type } : nil,
        email_status: report.email_status,
        email_error: current_user.admin? ? report.email_error : nil,
        resolved_at: report.resolved_at,
        created_at: report.created_at
      }
    end
  end
end
