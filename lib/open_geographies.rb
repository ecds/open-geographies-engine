# Open Geographies — a Rails engine that extends Performant Software's Core Data
# (core_data_connector) with the multi-tenant, no-code geospatial publishing layer:
# Sites, SearchCollections, atlas provisioning, authority bulk imports, automated
# Typesense indexing, and the by-slug public atlas API.
#
# It is deliberately additive: it installs onto a CLEAN upstream core_data_connector
# with no fork. Its migrations only CREATE new tables; its modifications to upstream
# classes are applied as decorators at boot (see OpenGeographies::Decorators), never as
# forked copies of upstream files.
require 'core_data_connector'
require 'open_geographies/version'
require 'open_geographies/engine'

module OpenGeographies
end
