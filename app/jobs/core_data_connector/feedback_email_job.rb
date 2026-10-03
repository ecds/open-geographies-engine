module CoreDataConnector
  # Emails a feedback report to OG_FEEDBACK_EMAIL. The report is already
  # saved; a delivery that fails is retried twice and then recorded on the
  # report (the admin list shows it), never lost.
  class FeedbackEmailJob < ApplicationJob
    queue_as :default

    retry_on StandardError, wait: 30.seconds, attempts: 3 do |job, error|
      FeedbackReport.where(id: job.arguments.first).update_all(email_error: "#{error.class}: #{error.message}".truncate(500))
    end

    def perform(report_id)
      report = FeedbackReport.find_by(id: report_id)
      recipients = FeedbackReport.email_recipients
      return if report.nil? || report.emailed_at || recipients.empty?

      FeedbackMailer.report(report, recipients).deliver_now
      report.update_columns(emailed_at: Time.current, email_error: nil)
    end
  end
end
