# frozen_string_literal: true

# Demo seed, run by the host container after db:prepare (idempotent — every
# step skips what already exists):
#
#   1. an admin account for the console and the engine pages;
#   2. the Historic Rural Churches of Georgia project, cloned from the live
#      instance's public API (coredata.ecds.io, project 2) — the first real
#      atlas through the stack — with its search collection, its site (slug
#      `hrcga`, live at http://hrcga.localhost:4321) and the churches
#      reindexed into the shared v1 index.
#
# The fetched snapshot is cached under tmp/og_import (a compose volume), so a
# rebuild doesn't walk the source again. DEMO_SKIP_HRCGA=1 seeds only the
# account.

require 'open_geographies/public_project_import'

log = ->(message) { $stdout.puts("[demo seed] #{message}"); $stdout.flush }

# --- 1. Admin -------------------------------------------------------------

email = ENV.fetch('DEMO_ADMIN_EMAIL', 'admin@example.com')
password = ENV.fetch('DEMO_ADMIN_PASSWORD', 'Changeme1!!')

user = CoreDataConnector::User.find_by(email:)

if user
  log.call("admin #{email} exists")
else
  # skip_invitation: the host's after-create hook otherwise replaces the
  # password with a random one and emails it (an invitation nobody receives).
  CoreDataConnector::User.create!(
    name: 'Administrator',
    email:,
    password:,
    password_confirmation: password,
    role: CoreDataConnector::User::ROLE_ADMIN,
    skip_invitation: true
  )
  log.call("created admin #{email}")
end

exit if ENV['DEMO_SKIP_HRCGA'] == '1'

# --- 2. HRCGA -------------------------------------------------------------

SLUG = 'hrcga'
NAME = 'Historic Rural Churches of Georgia'
SOURCE = ENV.fetch('DEMO_HRCGA_SOURCE', 'https://coredata.ecds.io')
SOURCE_PROJECT_ID = ENV.fetch('DEMO_HRCGA_PROJECT_ID', '2')

site = CoreDataConnector::Site.find_by(slug: SLUG)

if site
  log.call("site #{SLUG} exists (project #{site.project_id}) — nothing to do")
  exit
end

project = CoreDataConnector::Project.find_by(name: NAME)

unless project
  log.call("importing #{NAME} from #{SOURCE} (project #{SOURCE_PROJECT_ID}) — a few minutes on first run")
  project = OpenGeographies::PublicProjectImport.new(
    source: SOURCE, project_id: SOURCE_PROJECT_ID, name: NAME, slug: SLUG, log: $stdout
  ).run!
end

models = CoreDataConnector::ProjectModel.where(project_id: project.id)
churches = models.find_by!(name: 'Churches')

# The indexer tells the atlas's primary places apart from other Place-classed
# models (States, map layers) by this role.
if defined?(CoreDataConnector::OpenGeographies::ProjectModelRole)
  CoreDataConnector::OpenGeographies::ProjectModelRole.find_or_create_by!(project_model_id: churches.id, role: 'primary_place')
end

collection = CoreDataConnector::SearchCollection.find_or_create_by!(project_id: project.id, name: 'hrcga_churches') do |c|
  c.project_model_ids = [churches.id]
  c.auto_index = true
end

site = CoreDataConnector::Site.create!(
  project_id: project.id,
  name: NAME,
  slug: SLUG,
  config: {
    'i18n' => { 'locales' => ['en'], 'default_locale' => 'en' },
    'layers' => [
      { 'name' => 'OpenStreetMap', 'layer_type' => 'raster', 'url' => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png' }
    ],
    'search' => [
      {
        'name' => 'places',
        'route' => '/places',
        'search_collection_id' => collection.id,
        'geosearch' => true,
        'facets' => [
          { 'name' => 'types', 'type' => 'list' },
          { 'name' => 'denomination_facet', 'type' => 'list' },
          { 'name' => 'administrative_area.name', 'type' => 'list' }
        ],
        'result_card' => {
          'title' => 'name',
          'attributes' => [{ 'name' => 'denomination_facet' }, { 'name' => 'types' }],
          'relationships' => %w[media works]
        },
        'map' => { 'geometry' => 'geometry', 'max_zoom' => 16, 'zoom_to_place' => true, 'cluster_radius' => 8 }
      }
    ],
    # Curator bookkeeping that isn't for the public page.
    'detail_pages' => { 'models' => { 'places' => { 'exclude' => %w[legacy_id wordpress_link slug] } } }
  },
  branding: {},
  navigation: {}
)
log.call("created site #{SLUG} (id #{site.id}) on project #{project.id}")

# Only the churches: the media/works/people documents aren't needed to
# render the atlas, and reindexing all 6,000+ takes a quarter hour.
log.call("reindexing #{churches.name}…")
count = OpenGeographies::Indexing.reindex_project_models([churches]) do |completed, total|
  log.call("  #{completed}/#{total}") if completed.positive? && (completed % 500).zero?
end
log.call("reindexed #{count} records into #{OpenGeographies::Indexing.index_name}")
log.call("HRCGA is live: http://#{SLUG}.localhost:4321/en/search/places")
