# An atlas can have a domain of its own (atlas.example.org) besides its
# address on the platform (<slug>.<base domain>). The domain is connected
# only once its DNS names this atlas (see CoreDataConnector::SiteDomains);
# until then it's stored but not served. More than one atlas may have
# entered the same domain, but only one can be connected to it.
class AddDomainToCoreDataConnectorSites < ActiveRecord::Migration[8.1]
  def change
    add_column :core_data_connector_sites, :domain, :string
    add_column :core_data_connector_sites, :domain_verified_at, :datetime

    add_index :core_data_connector_sites, :domain, unique: true, where: 'domain_verified_at IS NOT NULL',
                                                   name: 'index_core_data_connector_sites_on_connected_domain'
  end
end
