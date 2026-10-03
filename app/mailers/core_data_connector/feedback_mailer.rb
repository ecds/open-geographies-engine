module CoreDataConnector
  # A feedback report by email, to OG_FEEDBACK_EMAIL: plain text, the
  # screenshot attached, replies going to the sender. Sent from
  # OG_FEEDBACK_FROM, else the host's POSTMARK_FROM (FairData's sender for
  # its own invitations), through the host's mail delivery.
  class FeedbackMailer < ActionMailer::Base
    layout false

    def report(report, to)
      @report = report
      @console_url = ENV['CORE_DATA_PUBLIC_URL'].to_s.chomp('/')

      if report.screenshot.attached?
        blob = report.screenshot.blob
        attachments[blob.filename.to_s] = { mime_type: blob.content_type, content: blob.download }
      end

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
