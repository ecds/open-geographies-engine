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

    fixtures = OpenGeographies::TenancyProbe::Fixtures.build!(password:)
    probe = OpenGeographies::TenancyProbe.new(host:, fixtures:, password:)

    begin
      probe.run!
    ensure
      fixtures.teardown! unless ENV['KEEP'] == '1'
    end

    abort("\n#{probe.failures.size} check(s) FAILED") if probe.failures.any?

    puts "\nAll #{probe.checks} checks passed."
  end
end

namespace :open_geographies do
  desc 'Clone a discoverable project from another instance\'s public API (SOURCE=, PROJECT_ID=, NAME=, [SLUG=])'
  task import_public_project: :environment do
    source = ENV.fetch('SOURCE')
    project_id = ENV.fetch('PROJECT_ID')
    name = ENV.fetch('NAME')

    project = OpenGeographies::PublicProjectImport.new(source:, project_id:, name:, slug: ENV['SLUG']).run!

    puts "\nImported project #{project.id} (#{project.name})."
  end
end
