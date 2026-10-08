# syntax=docker/dockerfile:1
# The FairData host (ecds/core-data-cloud) with the Open Geographies engines,
# in production mode, for the self-hosted install (../docker-compose.yml).
#
# Built like the host's own Dockerfile-ecds (Ruby 4.0.5, Node 20 + yarn for
# the FairData console), from the host repository at HOST_REF: the branch that
# mounts this engine (`og/platform-engine` until it's merged into `ecds`).
# ENGINE_REF, if set, points the bundle at another commit of
# ecds/open-geographies-engine than the one the host pins.
FROM ruby:4.0.5

RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends postgresql-client git libvips curl libgeos-dev \
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install --global yarn \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# ADD (not `git clone`) so each build checks the branch for new commits: a
# RUN layer would stay cached and never see them.
ARG HOST_REPO=https://github.com/ecds/core-data-cloud.git
ARG HOST_REF=og/platform-engine
ADD ${HOST_REPO}#${HOST_REF} /app

WORKDIR /app

# The FairData console (React/Vite): sign-in, projects, data entry. The
# engine's own console (atlases, wizard) ships prebuilt inside the gem. Built
# before the bundle, so a new ENGINE_REF doesn't rebuild it.
ARG VITE_MAP_TILER_KEY=
ENV VITE_MAP_TILER_KEY=$VITE_MAP_TILER_KEY \
    VITE_IIIF_MANIFEST_ITEM_LIMIT=1000 \
    DISABLE_ESLINT_PLUGIN=true \
    GENERATE_SOURCEMAP=false \
    NODE_OPTIONS="--max-old-space-size=4096"
RUN yarn config set network-timeout 600000 -g && yarn build && yarn deploy \
  && rm -rf client/node_modules && yarn cache clean

ARG ENGINE_REF=
RUN if [ -n "$ENGINE_REF" ]; then \
      sed -i -E "s|(gem 'open_geographies_platform', git: '[^']+', )ref: '[^']+'|\\1ref: '${ENGINE_REF}'|" Gemfile \
      && grep -q "ref: '${ENGINE_REF}'" Gemfile; \
    fi \
  && bundle config set --local without 'development test' \
  && bundle install --jobs 4

COPY self_host.rb /app/config/initializers/zz_self_host.rb
COPY engine_migrations.rb first_admin.rb entrypoint.sh /install/
RUN chmod +x /install/entrypoint.sh

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true \
    RAILS_MAX_THREADS=5 \
    AUTHENTICATION_EXPIRATION=730

EXPOSE 3000
ENTRYPOINT ["/install/entrypoint.sh"]
CMD ["web"]
