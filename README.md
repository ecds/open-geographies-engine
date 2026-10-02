# open_geographies_platform

A Rails engine that extends Performant Software's **Core Data** (now **FairData**) with
the Open Geographies layer: a no-code, multi-tenant geospatial publishing platform
(atlas provisioning, Sites, authority bulk imports from GeoNames/Wikidata, and a
by-slug public atlas API for the shared dynamic renderer). It is the upper layer of
Open Geographies; the lower layer — the canonical schema, the v1 API and Elasticsearch
indexing — is
[`open-geographies-fairdata`](https://github.com/ecds/open-geographies-fairdata) (gem
`open_geographies_fairdata`, module `OpenGeographies`; renamed from
`core-data-connector-open-geographies` on 2026-09-11).

Because the lower engine took the bare `OpenGeographies` module, this engine's Ruby
namespace is **`OpenGeographiesPlatform`** (gem `open_geographies_platform`). Its
domain classes still live in `CoreDataConnector::`; references into the lower engine
are written `::OpenGeographies::V1::…` / `::OpenGeographies::ProjectModelRole`.

Running it in production (with the renderer): [`PRODUCTION.md`](PRODUCTION.md), the
readiness checklist. Trying it locally in one command: [`demo/`](demo/).

## Why an engine

Jay/Emory asked that we **not diverge** the `core-data-connector` / `core-data-cloud`
forks from Performant upstream — fork modifications (especially schema migrations)
make future upstream updates conflict-prone. This engine packages all the Open
Geographies additions so the connector and cloud apps stay **clean upstream mirrors**.

It is **additive by construction**:

- **Schema:** its migrations only `create_table` the two new tables
  (`core_data_connector_sites`, `core_data_connector_search_collections`). They never
  `ALTER` an upstream Core Data table, so they install onto a clean upstream schema
  with no reconciliation.
- **Code:** the ~28 new classes live in the `CoreDataConnector` namespace (they are
  Core Data domain objects). The ~20 places the fork used to *modify* upstream files
  are applied at boot as **decorators** (`lib/open_geographies_platform/decorators.rb`), never
  as forked copies — so there are no file collisions and the upstream surface we track
  is just the decorator list.
- **Routes:** appended into the connector engine's `/core_data` route set.

## Local development against the real host

Develop against what actually deploys: ECDS's `core-data-cloud` fork on branch `ecds`
(the merged Core Data / FairData app, with the lower-layer engine already in its
Gemfile), with this engine mounted from a local path.

```sh
git clone --branch ecds https://github.com/ecds/core-data-cloud.git ecds-core-data-cloud
cd ecds-core-data-cloud
# Gemfile: gem 'open_geographies_platform', path: '../open-geographies-engine'
cp .env.example .env   # DATABASE_*, SECRET_KEY_BASE, ELASTICSEARCH_HOST/API_KEY, REDIS_URL
bundle install
bin/rails db:create
bin/rails railties:install:migrations FROM=open_geographies            # the lower engine's
bin/rails railties:install:migrations FROM=open_geographies_platform   # ours
bin/rails db:migrate
bin/rails runner 'Rails.application.eager_load!; puts "ok"'
```

Verified 2026-09-11 on `ecds` @ `ff020c5` (lower engine `67d0728`) with Ruby 4.0.5:
bundle resolves both engines, both `Engine` classes load with their own roots, all
migrations apply (including the lower engine's table rename), eager load is clean,
every route this engine adds appears under `/core_data` alongside the lower engine's
mount at `/open_geographies`, and the tenancy probe passes 37/37.

## Install (host app)

```ruby
# Gemfile (host = core-data-cloud / FairData, which provides the CoreDataConnector
# classes natively — the standalone core_data_connector gem no longer exists)
gem 'open_geographies_platform', git: 'https://github.com/ecds/open-geographies-engine.git'
```

The engine declares no dependency on `core_data_connector`: it needs the
`CoreDataConnector` classes to exist at boot, however the host provides them. On the
merged app they are native code. Routes are appended under the host's existing
`/core_data` scope (or to the connector engine's route set on a legacy gem-based host).

```sh
bundle install
bin/rails open_geographies:install:migrations   # copies the additive migrations
bin/rails db:migrate
```

The host already mounts `CoreDataConnector::Engine` at `/core_data`; this engine adds
its routes there automatically. Nothing else to wire.

## Provisioning is the canonical template

`Atlases::Template` creates a wizard-born atlas's models, user-defined fields and
relationships from `canonical_template.json` — the lower engine's own copy when that engine
is loaded, else `lib/open_geographies_platform/canonical_template.json` (a vendored snapshot of the lower engine's 0.3.0; never
edit it here — the template's home is the lower engine's repo). Because the lower engine's
`PromotedRelationships` matches names against the same document, a wizard-born atlas is
compliant by construction: "Types" on Places indexes as `types`, "Short Description" as
`short_description`, and so on. Two starters: `places` (Places + Types) and `atlas` (every
non-optional model), plus optional modules by name (Map Layers, Work Types, Tours).

## The console pages (`/wizard`, `/atlases`)

The engine serves its own console pages — the "Create your atlas" wizard at `/wizard`
and the atlas pages at `/atlases` (list; per atlas: settings, place imports, jobs) — from
one small React app that lives in this engine (`client/`). FairData only needs a
navigation link to `/wizard` or `/atlases`; everything past the link is the engine's.

The atlas settings editor covers name/slug, branding (logo, favicon, share image, fonts,
colors, footer), the home page, standalone pages and the menu (see "An atlas is a site"
below), map layers, search apps (collection, facets, result card), detail-page field
hiding, an Advanced JSON tab for the rest of the config with the emitted config.json, plus
Reindex and Build map tiles. Facet choices come from
`GET /core_data/sites/:id/facets` (`OpenGeographies::FacetCatalog`), which derives what is
actually facetable from the v1 mapping and the template's promotion rules — so the
pick-list never offers an attribute the index can't aggregate.

- It calls the engine's own admin API (`POST /core_data/atlases`, `GET /core_data/jobs/:id`,
  the `place_imports` endpoints) with the session the console already holds
  (`localStorage['core_data_cloud_user']`, sent as `Authorization`), so it needs no login
  of its own. In Clerk mode the `__session` cookie authenticates the same way.
- Runtime settings come from the host's environment: `VITE_MAP_TILER_KEY` (the draw and
  preview maps; without it MapLibre's demo tiles are used), `GEONAMES_USERNAME` (the
  administrative-unit picker and GeoNames imports), `OG_ATLAS_URL_TEMPLATE` (the "view
  your atlas" link).
- The build is committed (`public/wizard/`) so the host needs no Node step. To change the
  wizard: `cd client && npm install && npm run build`, then commit `public/wizard/` with
  the source. `npm run dev` serves it at http://localhost:5175 proxying `/core_data` to a
  host on :3001.

## Getting places in: upload a dataset, or a gazetteer

The wizard's "Add places" step and each atlas's Imports page offer two sources.

**Upload your data** (`DatasetImportsController`, `ImportDatasetJob`,
`app/services/core_data_connector/dataset_imports/`). A CSV (comma, semicolon or tab; any
common encoding), an Excel (.xlsx) or OpenDocument (.ods) workbook (first sheet), a GeoJSON
file, or a zipped shapefile (.shp + .dbf, with .prj/.cpg when present; longitude/latitude
only — projected files are refused with re-export steps), up to 50 MB / 50,000 rows.
Workbooks use roo and shapefiles rubyzip, both already in core-data-cloud's bundle; the
shapefile reader needs no GIS library. The preview proposes a role per
column (place name, field, category, latitude, longitude, geometry, identifier, skip) and a
field type, shows the rows on a map, and lists rows whose location can't be used (e.g. a
projected CRS). The place-name suggestion is scored (a name-like header, filled, nearly unique,
not dates/links/ids), so `RESNAME` beats a first column of dates. Columns that carry nothing a
visitor would read start as *Don't import* with the reason shown — the same value in every
row, GUIDs, GIS bookkeeping (`Shape_Length`, created/edited stamps), millisecond timestamps —
and "Skip all fields" clears the rest of a wide export so the curator turns on only what they
want. Numbers with leading zeros are offered as text. Dates as historical data has them — a
year, a month (`1983-03`, NPS's `1983-03-`), a decade, a range, *circa* — are offered as a
partial date (Core Data's fuzzy date, shown as "1911" or "March 1983", never with an invented
day); *Exact date* takes only full YYYY-MM-DD. A column of marks and blanks ("X" on 7 rows)
reads as Yes/No. For each type a column could take, the preview counts the values it couldn't
read, and the console warns under the column before anything is left empty
(`DatasetImports::Values` does the reading for both preview and import). Nothing is written
until the curator presses Import. Then:

- each row becomes a Place with its name, geometry and typed field values;
- missing fields are created on the Places model; a column matching an existing field
  (e.g. "Short Description") fills it, so canonical promotions still apply;
- rows without coordinates can be placed from their address: the preview's "Find locations
  from addresses" uses the chosen columns (or a city/state typed once) with the U.S. Census
  Bureau's batch geocoder (`DatasetImports::Geocoder`; free, no key, U.S. only;
  `OG_GEOCODER=none` turns it off), shows what was found on the preview map (orange), lists the
  approximate matches to check and the rows not placed (descriptions, intersections, a match in
  another town), and the import looks every row up the same way (`located_from_address`,
  `address_not_found` in the job counts). A name that is an address ("621 Ruben Street
  (House)") stands in for an empty street column. Places still without a location are listed
  but not mapped, and the preview says how many before import;
- a **Photo** column (image addresses; suggested from its header or from links to image files)
  is stored as a field and named the places' photo (`detail_pages.models.places.photo_field`,
  hidden from the field list): the renderer shows it on the detail page and in the map panel
  when the place has no media of its own. Columns of links are never added to the search;
- a category column becomes Types terms on the canonical Places→Types relationship
  (created as the template defines it if the project lacks one) — the atlas's `types` facet;
  values written all in lower case (`building`) are proposed title-cased (`Building`,
  `Church of God`), which the curator can turn off per column; mixed-case values stay as
  written. Terms match case-insensitively, so a later upload reuses them;
- short, repetitive text columns default to pick-list (Select) fields, which the index
  turns into `*_facet` keywords;
- with an identifier column, importing again skips rows whose id is already in the atlas;
  rows of one file that share an id (one listing covering several buildings) are all
  imported, and the preview warns that the column repeats;
- afterwards the project's atlases get the category and pick-list fields as filters, their
  text fields added to what the search box looks in, and the identifier hidden on public
  pages (only ever added, never removed);
- the import panel then follows the reindex and says when the atlas is live — or, in the
  curator's terms, why the shared index refused it.

Each search's "Also search in" (Settings → Search; `search_fields`, from
`GET /core_data/sites/:id/search_fields`) lists text fields by where the index holds them —
a promoted field under its key (`address`), any other as `<label>.value` — and is emitted to
the renderer as `elasticsearch.search_attributes` after the name and descriptions.

Older .xls, a bare .shp and KML are refused with instructions. Fixtures for each reader,
written with independent tools (openpyxl, odfpy, GDAL), are in `test/fixtures/datasets/`.

**From a gazetteer**: GeoNames and Wikidata imports for the atlas's area (`PlaceImportsController`,
`ImportPlacesJob`), idempotent by authority identifier.

Both suspend per-record indexing and queue one scoped reindex. Reindexes of one project run
one at a time (advisory lock in `ReindexAtlasJob`).

## Places without a location

A place imported without coordinates (a description such as "Cockspur Island", an
intersection, an address the lookup couldn't place) is listed and searchable on the atlas
but not on its map. The atlas's **Places** page (`/atlases/:id/places`) puts them there:

- **One by one:** pick a place from the list, then click the map where it is (or search for
  it by name with MapTiler, limited to the atlas's area first) and drag the marker to
  adjust. The map is framed to the places already located.
- **All at once:** look their addresses up with the Census geocoder (street from one of
  their fields, city/state/ZIP from a field or typed), prefilled from the last upload's
  address lookup. Exact matches are ticked; matches near the address are listed for
  review; nothing is saved until "Save N locations".
- `GET /core_data/sites/:id/unlocated_places`, `POST …/unlocated_places/lookup`,
  `POST …/unlocated_places/locate` (owner only; only the atlas's own places, only those still
  without a location). Saved places are reindexed in the background (`ReindexRecordsJob`,
  under the same per-project lock as a full reindex): indexing a newly located place looks
  its administrative area up on GeoNames, about one a second.
- An upload now records a city/state/ZIP column that held one value throughout but wasn't
  kept as a field (HABS's City), so the lookup can be prefilled later.

The same page's **Categories** tab lists every category value of the atlas's places (each
taxonomy its place models relate to: Types, and others such as Denomination) with how many
places use it, and renames them in place (`GET /core_data/sites/:id/categories`,
`PATCH …/categories/:term_id { name }`). Renaming to a name another value has (any letter
case) merges the two: every link moves to the existing value, which takes the typed
spelling, and the renamed value is deleted (its search document with it). The affected
places and the value are reindexed in the background.

## An atlas is a site: home page, pages, branding

Each atlas has its own home page and any number of standalone pages (About, Credits, …),
edited in the console and served by the shared renderer. They live on the site as
`content` (`CoreDataConnector::SiteContent`):

```
{ home:  { description, sections: [...] },
  pages: [{ slug, title, description, sections: [...] }, ...] }
```

A section is a **banner** (`hero`: title, subtitle, background image, search box, button),
**text** (Markdown), **text and image**, or a **call to action**. Text is stored as the
curator wrote it; the renderer converts and sanitizes it. The server holds every link and
image source to a site path, http(s) or mailto (never `javascript:`/`data:`), and branding
colors, sizes and fonts to their formats, since they end up in the renderer's CSS.

- A new atlas starts with a home page: a banner with its description, a search box and a
  button into the map. Atlases without one get the same page by default.
- The navigation can point at a page (`{ _template: 'Page', page: 'about' }`); the public
  bundle turns it into a link labelled with the page's title. With no navigation saved it is
  Explore plus every page.
- Images (logo, favicon, page images) are uploaded to the site
  (`POST /core_data/sites/:id/assets`, multipart `file`; `GET` lists, `DELETE …/assets/:key`
  removes): PNG, JPEG, GIF, WebP, AVIF, SVG or ICO, read from the file's contents, up to
  10 MB. They are ActiveStorage attachments (S3 in production) served publicly at
  `/core_data/public/v1/assets/:key/:filename`, immutable, with a sandboxing CSP so an
  SVG can't run script. Only site assets are served there, never a job's or an upload's
  file. It's our route, not ActiveStorage's: on core-data-cloud the SPA catch-all is drawn
  ahead of ActiveStorage's routes, so `rails_blob_url` answers with the console's HTML.
- Uploaded JPEG, PNG, WebP and AVIF images get web-sized copies at upload
  (`SiteImages`): 160–2000 px wide, never wider than the original, upright, sRGB, no
  metadata; JPEG when opaque, WebP with transparency. They're attached as
  `Site#asset_variants` (not listed in the image library), served by the same route, and
  listed by the public bundle's `images` (original key → size and copies), which the
  renderer turns into `srcset`/`sizes` and single URLs for the logo, favicon and share
  image. Truncated files and images over 100 megapixels are refused. Needs libvips (already
  in FairData's Dockerfile) through `ruby-vips`; without it images are served as uploaded.
  `bin/rails open_geographies:image_copies [SITE=id]` makes copies for earlier uploads.
- `GET /core_data/public/v1/atlases/:slug` carries `content` and `images` next to `config`,
  `branding` and `navigation`; `config` (which the browser also fetches) never holds the
  pages.

## Drafts and preview links

An atlas is private until its curator publishes it (`sites.published`; atlases that existed
before this was added were published by the migration). The wizard creates drafts.

- `GET /core_data/public/v1/atlases/:slug` answers 404 for a draft, unless the request
  carries the site's `preview_token` in an `X-OG-Preview` header. Then it serves the bundle
  marked `preview: true` with `Cache-Control: private, no-store`. A wrong token looks
  exactly like an unknown slug.
- The console's Settings → General → Visibility shows the draft's preview link
  (`<atlas address>/?preview=<token>`) with Copy and Open, publishes and unpublishes at once
  (separately from Save), and replaces the link (`POST /core_data/sites/:id/preview_token`;
  old links stop working). Atlas pages show a Draft/Published label.
- The renderer turns `?preview=<token>` into an HttpOnly cookie and redirects to the same
  address without it, then forwards the token with every bundle lookup. Preview responses
  are `no-store` and `noindex`, show a "Preview" notice, and are cached apart from the
  public bundle. An address with no published atlas (unknown, or a draft without the
  link) gets a 404 page instead of an empty atlas.
- The project stays `discoverable` either way (the renderer's detail pages read its
  records through FairData's public API), so a draft's records are reachable there by
  anyone who knows the project's ids, as before; it's the atlas that's private.

## Owners and editors

An atlas's people are its FairData project's members, added on the project's Users page
(`/projects/:id/user_projects`; the atlas header's **People →** links there, for owners).

- **Editors** do the content work: settings, home page and pages, menu, branding, images,
  map layers, search, detail pages, places without a location, category values, dataset and
  gazetteer imports, reindexing (`SitePolicy#update?`, `AtlasProjectPolicy#import?`,
  `SearchCollectionPolicy#reindex?`: any member of the project).
- **Owners** also decide where and whether the atlas is public: publish/unpublish, the slug,
  its own domain, replacing the preview link (`SitePolicy#manage?`), and deleting it
  (`#destroy?`). A general update that would change `published` or `slug` needs `manage?`;
  sending them unchanged (the console saves the slug with everything else) doesn't.
- The site JSON carries `permissions: { edit, manage, delete }` for the signed-in user; the
  console hides what the user can't do and says who can.
- Accounts made by inviting someone are FairData "guests": they work on the projects they
  were added to but can't create projects, so the console hides "Create an atlas" for them.

## Images

Settings → Images lists the atlas's uploaded images (the same `GET /core_data/sites/:id/assets`
the pickers use) with where each is used: logo, favicon, link preview image, footer, home
page, each page (Markdown included), other settings. "Used" covers both the saved atlas and
unsaved edits, so an image that's about to be used, or is still on the live atlas, isn't
counted as unused. Unused images can be deleted one by one or all at once
(`DELETE /core_data/sites/:id/assets/:key`, copies included); deleting a used one says
which places will show no image.

## An atlas's own domain

Every atlas has a platform address, `<slug>.<base domain>` (`OG_ATLAS_URL_TEMPLATE`, e.g.
`https://{slug}.atlas.example.edu`). It can also have a domain of its own
(`sites.domain`, `CoreDataConnector::SiteDomains`), set in Settings → General → Address.

- **Connected only through DNS.** The domain is stored as entered (no scheme, path, port or
  trailing dot; lower case) but served only once its DNS names this atlas: a CNAME to the
  platform address (for a subdomain such as `atlas.example.org`), or a TXT record
  `_open-geographies.<domain>` whose value is the slug (for a root domain, which also needs
  A/ALIAS records to the renderer). The server checks when the domain is set and on
  "Check DNS" (`PUT /core_data/sites/:id/domain`, `POST /core_data/sites/:id/domain/check`;
  3 s timeout); `sites.domain_verified_at` records the result. The general update can't set
  a domain or mark it connected.
- So a curator can't claim someone else's domain by typing it in, and the platform address
  never redirects to a domain whose DNS isn't ready. Several atlases may enter the same
  domain; only one is connected (unique partial index), the one the DNS names — it moves
  when the DNS moves. A new slug or a new domain disconnects until checked again.
- Refused outright: IP addresses, single names, malformed names, the base domain and
  `<x>.<base>` (atlas addresses), the console's own host. Development servers also accept
  names like `atlas.test.localhost` (three labels or more), connected without DNS, first
  come first served; production refuses `.localhost`.
- `GET /core_data/public/v1/atlases/by_domain?domain=` serves the same bundle as the
  by-slug endpoint (same discoverable/draft/preview rules) for a connected domain; both
  carry `domain` (connected only), which the renderer uses to send the platform address
  there. Console links (`public_url` in the site JSON, "View atlas", preview links) follow
  the domain.
- `GET /core_data/public/v1/domains/allowed?domain=` answers 200 for a connected domain or
  an existing atlas's platform address, else 404: the shape of Caddy's on-demand TLS
  `ask`, so the proxy in front of the renderer can get a certificate per domain on first
  visit and never for a name nobody connected.
- DNS is re-checked when the curator asks, or by `bin/rails open_geographies:check_domains`
  (every domain; prints what changed) — run it from cron so a domain whose DNS moved away
  is disconnected, and one whose DNS arrived late is connected. Not done: `www` ↔ root
  pairing.

## Upstream-PR posture

A few decorators carry changes that are **general improvements** to Core Data, not
Open Geographies specifics — the public-API `discoverable` gate, the orphaned-
relationship index crash-guard, GeometryCollection flattening, and an index progress
callback. These are offered upstream as separate PRs (see `UPSTREAM_PRS.md` in the
parent project) and are written to be **deleted from this engine** if/when they land
in an upstream release we depend on. The engine carries them meanwhile so the platform
is correct (and secure) regardless of upstream timing.
