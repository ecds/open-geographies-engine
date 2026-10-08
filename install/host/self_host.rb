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
