#!/bin/bash
# Host container: `web` (default) prepares the database, makes sure of the
# first administrator, and serves; `worker` runs the background jobs
# (imports, reindexes, photo copies, tile builds).
set -e
cd /app

# Waits for a command to succeed, saying what it's waiting for every 30 s.
wait_for() {
  local what=$1 tries=0
  shift
  until "$@" > /dev/null 2>&1; do
    tries=$((tries + 1))
    if [ $((tries % 15)) -eq 0 ]; then
      echo "[install] still waiting for ${what}"
    fi
    sleep 2
  done
}

wait_for "the database (check POSTGRES_PASSWORD: letters and digits only)" pg_isready -d "$DATABASE_URL"
wait_for "Elasticsearch" curl -fs "$ELASTICSEARCH_HOST/_cluster/health"

case "${1:-web}" in
  web)
    rm -f tmp/pids/server.pid
    bundle exec bin/rails db:prepare
    bundle exec bin/rails runner 'load "/install/engine_migrations.rb"; load "/install/first_admin.rb"'
    exec bundle exec puma -C config/puma.rb -b tcp://0.0.0.0:3000
    ;;
  worker)
    # The console answers only once the database is migrated (the host's
    # migrations and the engines'), so the jobs never run on an old schema.
    wait_for "the console to finish migrating" curl -fs http://host:3000/health
    exec bundle exec sidekiq -C config/sidekiq.yml
    ;;
  *)
    exec "$@"
    ;;
esac
