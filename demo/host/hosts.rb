# frozen_string_literal: true

# Demo stack only. The renderer container calls this host by its compose
# service name; Rails' development host authorization would refuse it.
Rails.application.config.hosts.concat(ENV.fetch('DEMO_ALLOWED_HOSTS', 'host').split(',').map(&:strip))
