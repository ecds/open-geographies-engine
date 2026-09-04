require_relative 'lib/open_geographies/version'

Gem::Specification.new do |spec|
  spec.name        = 'open_geographies'
  spec.version     = OpenGeographies::VERSION
  spec.authors     = ['Terminus Films']
  spec.email       = ['steve@terminusfilms.com']
  spec.homepage    = 'https://github.com/ecds/open-geographies-engine'
  spec.summary     = 'No-code, multi-tenant geospatial publishing layer for Core Data / FairData.'
  spec.description = 'A Rails engine that extends Performant Software Core Data ' \
                     '(FairData) with atlas provisioning, Sites, authority bulk ' \
                     'imports, and a by-slug public atlas API. Additive: mounts onto ' \
                     'an unmodified host and only creates new tables.'
  spec.license     = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  end

  # No dependency on core_data_connector: the standalone gem no longer exists (its
  # code was folded into core-data-cloud / FairData), so declaring it would fail
  # `bundle install` on every real host. The engine needs the CoreDataConnector
  # classes to exist at boot, however the host provides them — the merged app
  # autoloads them; a legacy gem-based host lists the gem before this one.
  # Other runtime libraries (rgeo, etc.) are the host's, not ours to pin.
  spec.add_dependency 'rails', '>= 8.1', '< 9'
end
