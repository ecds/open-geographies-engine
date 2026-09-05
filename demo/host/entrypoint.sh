#!/bin/bash
# Host container: prepare the database, start the server, then seed in the
# background so the console is reachable while the HRCGA import runs.
set -e

cd /app
rm -f tmp/pids/server.pid

until pg_isready -h "$DATABASE_HOST" -p "${DATABASE_PORT:-5432}" -U "$DATABASE_USERNAME" -q; do
  echo "[demo] waiting for postgres…"
  sleep 2
done

until curl -fs "$ELASTICSEARCH_HOST/_cluster/health" > /dev/null; do
  echo "[demo] waiting for elasticsearch…"
  sleep 3
done

# Creates the database on first run (and loads the host's own seeds), migrates
# on every run — the engine's two additive migrations included.
bundle exec bin/rails db:prepare

(
  # Give puma a moment to bind before the seed's log interleaves with its own.
  sleep 5
  bundle exec bin/rails runner /demo/seed.rb 2>&1 | sed -u 's/^/[seed] /'
) &

exec bundle exec puma -C config/puma.rb -b tcp://0.0.0.0:3000
