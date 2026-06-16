require 'net/http'
require 'json'
require 'erb'

module CoreDataConnector
  # Minimal Netlify REST client for the deployment pipeline (no gem
  # dependency). The token comes from the site's Hosting settings (each
  # atlas author brings their own Netlify account) or the instance-wide
  # NETLIFY_AUTH_TOKEN fallback.
  #
  #   NETLIFY_API_URL - overrides the API endpoint (local verification)
  class Netlify
    API_BASE = 'https://api.netlify.com/api/v1'.freeze

    class Error < StandardError; end

    attr_reader :token

    def initialize(token)
      @token = token
    end

    def self.api_base
      ENV.fetch('NETLIFY_API_URL', API_BASE)
    end

    # Creates a deploy on the site from a "/path" => SHA1 digest map. The
    # response's "required" lists the digests Netlify doesn't already have;
    # only those files need uploading.
    def create_deploy(site_id, files)
      request(:post, "/sites/#{site_id}/deploys", body: { files: })
    end

    # Uploads one file's contents into the deploy. The upload path matches
    # the digest-map key with the leading slash dropped, segments encoded.
    def upload_file(deploy_id, path, content)
      encoded = path.delete_prefix('/').split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')

      request(:put, "/deploys/#{deploy_id}/files/#{encoded}", raw: content)
    end

    def deploy(deploy_id)
      request(:get, "/deploys/#{deploy_id}")
    end

    private

    def request(method, path, body: nil, raw: nil)
      uri = URI("#{self.class.api_base}#{path}")

      request = Net::HTTP.const_get(method.capitalize).new(uri)
      request['Authorization'] = "Bearer #{token}"

      if raw
        request['Content-Type'] = 'application/octet-stream'
        request.body = raw
      elsif body
        request['Content-Type'] = 'application/json'
        request.body = body.to_json
      end

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) do |http|
        http.request(request)
      end

      parsed = JSON.parse(response.body) rescue {}

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Netlify #{method.upcase} #{path} failed (#{response.code}): #{parsed['message'] || response.body.to_s.truncate(300)}"
      end

      parsed
    end
  end
end
