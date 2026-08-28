# frozen_string_literal: true

require "digest"
require "net/http"
require "pathname"
require "tempfile"
require "uri"

require "lx"

module Lx
  class Adminer
    MAX_REDIRECTS = 5

    def initialize(config:, fetcher: nil)
      @config = config
      @fetcher = fetcher || method(:download)
    end

    def install!
      destination = @config.runtime_root.join("adminer/index.php")
      return false if valid?(destination)

      body = @fetcher.call(@config.adminer_url)
      actual = Digest::SHA256.hexdigest(body)
      unless actual == @config.adminer_sha256
        raise CommandError, "Adminer checksum mismatch: expected #{@config.adminer_sha256}, got #{actual}"
      end

      destination.dirname.mkpath
      Tempfile.create(["adminer", ".php"], destination.dirname, binmode: true) do |file|
        file.write(body)
        file.flush
        file.fsync
        File.rename(file.path, destination)
      end
      true
    rescue SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError => error
      raise CommandError, "Failed to install Adminer #{@config.adminer_version}: #{error.message}"
    end

    private

    def valid?(path)
      path.file? && Digest::SHA256.file(path).hexdigest == @config.adminer_sha256
    end

    def download(url, redirects = MAX_REDIRECTS)
      raise CommandError, "Too many redirects while downloading Adminer" if redirects.negative?

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port, :ENV)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30
      response = http.start { |client| client.get(uri.request_uri) }

      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        download(URI.join(uri, response.fetch("location")).to_s, redirects - 1)
      else
        raise CommandError, "Failed to download Adminer: HTTP #{response.code}"
      end
    end
  end
end
