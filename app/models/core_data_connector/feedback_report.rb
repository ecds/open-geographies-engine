module CoreDataConnector
  # A curator's "Send feedback": what happened, what they expected, where
  # (the console page, the atlas), a little context the console gathers (the
  # error shown, the job, the browser) and an optional screenshot.
  #
  # Anyone signed in may send one; the platform's admins read them all, a
  # sender only their own (FeedbackReportPolicy). When OG_FEEDBACK_EMAIL is
  # set, each report is also emailed there (FeedbackEmailJob); the report is
  # saved first, so a mail problem never loses one.
  class FeedbackReport < ApplicationRecord
    STATUSES = %w[new resolved].freeze

    MAX_TEXT = 5000
    MAX_PAGE_URL = 2000
    # The console page a report came from: a path on the console's own site
    # ("/atlases/12/imports"), never another site's address — including
    # "//host" and "/\host", which browsers read as one.
    PAGE_PATH = %r{\A/(?![/\\])[^\s\\\x00-\x1f\x7f]*\z}
    MAX_SCREENSHOT_BYTES = 10.megabytes
    # Postmark refuses a message over 10 MB counted after base64 encoding (a
    # third larger); a bigger screenshot stays with the report in the console.
    MAX_EMAILED_SCREENSHOT_BYTES = 5.megabytes
    SCREENSHOT_TYPES = %w[image/png image/jpeg image/webp].freeze

    # Reports one person may send in an hour, counted under an advisory lock
    # per sender (pg_advisory_xact_lock(LOCK_NAMESPACE, user id)).
    HOURLY_LIMIT = 20
    LOCK_NAMESPACE = 0x4F46

    # What the console may put in `context`, each a short string.
    CONTEXT_KEYS = %w[source path error job_id user_agent viewport screen language].freeze
    MAX_CONTEXT_VALUE = 2000

    belongs_to :user, optional: true
    belongs_to :project, optional: true
    belongs_to :site, optional: true
    belongs_to :resolved_by, class_name: 'CoreDataConnector::User', optional: true

    has_one_attached :screenshot

    validates :what_happened, presence: true, length: { maximum: MAX_TEXT }
    validates :expected, length: { maximum: MAX_TEXT }
    validates :page_url, length: { maximum: MAX_PAGE_URL }
    validates :status, inclusion: { in: STATUSES }

    before_validation :normalize

    # Addresses reports are emailed to (OG_FEEDBACK_EMAIL, comma-separated),
    # or none.
    def self.email_recipients
      ENV.fetch('OG_FEEDBACK_EMAIL', '').split(',').map(&:strip).reject(&:empty?)
    end

    # Only the keys the console sends, as trimmed strings.
    def self.clean_context(value)
      hash = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
      hash.stringify_keys.slice(*CONTEXT_KEYS).transform_values { |v| v.to_s.strip.truncate(MAX_CONTEXT_VALUE) }.reject { |_k, v| v.empty? }
    rescue StandardError
      {}
    end

    # Where the email went, for the admin list.
    def email_status
      return 'sent' if emailed_at
      return 'failed' if email_error.present?
      return 'off' if self.class.email_recipients.empty?

      'pending'
    end

    private

    def normalize
      self.what_happened = what_happened.to_s.strip
      self.expected = expected.to_s.strip.presence
      self.page_url = page_url.to_s.strip.presence
      self.page_url = nil if page_url && !page_url.match?(PAGE_PATH)
      self.context = self.class.clean_context(context || {})
    end
  end
end
