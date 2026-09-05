module CoreDataConnector
  # GET /wizard
  #
  # The "Create your atlas" wizard page. The wizard is a small self-contained
  # React app that lives in this engine (client/, built to public/wizard/) and
  # talks to the engine's own admin API (POST /core_data/atlases, jobs,
  # place_imports) with the session the FairData console already holds in
  # localStorage. FairData links here from its navigation; everything past that
  # link — this page, its assets, its flow — is the engine's, so the host's SPA
  # is not forked and never needs to know the wizard exists.
  #
  # Inherits from ActionController::Base rather than the JSON-only
  # CoreDataConnector::ApplicationController: this renders HTML and needs no
  # authentication of its own (the page holds no data; every API call it makes
  # is authenticated by the console session).
  class WizardController < ActionController::Base
    protect_from_forgery with: :exception

    layout false

    def show
      @config = {
        apiBaseUrl: '',
        consoleUrl: '',
        mapTilerKey: ENV.fetch('VITE_MAP_TILER_KEY', nil),
        atlasUrlTemplate: ENV.fetch('OG_ATLAS_URL_TEMPLATE', nil)
      }
    end
  end
end
