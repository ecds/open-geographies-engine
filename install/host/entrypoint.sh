#!/bin/bash
# Host container: `web` (default) prepares the database, makes sure of the
# first administrator, and serves; `worker` runs the background jobs
# (imports, reindexes, photo copies, tile builds).
set -e
cd /app

wait_for() {
  until "$@" > /dev/null 2>&1; do sleep 2; done
}

wait_for pg_isready -d "$DATABASE_URL"
wait_for curl -fs "$ELASTICSEARCH_HOST/_cluster/health"

case "${1:-web}" in
  web)
    rm -f tmp/pids/server.pid
    bundle exec bin/rails db:prepare
    bundle exec bin/rails runner 'load "/install/engine_migrations.rb"; load "/install/first_admin.rb"'
    exec bundle exec puma -C config/puma.rb -b tcp://0.0.0.0:3000
    ;;
  worker)
    # The web container migrates; wait until it has.
    until bundle exec bin/rails runner 'exit(ActiveRecord::Base.connection.pool.migration_context.needs_migration? ? 1 : 0)' > /dev/null 2>&1; do
      sleep 5
    done
    exec bundle exec sidekiq -C config/sidekiq.yml
    ;;
  *)
    exec "$@"
    ;;
esac
