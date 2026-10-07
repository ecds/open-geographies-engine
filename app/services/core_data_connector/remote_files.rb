# frozen_string_literal: true

require 'ipaddr'
require 'net/http'
require 'resolv'

module CoreDataConnector
  # Downloads a file that a curator's data points at — a spreadsheet's photo
  # links — without letting that address reach into the server's own
  # network. A link in an uploaded file is someone else's input, and the
  # server sits beside the database, Elasticsearch and cloud metadata
  # endpoints, so:
  #
  # - http(s) on the standard ports only, no user:password@ in the address;
  # - the host must resolve only to public addresses (no loopback, private,
  #   link-local — 169.254.169.254 — carrier-grade NAT, multicast or
  #   reserved ranges, in IPv4 or IPv6), and the connection is made to an
  #   address that was checked, so a second DNS answer can't swap it. IPv4
  #   addresses are tried before IPv6 ones, and the next is tried only when
  #   connecting fails: many servers and containers have no IPv6 route, and
  #   most photo sources (the Library of Congress among them) answer on both;
  # - every redirect is checked again, at most MAX_REDIRECTS of them;
  # - timeouts, and at most MAX_BYTES read.
  #
  # Returns a Download; raises Refused (the address isn't allowed), Busy (the
  # source asked us to slow down; retry_after in seconds) or Failed.
  module RemoteFiles
    MAX_BYTES = 50.megabytes
    MAX_REDIRECTS = 3
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    PORTS = { 'http' => 80, 'https' => 443 }.freeze
    USER_AGENT = 'OpenGeographies/1.0 (atlas photo import)'

    BLOCKED = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    class Error < StandardError; end
    class Refused < Error; end
    class Failed < Error; end
    class TimedOut < Failed; end

    class Busy < Error
      attr_reader :retry_after

      def initialize(message, retry_after)
        super(message)
        @retry_after = retry_after
      end
    end

    Download = Struct.new(:file, :content_type, :url, keyword_init: true) do
      def close!
        file&.close!
      end
    end

    module_function

    def fetch(url, redirects: MAX_REDIRECTS)
      uri = check_uri!(url)

      connect(uri, resolve!(uri.host)) do |http|
        request = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => USER_AGENT, 'Accept' => 'image/*')

        http.request(request) do |response|
          case response
          when Net::HTTPRedirection
            raise Failed, 'Too many redirects.' if redirects.zero?

            location = response['location'].to_s
            raise Failed, 'Redirected without an address.' if location.blank?

            return fetch(URI.join(uri.to_s, location).to_s, redirects: redirects - 1)
          when Net::HTTPSuccess
            return Download.new(file: read_body(response), content_type: response['content-type'].to_s.split(';').first, url: uri.to_s)
          when Net::HTTPTooManyRequests, Net::HTTPServiceUnavailable
            raise Busy.new("The source is busy (#{response.code}).", response['retry-after'].to_i.clamp(5, 300))
          else
            raise Failed, "The source answered #{response.code}#{" #{response.message}" if response.message.present?}."
          end
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise TimedOut, 'The source took too long to answer.'
    rescue OpenSSL::SSL::SSLError => e
      raise Failed, "The source's secure connection failed (#{e.message.truncate(80)})."
    rescue SocketError, SystemCallError, IOError => e
      raise Failed, "The source couldn't be reached (#{e.message.truncate(80)})."
    end

    def check_uri!(url)
      uri = URI.parse(url.to_s.strip)

      raise Refused, 'Only http:// and https:// addresses can be fetched.' unless PORTS.key?(uri.scheme&.downcase) && uri.host.present?
      raise Refused, 'Addresses with a user name or password are not fetched.' if uri.userinfo
      raise Refused, 'Only the standard web ports are used.' unless uri.port == PORTS[uri.scheme.downcase]

      uri
    rescue URI::InvalidURIError
      raise Refused, 'Not a web address.'
    end

    # Opens a connection to the first of the checked addresses that answers
    # and yields it. Only a failure to connect moves on to the next address;
    # once connected, errors are the source's.
    def connect(uri, addresses)
      addresses.each_with_index do |address, index|
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = address
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        begin
          http.start
        rescue Net::OpenTimeout, SystemCallError
          raise if index == addresses.size - 1

          next
        end

        begin
          return yield(http)
        ensure
          http.finish if http.started?
        end
      end
    end

    # The addresses to connect to, IPv4 first: every address the name
    # resolves to must be public (a name with one private answer is refused
    # outright).
    def resolve!(host)
      name = host.delete_prefix('[').delete_suffix(']')
      addresses = literal?(name) ? [name] : Resolv.getaddresses(name)

      raise Failed, "#{host} couldn't be found." if addresses.empty?
      raise Refused, "#{host} is not a public address." if addresses.any? { |address| blocked?(address) }

      ipv4_first(addresses.uniq)
    end

    # IPv4 addresses before IPv6 ones, each in the resolver's order.
    def ipv4_first(addresses)
      addresses.each_with_index.sort_by { |address, index| [IPAddr.new(address).ipv4? ? 0 : 1, index] }.map(&:first)
    end

    def blocked?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv6? && (ip.ipv4_mapped? || ip.ipv4_compat?)

      BLOCKED.any? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    def literal?(name)
      IPAddr.new(name)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def read_body(response)
      length = response['content-length'].to_i
      raise Failed, "The file is larger than #{MAX_BYTES / 1.megabyte} MB." if length > MAX_BYTES

      file = Tempfile.new('og-remote', binmode: true)
      size = 0

      response.read_body do |chunk|
        size += chunk.bytesize
        if size > MAX_BYTES
          file.close!
          raise Failed, "The file is larger than #{MAX_BYTES / 1.megabyte} MB."
        end

        file.write(chunk)
      end

      file.flush
      file.rewind
      file
    end
  end
end
