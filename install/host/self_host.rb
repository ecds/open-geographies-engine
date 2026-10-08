# frozen_string_literal: true

# Self-hosted install only (open-geographies-engine/install). The host's
# production config is written for ECDS's servers; these settings make it run
# on anyone's, without editing the host's own files.

# Host authorization: production.rb allows ECDS's names only. Allow the
# console's domain and the internal name the renderer calls it by.
Rails.application.config.hosts.concat(ENV.fetch('OG_ALLOWED_HOSTS', '').split(',').map(&:strip).reject(&:empty?))

# Uploaded files. production.rb sends them to S3 (its :amazon service); here
# they stay on the server (storage.yml's :local, the `storage` volume) unless
# S3_BUCKET names a bucket. Nothing the engines serve links to the store
# directly (images and datasets are read through the console), so a store the
# browser can't reach is fine.
if ENV['S3_BUCKET'].present?
  # Another S3-compatible store: its endpoint, and path-style addresses
  # (endpoint/bucket/key) if it needs them.
  s3 = {}
  s3[:endpoint] = ENV['S3_ENDPOINT'] if ENV['S3_ENDPOINT'].present?
  s3[:force_path_style] = true if ENV['S3_FORCE_PATH_STYLE'] == 'true'
  Aws.config.update(s3:) if s3.any?
else
  Rails.application.config.active_storage.service = :local
  # In case something loaded ActiveStorage::Blob before this file did.
  Rails.application.config.after_initialize do
    ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch(:local)
  end
end

# FairData emails a new account its password (Users::Invitations), and Active
# Job logs a job's arguments when it's queued: every invitation's password
# would be in the log in plain text.
Rails.application.config.after_initialize do
  ActionMailer::MailDeliveryJob.log_arguments = false
end

# Sign-in (POST /auth/login) has no limit of its own: at most 10 attempts from
# one address in 3 minutes. Caddy passes the client's address on, and Rails
# trusts it from the stack's private network.
Rails.application.config.to_prepare do
  JwtAuth::AuthenticationController.rate_limit to: 10, within: 3.minutes, only: :login, store: Rails.cache
end

module OpenGeographiesInstall
  # Two kinds of the host's paths never answer from the internet (Caddy
  # refuses them first; this holds behind any other proxy too):
  # - Active Storage's own endpoints. Its direct-upload URLs take files from
  #   anyone, and neither console uses them (their GETs only ever reached the
  #   console's catch-all route anyway).
  # - The job dashboard, /sidekiq: Basic auth with no attempt limit, and it
  #   shows job arguments. It answers only to a localhost address, i.e.
  #   through an SSH tunnel (README: "The job dashboard").
  class Guard
    LOCAL = %w[localhost 127.0.0.1 ::1].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      path = Rack::Utils.unescape_path(env['PATH_INFO'].to_s).squeeze('/').downcase

      if path.start_with?('/rails/active_storage/') || (path.start_with?('/sidekiq') && !local?(env))
        return [404, { 'content-type' => 'text/plain' }, ['Not Found']]
      end

      @app.call(env)
    end

    private

    # The Host header itself: Rack's #host would take X-Forwarded-Host, which
    # a client can set.
    def local?(env)
      LOCAL.include?(env['HTTP_HOST'].to_s.downcase.sub(/:\d+\z/, '').delete_prefix('[').delete_suffix(']'))
    end
  end
end

Rails.application.config.middleware.insert_before 0, OpenGeographiesInstall::Guard
