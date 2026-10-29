# frozen_string_literal: true

require_relative "test_helper"

class ClientFactoryTest < Minitest::Test
  include EnvHelper

  PARAMS = {max_tokens: 32, messages: [{role: "user", content: "Hello"}], model: MODEL}.freeze

  def setup
    @server = LoopbackServer.new
    @base_url = @server.base_url
  end

  def teardown
    @server.close
  end

  def create(**options)
    ClaudeSample::ClientFactory.create_client(
      **{base_url: @base_url, token_provider: -> { "selected-token" }, max_retries: 0}.merge(options)
    )
  end

  def requests = @server.requests

  def test_returns_the_standard_client_and_resolves_the_token_per_request_not_at_creation
    calls = 0
    tokens = %w[first-token second-token]
    client = create(token_provider: -> { tokens.fetch((calls += 1) - 1) })
    assert_instance_of Anthropic::Client, client
    assert_equal 0, calls
    assert_equal "OK", client.messages.create(**PARAMS).content.first.text
    client.messages.create(**PARAMS)
    assert_equal 2, calls
    assert_equal ["Bearer first-token", "Bearer second-token"], requests.map { |request| request.header("authorization") }
    requests.each do |request|
      assert_nil request.header("anthropic-beta"), "a generic bearer must not carry the OAuth beta"
      assert_nil request.header("x-api-key")
      assert_nil request.header("api-key")
      refute_includes request.wire, "provided-by-request-hook", "the suppression placeholder stays off the wire"
    end
  end

  def test_sends_the_model_and_the_native_or_foundry_style_path
    {"" => "/v1/messages", "/anthropic" => "/anthropic/v1/messages"}.each do |prefix, path|
      requests.clear
      create(base_url: @server.base_url(prefix)).messages.create(**PARAMS)
      assert_equal path, requests.first.path
      assert_equal MODEL, requests.first.json["model"]
      assert_equal 32, requests.first.json["max_tokens"]
    end
  end

  def test_ambient_credentials_profile_base_url_and_custom_headers_cannot_reach_the_wire
    ambient = {
      "ANTHROPIC_API_KEY" => "ambient-key-canary",
      "ANTHROPIC_AUTH_TOKEN" => "ambient-token-canary",
      "ANTHROPIC_PROFILE" => "nonexistent-profile-canary",
      "ANTHROPIC_BASE_URL" => "https://wrong.example",
      "ANTHROPIC_CUSTOM_HEADERS" => "Authorization: custom-canary\nx-api-key: key-canary\napi-key: alias-canary",
      "ANTHROPIC_FOUNDRY_RESOURCE" => "unchanged-cli-resource"
    }
    with_env(ambient) do
      create.messages.create(
        **PARAMS,
        request_options: {extra_headers: {"Authorization" => "request-canary", "x-api-key" => "request-key-canary",
                                          "anthropic-beta" => "a-requested-beta"}}
      )
      request = requests.first
      assert_equal "Bearer selected-token", request.header("authorization")
      assert_nil request.header("x-api-key")
      assert_nil request.header("api-key")
      assert_equal "a-requested-beta", request.header("anthropic-beta"), "the requested beta is preserved and nothing is added"
      assert_equal "/anthropic/v1/messages", request.path, "the explicit base URL wins over ANTHROPIC_BASE_URL"
      refute_includes request.wire, "canary"
      assert_equal "unchanged-cli-resource", ENV.fetch("ANTHROPIC_FOUNDRY_RESOURCE"), "the factory does not touch the environment"
    end
  end

  def test_control_the_same_ambient_values_do_reach_the_wire_from_an_unconfigured_sdk_client
    with_env("ANTHROPIC_API_KEY" => "ambient-key-canary", "ANTHROPIC_CUSTOM_HEADERS" => "x-api-key: header-canary\napi-key: alias-canary") do
      capture_io { Anthropic::Client.new(base_url: @base_url, max_retries: 0).messages.create(**PARAMS) }
      %w[ambient-key-canary header-canary alias-canary].each do |canary|
        assert_includes requests.first.wire, canary, "the SDK defaults leak #{canary}, so the canary test is meaningful"
      end
    end
    with_env("ANTHROPIC_PROFILE" => "nonexistent-profile-canary") do
      assert_raises(Anthropic::Errors::Error, "the SDK looks for the profile named by ANTHROPIC_PROFILE") do
        Anthropic::Client.new(base_url: @base_url)
      end
      create(api_key: "selected-key", token_provider: nil)
    end
  end

  def test_api_key_header_is_configuration_authorization_by_default_any_other_name_verbatim
    [
      [nil, "authorization", "Bearer selected-key"],
      ["Authorization", "authorization", "Bearer selected-key"],
      ["x-api-key", "x-api-key", "selected-key"],
      ["api-key", "api-key", "selected-key"]
    ].each do |header, name, expected|
      requests.clear
      options = {token_provider: nil, api_key: "selected-key"}
      options[:key_header] = header if header
      create(**options).messages.create(**PARAMS)
      request = requests.first
      assert_equal expected, request.header(name), "#{name} for #{header.inspect}"
      (%w[authorization x-api-key api-key] - [name]).each { |other| assert_nil request.header(other), "#{other} must be absent" }
      assert_nil request.header("anthropic-beta")
      refute_includes request.wire, "provided-by-request-hook"
    end
  end

  def test_anthropic_version_is_the_sdk_default_unless_configured
    create.messages.create(**PARAMS)
    assert_equal "2026-10-21", requests.last.header("anthropic-version"), "the SDK default version"
    create(api_version: "2023-06-01").messages.create(
      **PARAMS, request_options: {extra_headers: {"anthropic-version" => "request-version"}}
    )
    assert_equal "2023-06-01", requests.last.header("anthropic-version"), "the configured version"
  end

  def test_invalid_configuration_fails_before_any_network_use
    invalid = {
      "neither credential" => {token_provider: nil},
      "both credentials" => {api_key: "key"},
      "plain HTTP" => {base_url: "http://insecure.example"},
      "credentials in the URL" => {base_url: "https://user:secret@example.com"},
      "query in the URL" => {base_url: "https://example.com/anthropic?x=1"},
      "fragment in the URL" => {base_url: "https://example.com/anthropic#x"},
      "unsupported scheme" => {base_url: "ftp://example.com"},
      "no host" => {base_url: "https://"},
      "empty URL" => {base_url: ""},
      "not callable" => {token_provider: "token"},
      "empty key" => {token_provider: nil, api_key: ""},
      "multi-line key" => {token_provider: nil, api_key: "key\nvalue"},
      "spaced key" => {token_provider: nil, api_key: "key value"},
      "non-string key" => {token_provider: nil, api_key: 12_345},
      "bad header name" => {token_provider: nil, api_key: "key", key_header: "bad\nheader"},
      "empty header name" => {token_provider: nil, api_key: "key", key_header: ""},
      "bad version" => {api_version: "2023\n06"}
    }
    invalid.each do |label, options|
      assert_raises(ArgumentError, label) { create(**options) }
    end
    assert_empty requests
    ["http://127.0.0.1:8080", "http://localhost", "http://[::1]:8080", "https://example.com:8443/anthropic"].each do |accepted|
      create(base_url: accepted)
    end
  end

  def test_the_factory_keeps_the_sdk_defaults_for_timeout_and_retries_unless_given
    client = ClaudeSample::ClientFactory.create_client(base_url: @base_url, token_provider: -> { "token" })
    assert_equal Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS, client.timeout
    assert_equal 600.0, client.timeout
    assert_equal Anthropic::Client::DEFAULT_MAX_RETRIES, client.max_retries
    assert_equal 30.0, create(timeout: 30).timeout
    assert_equal 5, create(max_retries: 5).max_retries
  end

  def test_a_same_origin_redirect_is_followed_and_re_authorized
    @server.close
    @server = LoopbackServer.new do |request, count|
      count == 1 ? [307, {"location" => "/anthropic/v1/messages-moved"}, ""] : LoopbackServer.json_response(message_body)
    end
    issued = 0
    create(base_url: @server.base_url, token_provider: -> { "token-#{issued += 1}" }).messages.create(**PARAMS)
    assert_equal ["Bearer token-1", "Bearer token-2"], requests.map { |request| request.header("authorization") }
    assert_equal "/anthropic/v1/messages-moved", requests.last.path
  end

  def test_a_cross_origin_redirect_is_refused_before_any_credential_is_produced_or_sent
    @server.close
    [
      ->(port) { "http://localhost:#{port}/anthropic/v1/messages" },
      ->(port) { "https://127.0.0.1:#{port}/anthropic/v1/messages" },
      ->(_port) { "http://127.0.0.1:1/anthropic/v1/messages" }
    ].each do |target|
      port = nil
      @server = LoopbackServer.new { |_request, _count| [302, {"location" => target.call(port)}, ""] }
      port = @server.port
      issued = 0
      error = assert_raises(RuntimeError) do
        create(base_url: @server.base_url, token_provider: -> { "token-#{issued += 1}" }).messages.create(**PARAMS)
      end
      assert_equal "Refusing to send credentials to a different origin.", error.message
      assert_equal 1, requests.length, "only the original origin is contacted"
      assert_equal 1, issued, "no token is produced for the refused hop"
      @server.close
    end
    @server = LoopbackServer.new
  end

  def test_a_provider_failure_surfaces_unchanged_and_no_request_is_sent
    failure = RuntimeError.new("credential unavailable")
    error = assert_raises(RuntimeError) { create(token_provider: -> { raise failure }).messages.create(**PARAMS) }
    assert_same failure, error
    assert_empty requests
  end

  def test_a_token_that_is_empty_multi_line_or_not_a_string_is_rejected_without_being_echoed
    ["", "line\nbreak", "has space", 42, nil].each do |bad|
      error = assert_raises(RuntimeError) { create(token_provider: -> { bad }).messages.create(**PARAMS) }
      assert_equal "The token provider must return a non-empty string without whitespace or control characters.", error.message
    end
    assert_empty requests
  end

  def test_http_error_statuses_surface_as_sdk_errors_that_do_not_contain_the_credential
    {
      401 => Anthropic::Errors::AuthenticationError, 403 => Anthropic::Errors::PermissionDeniedError,
      429 => Anthropic::Errors::RateLimitError, 500 => Anthropic::Errors::InternalServerError
    }.each do |status, error_class|
      @server.close
      @server = LoopbackServer.new { |_request, _count| LoopbackServer.json_response(error_body("api_error", "test failure"), status) }
      error = assert_raises(error_class) { create(base_url: @server.base_url).messages.create(**PARAMS) }
      assert_equal status, error.status
      refute_includes error.message, "selected-token"
    end
  end

  def test_an_sdk_retry_acquires_a_fresh_token
    @server.close
    @server = LoopbackServer.new do |_request, count|
      if count == 1
        LoopbackServer.json_response(error_body("api_error", "try again"), 500, "retry-after-ms" => "1")
      else
        LoopbackServer.json_response(message_body)
      end
    end
    issued = 0
    create(base_url: @server.base_url, max_retries: 1, token_provider: -> { "token-#{issued += 1}" }).messages.create(**PARAMS)
    assert_equal ["Bearer token-1", "Bearer token-2"], requests.map { |request| request.header("authorization") }
  end

  def test_streaming_goes_through_the_same_credential_hook
    @server.close
    @server = LoopbackServer.new { |_request, _count| [200, {"content-type" => "text/event-stream"}, sse_body(%w[Hel lo])] }
    stream = create(base_url: @server.base_url).messages.stream(**PARAMS)
    assert_equal "Hello", stream.text.to_a.join
    request = requests.first
    assert_equal "Bearer selected-token", request.header("authorization")
    assert_includes request.header("accept"), "text/event-stream"
    assert_nil request.header("anthropic-beta")
  end

  def test_the_transport_timeout_is_enforced
    @server.close
    @server = LoopbackServer.new do |_request, _count|
      sleep 3
      LoopbackServer.json_response(message_body)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Anthropic::Errors::APITimeoutError) { create(base_url: @server.base_url, timeout: 1.0).messages.create(**PARAMS) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.9, "the request must end at the 1 second timeout"
  end
end
