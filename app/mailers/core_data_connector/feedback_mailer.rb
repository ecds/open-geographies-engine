module CoreDataConnector
  # A feedback report by email, to OG_FEEDBACK_EMAIL: plain text, the
  # screenshot attached (up to 5 MB; a larger one is left in the console, as
  # Postmark's 10 MB counts the encoded attachment), replies going to the
  # sender. Sent from
  # OG_FEEDBACK_FROM, else the host's POSTMARK_FROM (FairData's sender for
  # its own invitations), through the host's mail delivery.
  class FeedbackMailer < ActionMailer::Base
    layout false

    def report(report, to)
      @report = report
      @console_url = ENV['CORE_DATA_PUBLIC_URL'].to_s.chomp('/')

      @screenshot = report.screenshot.attached? ? report.screenshot.blob : nil
      @screenshot_attached = @screenshot && @screenshot.byte_size <= FeedbackReport::MAX_EMAILED_SCREENSHOT_BYTES
      attachments[@screenshot.filename.to_s] = { mime_type: @screenshot.content_type, content: @screenshot.download } if @screenshot_attached

      about = report.site&.name || 'the atlas console'
      mail(
        to:,
        from: ENV['OG_FEEDBACK_FROM'].presence || ENV['POSTMARK_FROM'].presence || 'no-reply@example.com',
        reply_to: report.user&.email.presence,
        subject: "Open Geographies feedback: #{about} — #{report.what_happened.squish.truncate(60)}"
      )
    end
  end
end
