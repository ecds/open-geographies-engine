# Open Geographies — a Rails engine that extends Performant Software's Core Data
# (now FairData) with the multi-tenant, no-code geospatial publishing layer:
# Sites, atlas provisioning, authority bulk imports, and the by-slug public atlas API.
#
# It is deliberately additive: it mounts onto an UNMODIFIED host. Its migrations only
# CREATE new tables; its modifications to upstream classes are applied as decorators at
# boot (see OpenGeographies::Decorators), never as forked copies of upstream files.
#
# The host provides the CoreDataConnector classes. On the merged core-data-cloud /
# FairData app they are native, autoloaded code and there is nothing to require. Only
# a legacy host that still uses the standalone core_data_connector gem has a file by
# that name — load it if present so the engine still works there, and otherwise do
# nothing rather than fail (the gem no longer exists to install).
begin
  require 'core_data_connector'
rescue LoadError
  nil
end
require 'open_geographies/version'
require 'open_geographies/engine'
require 'open_geographies/tenancy_probe'
require 'open_geographies/facet_catalog'
require 'open_geographies/field_catalog'
require 'open_geographies/public_project_import'

module OpenGeographies
end
