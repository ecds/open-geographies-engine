require_relative 'lib/open_geographies/version'

Gem::Specification.new do |spec|
  spec.name        = 'open_geographies'
  spec.version     = OpenGeographies::VERSION
  spec.authors     = ['Terminus Films']
  spec.email       = ['steve@terminusfilms.com']
  spec.homepage    = 'https://github.com/terminusfilms/open-geographies-engine'
  spec.summary     = 'No-code, multi-tenant geospatial publishing layer for Core Data.'
  spec.description = 'A Rails engine that extends Performant Software Core Data ' \
                     '(core_data_connector) with atlas provisioning, Sites, ' \
                     'SearchCollections, authority bulk imports, automated Typesense ' \
                     'indexing, and a by-slug public atlas API. Additive: installs ' \
                     'onto a clean upstream Core Data with no fork.'
  spec.license     = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  end

  # The engine extends Core Data in place; it must load after it. All other runtime
  # deps (typesense, rgeo, etc.) come transitively through core_data_connector.
  spec.add_dependency 'core_data_connector'
  spec.add_dependency 'rails', '>= 8.1', '< 9'
end
