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
  # Two kinds of the host's paths never answer from the internet. Caddy
  # refuses them first; this refuses them in Rails as well:
  # - Active Storage's own endpoints. Its direct-upload URLs take files from
  #   anyone, and neither console uses them (their GETs only ever reached the
  #   console's catch-all route anyway).
  # - The job dashboard, /sidekiq: Basic auth with no attempt limit, and it
  #   shows job arguments. It answers only to a request from the server
  #   itself, addressed to localhost: an SSH tunnel's (README: "The job
  #   dashboard"), which arrives from the stack network's gateway, or one
  #   made inside this container. Caddy's requests never come from either,
  #   and neither address can be set by a header.
  class Guard
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    # The stack network's gateway: the default route in /proc/net/route,
    # whose addresses are little-endian hex.
    def self.gateway
      route = File.readlines('/proc/net/route').map(&:split).find { |fields| fields[1] == '00000000' }
      route && [route[2]].pack('H8').bytes.reverse.join('.')
    rescue SystemCallError
      nil
    end

    LOCAL_PEERS = ['127.0.0.1', '::1', gateway].compact.freeze

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

    # REMOTE_ADDR is the connection's own address (this runs before Rails'
    # proxy handling), and the Host header is read directly: Rack's #host
    # would take X-Forwarded-Host.
    def local?(env)
      host = env['HTTP_HOST'].to_s.downcase.sub(/:\d+\z/, '').delete_prefix('[').delete_suffix(']')

      LOCAL_PEERS.include?(env['REMOTE_ADDR']) && LOCAL_HOSTS.include?(host)
    end
  end
end

Rails.application.config.middleware.insert_before 0, OpenGeographiesInstall::Guard
