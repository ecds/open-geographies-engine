# The FairData host (ecds/core-data-cloud, branch `ecds`) with the Open
# Geographies engine mounted — the same shape as the future integration PR,
# applied here as patches so the demo needs nothing pushed to the host repo.
#
# Build context is the engine repo root (see ../docker-compose.yml): the
# engine is copied in at /open-geographies-engine, where the host's Gemfile
# (`path: '../open-geographies-engine'`, relative to /app) expects it.
#
# Mirrors Dockerfile-ecds in the host repo: Ruby 4.0.5, Node 20 + yarn for
# the FairData console build. The engine's own console (wizard, atlas pages)
# ships as a committed bundle (public/wizard/), so nothing here builds it.
FROM ruby:4.0.5

RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends postgresql-client git libvips curl libgeos-dev \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install --global yarn \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG CORE_DATA_CLOUD_REPO=https://github.com/ecds/core-data-cloud.git
# The `ecds` branch commit the mount patches apply to.
ARG CORE_DATA_CLOUD_REF=d5ddd0393a5e359516a8db312d5c06ec674b2976

RUN git clone --filter=blob:none "$CORE_DATA_CLOUD_REPO" /app \
  && git -C /app checkout --detach "$CORE_DATA_CLOUD_REF"

WORKDIR /app

COPY demo/host/patches /tmp/patches
RUN git apply --index /tmp/patches/*.patch && rm -rf /tmp/patches

COPY . /open-geographies-engine

RUN bundle install --jobs 4

# The FairData console (React/Vite) — login, projects, data entry. Set
# BUILD_CONSOLE=0 to skip it (the engine pages have their own sign-in and
# work without it; the host root will 404).
ARG BUILD_CONSOLE=1
ARG VITE_MAP_TILER_KEY
ENV VITE_MAP_TILER_KEY=$VITE_MAP_TILER_KEY
ENV DISABLE_ESLINT_PLUGIN=true
ENV GENERATE_SOURCEMAP=false
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN if [ "$BUILD_CONSOLE" = "1" ]; then \
      yarn config set network-timeout 600000 -g && yarn build && yarn deploy && rm -rf client/node_modules; \
    fi

# Demo-only: let the renderer container reach us by service name (Rails
# development host authorization allows only localhost by default).
COPY demo/host/hosts.rb /app/config/initializers/zz_demo_hosts.rb
COPY demo/host/seed.rb /demo/seed.rb
COPY demo/host/entrypoint.sh /demo/entrypoint.sh
RUN chmod +x /demo/entrypoint.sh

ENV RAILS_ENV=development
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_SERVE_STATIC_FILES=true
ENV AUTHENTICATION_EXPIRATION=730

EXPOSE 3000

ENTRYPOINT ["/demo/entrypoint.sh"]
