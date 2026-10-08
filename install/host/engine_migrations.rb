# frozen_string_literal: true

# The engines' own migrations, run in place from each gem under their own
# version numbers: all of the indexing engine's (open_geographies_fairdata; the
# host's db/migrate has none of them) and any of ours newer than the host's
# copies. Copying them in at build time (railties:install:migrations) would
# stamp them with the build's time, so the next rebuild would copy them again
# under new numbers and try to create tables that already exist.
#
# A migration the host already carries (by name, as that task compares) is
# left to the host. Runs after db:prepare on every start; a no-op once applied.
pool = ActiveRecord::Base.connection_pool
host = pool.migration_context.migrations.map(&:name)

[OpenGeographies::Engine, OpenGeographiesPlatform::Engine].each do |engine|
  paths = engine.paths['db/migrate'].existent
  next if paths.empty?

  migrations = ActiveRecord::MigrationContext.new(paths, pool.schema_migration, pool.internal_metadata)
                                             .migrations.reject { |m| host.include?(m.name) }
  next if migrations.empty?

  ActiveRecord::Migrator.new(:up, migrations, pool.schema_migration, pool.internal_metadata).migrate
end
