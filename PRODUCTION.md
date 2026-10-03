# Open Geographies: production readiness checklist

For ECDS ops. What has to be true before the first production atlas goes public. It covers
the two parts Open Geographies adds to FairData: the platform engine (`open_geographies_platform`,
mounted in the FairData host) and the shared renderer (`ecds/core-data-places`, one Node
server for every atlas). The indexing engine (`open_geographies_fairdata`) and FairData itself are referenced only
where they meet these. Today's reference deployment is the demo stack in [`demo/`](demo/)
(Docker Compose, development mode).

## 1. Renderer

- [ ] **Build and run with compression.** `npm run build:server`, then `npm run serve`
  (`scripts/serve.mjs`, Node 24). It serves the build's Brotli/gzip copies of `/_astro/*`
  (10 MB → 2.3 MB). Astro's own entry point (`dist/server/entry.mjs`) sends everything
  uncompressed. The demo's `demo/renderer/Dockerfile` does this.
- [ ] **Environment**

  | Variable | Value |
  |---|---|
  | `HOST`, `PORT` | `0.0.0.0`, `4321` |
  | `OG_CONSOLE_URL` | The FairData host, as the renderer reaches it. With the host's `PRIMARY_DOMAIN` set, use exactly that domain; any other name gets a 301. |
  | `OG_CORE_DATA_INTERNAL_URL` | Only if the browser-facing Core Data URL doesn't resolve from the renderer (e.g. a container network). |
  | `OG_BASE_DOMAIN` | **Required.** The domain atlases live under (`atlas.example.edu` → `<slug>.atlas.example.edu`). Without it, every atlas address 404s. |
  | `OG_ELASTICSEARCH_URL`, `OG_ELASTICSEARCH_API_KEY` | The search index. The renderer only searches, so give it a **read-only** API key limited to `open_geographies_v1` (and `open_geographies_v1_project_*` once each atlas has its own index, §8). |
  | `OG_SITE_SLUG` | **Unset** (it pins one atlas). |
  | `OG_TRUST_ATLAS_SLUG_HEADER` | **Unset**, unless a proxy sets `X-Atlas-Slug` itself and strips the client's. |
  | Optional | `OG_ATLAS_CACHE_TTL_MS` (30 s), `OG_ATLAS_ERROR_TTL_MS` (5 s), `OG_ATLAS_FETCH_TIMEOUT_MS` (5 s), `OG_ATLAS_CACHE_MAX_ENTRIES` (1,000), `OG_WORDPRESS_TIMEOUT_MS`. |
- [ ] **Health check**: `GET /health` on the renderer. It never depends on the console or
  Elasticsearch, so a console outage doesn't take the renderer out of the load balancer.
  The FairData host has `GET /health` (Rails).

## 2. Host (the platform engine's part)

- [ ] `OG_ATLAS_URL_TEMPLATE=https://{slug}.<OG_BASE_DOMAIN>`, matching the renderer's base
  domain. The console's links, preview links and custom-domain checks all derive from it.
- [ ] `CORE_DATA_PUBLIC_URL` (the browser-facing console URL), `VITE_MAP_TILER_KEY` (console
  maps), `GEONAMES_USERNAME` (see 7), `ELASTICSEARCH_HOST` + `ELASTICSEARCH_API_KEY` (write
  access to the index), `IIIF_CLOUD_URL` + `IIIF_CLOUD_API_KEY` + `IIIF_CLOUD_PROJECT_ID`
  (photo copies). `OG_GEOCODER=none` turns off US Census address lookups (on by default).
- [ ] **Migrations**: the host doesn't copy engine migrations on its own. Run
  `bin/rails railties:install:migrations FROM=open_geographies_platform` (and the
  indexing engine's, `FROM=open_geographies`), then `db:migrate`.
- [ ] **libvips** in the image (the host's `Dockerfile-ecds` already installs it) for upload
  copies and TIFF conversion. The `ruby-vips` gem comes in with the engine.
- [ ] **Sidekiq + Redis running.** Imports, reindexes, photo copies and tile builds are jobs.
  A stopped worker looks like an import that never finishes.
- [ ] **Request body limit at the proxy** in front of the host: at least **100 MB** for
  `/core_data/sites/*/assets` (TIFF scans) and **50 MB** for dataset uploads. nginx's
  default is 1 MB.
- [ ] **Outbound network from the host**: DNS (custom-domain checks use the system
  resolver), `api.geonames.org`, `geocoding.geo.census.gov`, IIIF Cloud, and any public
  web address a curator's photo links point at. Photo downloads refuse private and loopback
  addresses.
- [ ] **Cron**: `bin/rails open_geographies:check_domains` hourly. It re-checks custom-domain
  DNS, connecting late arrivals and disconnecting domains whose DNS moved away.
- [ ] **Curator feedback** ("Send feedback" in the console) is always kept in the host's
  database and listed for FairData administrators at `/atlases/feedback`. To have each report
  emailed as well, set `OG_FEEDBACK_EMAIL` (comma-separated addresses). Mail goes through the
  host's own delivery (Postmark: `POSTMARK_API_TOKEN`), from `OG_FEEDBACK_FROM` or else
  `POSTMARK_FROM`, which must be a Postmark sender signature; replies go to the curator. A
  delivery that fails is retried twice, then shown on the report as "Email failed" (the report
  itself is never lost). Screenshots (PNG/JPEG/WebP, 10 MB) are stored with the host's other
  uploads and served only to their sender and admins.

## 3. Proxy, CDN and caching

- [ ] **Pass the original `Host` to the renderer.** It picks the atlas from Host. Caddy does
  this by default; nginx needs `proxy_set_header Host $host;`.
- [ ] **Overwrite `X-Forwarded-Proto` and `X-Forwarded-Host`** with the proxy's own values;
  never pass the client's. Sitemaps, robots.txt and the custom-domain redirect use them,
  and some of those responses are cacheable.
- [ ] **CDN cache key includes Host** (one renderer serves every atlas at the same paths).
- [ ] **Bypass the CDN cache when the `og_preview` cookie is present.** Preview responses
  are already `private, no-store`, so they're never stored. Bypassing just keeps a preview
  visitor from being handed a cached public page.
- [ ] What the renderer sends, so CDN rules can follow it:
  - `/_astro/*`: `public, max-age=31536000, immutable`. Cache hard.
  - Pages: `public, max-age=0, must-revalidate` (the `Netlify-CDN-Cache-Control` header
    only applies on Netlify).
  - `robots.txt`: 1 hour. `sitemap.xml`: 5 minutes to 1 hour.
  - Platform address → custom domain redirect: `301`, 1 hour.
  - `/config.json`, `/api/search.json`, previews, 404s: `no-store`.
  - After **unpublishing** an atlas, purge its host from the CDN, or cached pages outlive it.
- [ ] **Atlas images**: the console serves uploaded images at
  `/core_data/public/v1/assets/<key>/<file>` (immutable, ETag) by reading them from S3 on
  each request. Put a CDN in front of that path on the console host.

## 4. TLS

- [ ] **Wildcard certificate for `*.<OG_BASE_DOMAIN>`**, either Emory's or ACME with a
  DNS-01 challenge (Let's Encrypt only issues wildcards via DNS-01).
- [ ] **Custom domains**: a certificate per domain, issued on first visit. With Caddy:
  on-demand TLS, allowed only for names the console vouches for:

  ```
  {
    on_demand_tls {
      ask https://<console host>/core_data/public/v1/domains/allowed
    }
  }
  *.atlas.example.edu {
    tls { dns <provider> … }          # wildcard via DNS-01
    reverse_proxy renderer:4321
  }
  https:// {
    tls { on_demand }                 # atlases' own domains
    reverse_proxy renderer:4321
  }
  ```

  The `allowed` endpoint answers 200 only for a connected custom domain or an existing
  atlas's platform address, so nobody can make the proxy request certificates for
  arbitrary names. Without on-demand TLS, ops add each domain's certificate by hand when a
  curator connects one.
- [ ] **Tell curators where root domains point**: a root domain (`example.org`) can't use a
  CNAME and needs A/ALIAS records to the renderer's address. The console tells the curator
  to ask for it.

## 5. Backups

- [ ] **Postgres**: everything that defines an atlas: projects and records, sites (pages,
  branding, domains, preview tokens), search collections, jobs, and the GeoNames cache
  (`open_geographies_geonames_hierarchies`). Daily dumps plus point-in-time recovery.
- [ ] **ActiveStorage bucket** (`AWS_BUCKET_NAME`, production service `amazon`): atlas
  images and their web-sized copies, uploaded dataset files kept with their import jobs.
  Turn on bucket versioning.
- [ ] **Elasticsearch**: rebuildable from Postgres by reindexing, but slowly (HRCGA, 6.4k
  records: 17 min with the indexing engine at `67d0728`). A snapshot repository (S3) avoids that. The
  GeoNames cache lives in Postgres, so a rebuild doesn't spend GeoNames credits again.
- [ ] **IIIF Cloud** holds the copied photos; its backups are its own. Each place's Photo
  field keeps the source address as provenance.

## 6. Monitoring

- [ ] Uptime on both `/health` endpoints.
- [ ] **Error monitoring** for the host and the renderer. Neither has one today; the host's
  Gemfile has no Sentry or equivalent.
- [ ] Renderer logs `[atlas] console returned <status>` / `[atlas] failed to resolve`: the
  console is unreachable. Atlases the renderer has already loaded keep their last good
  config; others (and every atlas after a renderer restart) render empty until it's back.
- [ ] **Sidekiq failed and dead jobs**, especially reindex jobs (see 8). Curators also see
  each atlas's jobs in the console.
- [ ] Someone reads **curator feedback** (`/atlases/feedback`, or the `OG_FEEDBACK_EMAIL`
  inbox) and marks it resolved.
- [ ] **Elasticsearch disk**: past the flood-stage watermark (95%), ES makes the index
  read-only and every reindex fails (this happened on the demo machine). Alert at 85%.
- [ ] Field count of `open_geographies_v1` against its limit (see 8).
- [ ] Certificate expiry, if not automated.

## 7. GeoNames credits

- [ ] The account the local and demo setups use is a **free one: 1,000 credits an hour,
  20,000 a day**. Each newly located place costs a lookup at index time, cached per place
  afterwards. A large import exhausts the hour, and the remaining places index **with an
  empty administrative area, silently**; a reindex after the hour fills them in.
- [ ] Before production: an ECDS-owned account, premium if atlases of thousands of places
  are expected. Schedule big imports with the hourly limit in mind.

## 8. The shared index: field limit and type collisions

An open item with the indexing engine (the index-mapping proposal of 2026-09-30).

- [ ] Every atlas indexes into one Elasticsearch index, `open_geographies_v1`, and each new
  field label adds dynamic fields. Measured: canonical mapping 150 fields; HRCGA +350; an
  uploaded atlas +20–30. **At Elasticsearch's default limit of 1,000, the next atlas's
  reindex fails entirely.**
- [ ] A field label's type is fixed by the first atlas that uses it. Another atlas with the
  same label and a different type (text vs. date) fails its whole reindex. Reproduced three
  times locally.
- [ ] Until the index changes land: raise the limit at creation
  (`PUT open_geographies_v1/_settings {"index.mapping.total_fields.limit": 3000}`; the local
  copy runs with 3,000), watch the field count, and treat a failed reindex mentioning
  "Limit of total fields" or `mapper_parsing_exception` as this. The fix itself (one index
  per atlas, or mapping changes) belongs to the indexing engine.
- [ ] One index per atlas is proposed to the indexing engine (`OpenGeographies::V1::Indexes`,
  switched by `OG_INDEX_LAYOUT=shared|both|per_project`, with `og_indexes:build`, `report` and
  `drop_shared` for the move). This engine is ready for it: when the indexing engine provides
  it, each atlas's config names its own index and the console's Reindex rebuilds that index
  with no downtime. Without it, or with `shared`, nothing changes. With it, keep
  Elasticsearch from creating a project index by itself:
  `action.auto_create_index: "-open_geographies_v1_project_*,+*"`.
- [ ] **Dated searches need runtime fields.** A search with dates (Settings → Search → Time)
  computes each record's years at search time with a fixed Painless script over `_source`. The
  cluster must allow it: `search.allow_expensive_queries` true (the default; with it false the
  year filter fails while everything else works) and inline scripts in the runtime-field
  contexts (the default; a cluster restricted to stored scripts fails every dated search). Cost,
  measured on HRCGA's 444 churches through the renderer: about 100 ms per dated search against
  15–30 ms undated, growing with the atlas's size. The renderer caps a request at 20 searches of
  at most 250 results, each with a 10 s Elasticsearch timeout.

## 9. Before the first atlas goes public

- [ ] Run `bin/rails open_geographies:tenancy_probe HOST=<host>` against staging. It creates
  and removes its own two test tenants and expects every check to pass.
- [ ] The host probe passes against the deployed host
  (`bin/rails open_geographies:host_tenancy_probe HOST=<host>`): FairData's own admin API
  keeps each project's records and models to its owners.
- [ ] FairData's navigation links to `/atlases`.
- [ ] Publish the atlas from the console (atlases start as drafts), open it at its address,
  and check `/robots.txt` and `/sitemap.xml` there.
