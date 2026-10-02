# frozen_string_literal: true

# The two-tenant security probe.
#
#   bin/rails open_geographies:tenancy_probe HOST=http://localhost:3001 [KEEP=1]
#
# Builds two tenants in the host's database — two owner users, two projects,
# a site, search collection and job each; one project discoverable, the other
# not — then exercises the engine's HTTP surface as each owner and as nobody,
# asserting that tenant A cannot read, list, write or run jobs against tenant
# B through any endpoint the engine adds. The renderer's half of the same
# contract (the search handler over a shared index) is core-data-places'
# test/tenancy.test.ts.
#
# Runs against a live host so it exercises the real routing, authentication
# and policy stack rather than a dummy app. Fixture rows are removed at the end
# unless KEEP=1. Exits non-zero on the first failing group.
namespace :open_geographies do
  desc 'Two-tenant security probe against a running host (HOST=http://localhost:3001)'
  task tenancy_probe: :environment do
    require 'net/http'
    require 'json'

    host = ENV.fetch('HOST', 'http://localhost:3001')
    password = 'Tenancy-Probe-2026!'

    fixtures = OpenGeographiesPlatform::TenancyProbe::Fixtures.build!(password:)
    probe = OpenGeographiesPlatform::TenancyProbe.new(host:, fixtures:, password:)

    begin
      probe.run!
    ensure
      fixtures.teardown! unless ENV['KEEP'] == '1'
    end

    abort("\n#{probe.failures.size} check(s) FAILED") if probe.failures.any?

    puts "\nAll #{probe.checks} checks passed."
  end

  # The host half: FairData's own admin API, as the same two owners. See
  # OpenGeographiesPlatform::HostTenancyProbe for what it checks and why.
  #
  #   bin/rails open_geographies:host_tenancy_probe HOST=http://localhost:3001 [KEEP=1]
  desc 'Two-tenant probe of the host\'s own admin API: re-parenting and cross-tenant links (HOST=)'
  task host_tenancy_probe: :environment do
    require 'net/http'
    require 'json'

    host = ENV.fetch('HOST', 'http://localhost:3001')
    password = 'Tenancy-Probe-2026!'

    fixtures = OpenGeographiesPlatform::TenancyProbe::Fixtures.build!(password:)
    probe = OpenGeographiesPlatform::HostTenancyProbe.new(host:, fixtures:, password:)

    begin
      probe.run!
    ensure
      fixtures.teardown! unless ENV['KEEP'] == '1'
    end

    puts "\nSkipped (untestable on this host): #{probe.skipped.size}" if probe.skipped.any?
    probe.skipped.each { |s| puts "  #{s}" }

    abort("\n#{probe.failures.size} of #{probe.checks} check(s) FAILED:\n  #{probe.failures.join("\n  ")}") if probe.failures.any?

    puts "\nAll #{probe.checks} checks passed."
  end
end

namespace :open_geographies do
  desc 'Clone a discoverable project from another instance\'s public API ' \
       '(SOURCE=, PROJECT_ID=, NAME=, [SLUG=], [RELATED_PROJECTS="Contained In=7,…"])'
  task import_public_project: :environment do
    source = ENV.fetch('SOURCE')
    project_id = ENV.fetch('PROJECT_ID')
    name = ENV.fetch('NAME')
    # Which project a relationship's targets live in, for sources whose
    # descriptors don't carry related_project_id yet.
    related_projects = ENV.fetch('RELATED_PROJECTS', '').split(',').filter_map do |pair|
      label, id = pair.split('=', 2)
      [label.strip, id.strip] if label.present? && id.present?
    end.to_h

    project = OpenGeographiesPlatform::PublicProjectImport.new(source:, project_id:, name:, slug: ENV['SLUG'], related_projects:).run!

    puts "\nImported project #{project.id} (#{project.name})."
  end
end

namespace :open_geographies do
  desc 'Make web-sized copies of atlas images uploaded before copies existed or without libvips ([SITE=id])'
  task image_copies: :environment do
    abort('libvips is not available: install it (Debian: libvips42, macOS: brew install vips) and retry.') unless CoreDataConnector::SiteImages.available?

    sites = ENV['SITE'].present? ? CoreDataConnector::Site.where(id: ENV['SITE']) : CoreDataConnector::Site.all

    sites.find_each do |site|
      count = CoreDataConnector::SiteImages.backfill(site)
      puts "#{site.slug}: #{count} image(s) copied" if count.positive?
    end
  end

  desc 'Check every atlas domain\'s DNS again: connect the ones that now point at their atlas, ' \
       'disconnect the ones that stopped (run it from cron, e.g. hourly)'
  task check_domains: :environment do
    CoreDataConnector::Site.where.not(domain: nil).find_each do |site|
      was = site.domain_status
      result = site.check_domain!
      now = site.domain_status

      puts "#{site.slug}: #{site.domain} #{was} → #{now}#{result.connected ? '' : " (#{result.message})"}" if was != now
    end
  end
end
