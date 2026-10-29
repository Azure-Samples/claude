# frozen_string_literal: true

require "anthropic"
require "uri"

module ClaudeSample
  # Creates the standard Anthropic::Client for any Anthropic-compatible endpoint with exactly one explicit credential.
  #
  # The factory reads no environment variables and imports no cloud-provider code. Left alone, the SDK would look for
  # ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_PROFILE, workload identity variables and profiles on disk, so it
  # is handed a public, non-secret placeholder that only switches that discovery off. A public request middleware then
  # runs on every HTTP attempt (retries and redirect hops included), removes every credential header, and applies the
  # selected credential. The placeholder never leaves the process.
  module ClientFactory
    # Credential-bearing headers. All of them are removed before the selected credential is applied.
    CREDENTIAL_HEADERS = %w[authorization x-api-key api-key].freeze

    # Public, non-secret value that only stops the SDK from discovering credentials.
    SUPPRESSION_PLACEHOLDER = "provided-by-request-hook"

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

    VISIBLE_ASCII = /\A[\x21-\x7E]+\z/
    HEADER_NAME = /\A[!\#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    BASE_URL_ERROR = "base_url must be an HTTPS URL without credentials, query, or fragment."
    SECRET_ERROR = "must be a non-empty string without whitespace or control characters."

    class << self
      # @param base_url [String] HTTPS endpoint (plain HTTP only for loopback hosts) without credentials, query or fragment
      # @param token_provider [#call, nil] returns a bearer token. It runs once per HTTP attempt, so it should be cheap or cache.
      # @param api_key [String, nil] a static key; exclusive with token_provider
      # @param key_header [String] header that carries api_key. "Authorization" sends "Bearer <key>"; any other name sends the raw key.
      # @param api_version [String, nil] anthropic-version to send on every request; nil keeps the SDK default
      # @param timeout [Float, nil] seconds per attempt, enforced by the SDK; nil keeps the SDK default
      # @param max_retries [Integer, nil] nil keeps the SDK default
      # @return [Anthropic::Client]
      def create_client(base_url:, token_provider: nil, api_key: nil, key_header: "Authorization", api_version: nil,
                        timeout: nil, max_retries: nil)
        origin = origin_of(base_url)
        raise ArgumentError, "Provide exactly one of token_provider or api_key." if token_provider.nil? == api_key.nil?
        raise ArgumentError, "token_provider must respond to #call." unless token_provider.nil? || token_provider.respond_to?(:call)
        raise ArgumentError, "key_header must be a valid HTTP header name." unless HEADER_NAME.match?(key_header.to_s)
        raise ArgumentError, "api_key #{SECRET_ERROR}" unless api_key.nil? || visible_ascii?(api_key)
        raise ArgumentError, "api_version #{SECRET_ERROR}" unless api_version.nil? || visible_ascii?(api_version)

        header = token_provider ? "authorization" : key_header.downcase
        authorize = lambda do |request, nxt|
          assert_origin!(request.url, origin)
          secret = token_provider ? acquire_token(token_provider) : api_key
          headers = request.headers.reject { |name, _| CREDENTIAL_HEADERS.include?(name.downcase) || name.downcase == header }
          headers[header] = header == "authorization" ? "Bearer #{secret}" : secret
          headers["anthropic-version"] = api_version if api_version
          nxt.call(request.with(headers: headers.freeze))
        end

        options = {auth_token: SUPPRESSION_PLACEHOLDER, base_url: base_url, middleware: [authorize]}
        options[:timeout] = Float(timeout) unless timeout.nil?
        options[:max_retries] = max_retries unless max_retries.nil?
        Anthropic::Client.new(**options)
      end

      private

      def visible_ascii?(value)
        value.is_a?(String) && VISIBLE_ASCII.match?(value)
      end

      # @return [Array(String, String, Integer)] scheme, host, port
      def origin_of(base_url)
        uri = begin
          URI.parse(base_url.to_s)
        rescue URI::InvalidURIError
          raise ArgumentError, BASE_URL_ERROR
        end
        host = uri.host.to_s.downcase
        secure = uri.scheme == "https" || (uri.scheme == "http" && LOOPBACK_HOSTS.include?(host))
        raise ArgumentError, BASE_URL_ERROR if host.empty? || !secure || uri.userinfo || uri.query || uri.fragment

        [uri.scheme, host, uri.port]
      end

      def assert_origin!(url, origin)
        return if [url.scheme, url.host.to_s.downcase, url.port] == origin && url.userinfo.nil?

        raise "Refusing to send credentials to a different origin."
      end

      def acquire_token(token_provider)
        token = token_provider.call
        return token if visible_ascii?(token)

        raise "The token provider must return a non-empty string without whitespace or control characters."
      end
    end
  end
end
