# The shared dynamic renderer (ecds/core-data-places), built with Astro's
# standalone Node adapter. One server renders every atlas: the site is picked
# per request from the Host header (`<slug>.localhost:4321`) or OG_SITE_SLUG,
# and its config comes from the host's public by-slug endpoint at runtime —
# nothing atlas-specific is baked in.
FROM node:24-bookworm-slim AS build

RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG RENDERER_REPO=https://github.com/ecds/core-data-places.git
ARG RENDERER_REF=main

RUN git clone --filter=blob:none "$RENDERER_REPO" /renderer \
  && git -C /renderer checkout --detach "$RENDERER_REF"

WORKDIR /renderer

# The dependency tree is large; a throttled fetch is what survives Docker
# Desktop's networking under load.
RUN npm ci --maxsockets=4 --fetch-timeout=600000 --fetch-retries=5 --fetch-retry-maxtimeout=120000

# Not `npm run build`: that is the static-site pipeline (one atlas's config,
# descriptors and content repo fetched at build time). build:server writes
# the empty label defaults and builds with the Node adapter.
RUN npm run build:server && npm prune --omit=dev

FROM node:24-bookworm-slim

WORKDIR /renderer
COPY --from=build /renderer/dist ./dist
COPY --from=build /renderer/node_modules ./node_modules
COPY --from=build /renderer/package.json ./package.json

ENV HOST=0.0.0.0
ENV PORT=4321
EXPOSE 4321

CMD ["node", "dist/server/entry.mjs"]
