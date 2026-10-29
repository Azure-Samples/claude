# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class SampleTest < Minitest::Test
  include EnvHelper

  CLI_OK = ->(_arguments) { [0, '{"accessToken":"entra-test-token"}'] }
  NO_ENDPOINT = "Error: Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME, or ANTHROPIC_BASE_URL and ANTHROPIC_MODEL. The two sets are never mixed.\n"
  LEGACY_NEEDS_MODEL = "Error: CLAUDE_BASE_URL selects the CLAUDE_* settings: also set CLAUDE_DEPLOYMENT_NAME (ANTHROPIC_MODEL is not used with it).\n"
  CANONICAL_NEEDS_MODEL = "Error: ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings: also set ANTHROPIC_MODEL (CLAUDE_DEPLOYMENT_NAME is not used with it).\n"
  LEGACY_NEEDS_KEY = "Error: Set CLAUDE_API_KEY (ANTHROPIC_API_KEY is not used with CLAUDE_BASE_URL).\n"
  CANONICAL_NEEDS_KEY = "Error: Set ANTHROPIC_API_KEY (CLAUDE_API_KEY is not used with ANTHROPIC_BASE_URL).\n"
  CANONICAL_NEEDS_MODE = "Error: ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE: " \
                         "set AUTH_MODE=api_key (uses ANTHROPIC_API_KEY) or AUTH_MODE=bearer (uses an Azure CLI token).\n"

  def teardown
    @server&.close
  end

  def serve(&responder)
    @server&.close
    @server = LoopbackServer.new(&responder)
  end

  # The legacy (CLAUDE_*) settings.
  def sample_env(extra = {})
    {"CLAUDE_BASE_URL" => @server.base_url, "CLAUDE_DEPLOYMENT_NAME" => MODEL}.merge(extra)
  end

  # The canonical (ANTHROPIC_*) settings.
  def canonical_env(extra = {})
    {"ANTHROPIC_BASE_URL" => @server.base_url, "ANTHROPIC_MODEL" => MODEL}.merge(extra)
  end

  # @return [Array(Integer, String, String)] exit status, stdout, stderr
  def run_sample(argv, env, cli: CLI_OK, ambient: {})
    stdout = StringIO.new
    stderr = StringIO.new
    status = with_env(ambient) { ClaudeSample::Sample.run(argv, env, stdout, stderr, run_cli: cli) }
    [status, stdout.string, stderr.string]
  end

  def counting_cli
    calls = []
    [calls, lambda { |arguments|
      calls << arguments
      [0, '{"accessToken":"entra-test-token"}']
    }]
  end

  def thinking_then_text
    body = message_body("OK")
    body["content"].unshift({"type" => "thinking", "thinking" => "not for display", "signature" => "sample"})
    body
  end

  def test_the_one_shot_sample_prints_the_text_and_usage_never_the_thinking_and_sends_one_bearer_request
    serve { |_request, _count| LoopbackServer.json_response(thinking_then_text) }
    status, stdout, stderr = run_sample([], sample_env)
    assert_equal 0, status, stderr
    assert_equal "OK\n\n[usage] input=1 output=2\n", stdout
    assert_equal "", stderr
    assert_equal 1, @server.requests.length
    request = @server.requests.first
    assert_equal "/anthropic/v1/messages", request.path
    assert_equal "Bearer entra-test-token", request.header("authorization")
    assert_equal "2026-10-21", request.header("anthropic-version"), "the SDK default API version"
    %w[anthropic-beta x-api-key api-key].each { |name| assert_nil request.header(name), "#{name} must be absent" }
    assert_equal MODEL, request.json["model"]
    assert_equal 1024, request.json["max_tokens"]
    assert_equal ClaudeSample::Sample::PROMPT, request.json["messages"].first["content"]
  end

  def test_stream_prints_the_text_as_it_arrives_then_usage
    serve { |_request, _count| [200, {"content-type" => "text/event-stream"}, sse_body(["Seattle has ", "the Space Needle."], input: 11, output: 13)] }
    status, stdout, stderr = run_sample(["--stream"], sample_env)
    assert_equal 0, status, stderr
    assert_equal "Seattle has the Space Needle.\n\n[usage] input=11 output=13\n", stdout
    request = @server.requests.first
    assert_equal "Bearer entra-test-token", request.header("authorization")
    assert_includes request.header("accept"), "text/event-stream"
    assert_nil request.header("anthropic-beta")
  end

  def test_api_key_mode_authorization_by_default_api_key_header_and_anthropic_api_version_are_optional_overrides
    serve
    legacy = {"AUTH_MODE" => "api_key", "CLAUDE_API_KEY" => "sample-key"}
    canonical = {"AUTH_MODE" => "api_key", "ANTHROPIC_API_KEY" => "sample-key"}
    [
      ["legacy: default header", sample_env(legacy), "authorization", "Bearer sample-key", "2026-10-21"],
      ["legacy: resource key header", sample_env(legacy.merge("API_KEY_HEADER" => "x-api-key")), "x-api-key", "sample-key", "2026-10-21"],
      ["legacy: explicit version", sample_env(legacy.merge("ANTHROPIC_API_VERSION" => "2023-06-01")), "authorization", "Bearer sample-key", "2023-06-01"],
      ["canonical: explicit api_key", canonical_env(canonical), "authorization", "Bearer sample-key", "2026-10-21"],
      ["canonical: explicit api_key, resource key header", canonical_env(canonical.merge("API_KEY_HEADER" => "x-api-key")), "x-api-key", "sample-key", "2026-10-21"]
    ].each do |label, env, header, expected, version|
      cli_calls, cli = counting_cli
      status, _stdout, stderr = run_sample([], env, cli: cli)
      assert_equal 0, status, "#{label}: #{stderr}"
      request = @server.requests.last
      assert_equal expected, request.header(header), "#{label} header"
      assert_equal version, request.header("anthropic-version"), "#{label} version"
      assert_empty cli_calls, "#{label} must not start the Azure CLI"
      (%w[authorization x-api-key api-key] - [header]).each { |other| assert_nil request.header(other), "#{label}: #{other} must be absent" }
    end
  end

  def test_canonical_profile_auth_mode_is_explicit_and_only_anthropic_values_are_used
    serve
    calls, cli = counting_cli
    env = canonical_env(
      "ANTHROPIC_BASE_URL" => @server.base_url("/canonical"), "ANTHROPIC_MODEL" => "preferred-model",
      "AUTH_MODE" => "bearer", "TOKEN_SCOPE" => "api://example/.default", "AZURE_TENANT_ID" => "tenant-1.example",
      "CLAUDE_BASE_URL" => @server.base_url("/legacy-canary"), "CLAUDE_DEPLOYMENT_NAME" => "legacy-model-canary", "CLAUDE_API_KEY" => "legacy-key-canary"
    )
    status, _stdout, stderr = run_sample([], env, cli: cli)
    assert_equal 0, status, stderr
    request = @server.requests.first
    assert_equal "/canonical/v1/messages", request.path
    assert_equal "preferred-model", request.json["model"]
    assert_equal "Bearer entra-test-token", request.header("authorization")
    assert_equal [%w[account get-access-token --scope api://example/.default --output json --tenant tenant-1.example]], calls
    refute_includes request.wire, "canary"
  end

  def test_mixed_families_neither_profile_ever_borrows_a_model_or_key_from_the_other
    serve
    ambient_anthropic = {"ANTHROPIC_API_KEY" => "ambient-anthropic-key-canary", "ANTHROPIC_MODEL" => "ambient-model-canary",
                         "ANTHROPIC_AUTH_TOKEN" => "ambient-token-canary"}
    legacy_decoys = {"CLAUDE_BASE_URL" => @server.base_url("/legacy-canary"), "CLAUDE_DEPLOYMENT_NAME" => "legacy-model-canary",
                     "CLAUDE_API_KEY" => "legacy-key-canary"}
    {
      "legacy profile with ambient ANTHROPIC_* values" =>
        [sample_env({"AUTH_MODE" => "api_key", "CLAUDE_API_KEY" => "legacy-selected-key"}.merge(ambient_anthropic)), "Bearer legacy-selected-key", MODEL, "/anthropic/v1/messages"],
      "canonical profile with every legacy decoy present" =>
        [canonical_env({"ANTHROPIC_BASE_URL" => @server.base_url("/canonical"), "AUTH_MODE" => "api_key", "ANTHROPIC_API_KEY" => "canonical-selected-key"}.merge(legacy_decoys)),
         "Bearer canonical-selected-key", MODEL, "/canonical/v1/messages"],
      "both URLs set: the explicit canonical profile wins" =>
        [{"ANTHROPIC_BASE_URL" => @server.base_url("/canonical"), "ANTHROPIC_MODEL" => "canonical-model", "AUTH_MODE" => "api_key", "ANTHROPIC_API_KEY" => "canonical-selected-key"}.merge(legacy_decoys),
         "Bearer canonical-selected-key", "canonical-model", "/canonical/v1/messages"]
    }.each do |label, (env, authorization, model, path)|
      status, _stdout, stderr = run_sample([], env)
      assert_equal 0, status, "#{label}: #{stderr}"
      request = @server.requests.last
      assert_equal authorization, request.header("authorization"), "#{label}: authorization"
      assert_equal model, request.json["model"], "#{label}: model"
      assert_equal path, request.path, "#{label}: path"
      refute_includes request.wire, "canary", "#{label}: a decoy reached the wire"
    end
    sent = @server.requests.length

    {
      "ambient native endpoint and model never get an Azure token" => [canonical_env("AZURE_TENANT_ID" => "tenant-1.example"), CANONICAL_NEEDS_MODE],
      "canonical api_key never falls back to CLAUDE_API_KEY" => [canonical_env("AUTH_MODE" => "api_key", "CLAUDE_API_KEY" => "legacy-key-canary"), CANONICAL_NEEDS_KEY],
      "canonical model never falls back to CLAUDE_DEPLOYMENT_NAME" =>
        [{"ANTHROPIC_BASE_URL" => @server.base_url, "ANTHROPIC_API_KEY" => "k"}.merge(legacy_decoys), CANONICAL_NEEDS_MODEL],
      "legacy api_key never falls back to ANTHROPIC_API_KEY" =>
        [sample_env("AUTH_MODE" => "api_key", "ANTHROPIC_API_KEY" => "ambient-anthropic-key-canary"), LEGACY_NEEDS_KEY],
      "legacy model never falls back to ANTHROPIC_MODEL" => [{"CLAUDE_BASE_URL" => @server.base_url}.merge(ambient_anthropic), LEGACY_NEEDS_MODEL]
    }.each do |label, (env, expected)|
      cli_calls, cli = counting_cli
      status, stdout, stderr = run_sample([], env, cli: cli)
      assert_equal 1, status, "#{label}: exit status"
      assert_equal expected, stderr, "#{label}: stderr"
      assert_equal "", stdout, "#{label}: stdout"
      assert_empty cli_calls, "#{label}: the Azure CLI must not start"
    end
    assert_equal sent, @server.requests.length, "a refused configuration sends no request"
  end

  def test_missing_mode_canary_the_canonical_profile_without_auth_mode_sends_neither_the_native_key_nor_an_azure_token
    serve
    ambient = {
      "ANTHROPIC_API_KEY" => "ambient-anthropic-key-canary", "AZURE_TENANT_ID" => "tenant-1.example", "TOKEN_SCOPE" => "api://example/.default",
      "CLAUDE_BASE_URL" => @server.base_url("/legacy-canary"), "CLAUDE_DEPLOYMENT_NAME" => "legacy-model-canary", "CLAUDE_API_KEY" => "legacy-key-canary"
    }
    [canonical_env(ambient), canonical_env({"AUTH_MODE" => ""}.merge(ambient))].each do |env|
      cli_calls, cli = counting_cli
      status, stdout, stderr = run_sample([], env, cli: cli, ambient: ambient)
      assert_equal 1, status, "exit status"
      assert_equal CANONICAL_NEEDS_MODE, stderr, "stderr"
      assert_equal "", stdout, "stdout"
      assert_empty cli_calls, "the Azure CLI must not start"
      refute_includes stderr + stdout, "canary", "the error must not echo any ambient value"
    end
    assert_empty @server.requests, "no request, so no native key and no Azure token left the process"
  end

  def test_configuration_errors_exit_1_with_a_clear_message_and_make_no_request
    serve
    {
      "no endpoint at all" => [{}, NO_ENDPOINT],
      "a legacy model alone is not an endpoint" => [{"CLAUDE_DEPLOYMENT_NAME" => MODEL}, NO_ENDPOINT],
      "a canonical model alone is not an endpoint" => [{"ANTHROPIC_MODEL" => MODEL}, NO_ENDPOINT],
      "legacy endpoint without its model" => [{"CLAUDE_BASE_URL" => @server.base_url}, LEGACY_NEEDS_MODEL],
      "canonical endpoint without its model" => [{"ANTHROPIC_BASE_URL" => @server.base_url}, CANONICAL_NEEDS_MODEL],
      "unknown mode" => [sample_env("AUTH_MODE" => "oauth"), "Error: AUTH_MODE must be bearer or api_key.\n"],
      "legacy key mode without a key" => [sample_env("AUTH_MODE" => "api_key"), LEGACY_NEEDS_KEY],
      "canonical endpoint without AUTH_MODE" => [canonical_env, CANONICAL_NEEDS_MODE],
      "canonical api_key without a key" => [canonical_env("AUTH_MODE" => "api_key"), CANONICAL_NEEDS_KEY],
      "plain HTTP endpoint" => [{"CLAUDE_BASE_URL" => "http://insecure.example", "CLAUDE_DEPLOYMENT_NAME" => MODEL},
                                "Error: base_url must be an HTTPS URL without credentials, query, or fragment.\n"],
      "unsafe scope" => [sample_env("TOKEN_SCOPE" => "x&y"), "Error: The token scope may only contain letters, digits and the characters . _ : / -\n"]
    }.each do |label, (env, expected)|
      status, stdout, stderr = run_sample([], env)
      assert_equal 1, status, label
      assert_equal expected, stderr, label
      assert_equal "", stdout, label
    end
    assert_empty @server.requests
  end

  def test_azure_token_credentials_azure_cli_credential_is_accepted_any_other_explicit_choice_is_refused_and_key_mode_ignores_it
    serve
    [nil, "AzureCliCredential"].each do |selector|
      calls, cli = counting_cli
      status, _stdout, stderr = run_sample([], sample_env(selector ? {"AZURE_TOKEN_CREDENTIALS" => selector} : {}), cli: cli)
      assert_equal 0, status, "accepted selector #{selector.inspect}: #{stderr}"
      assert_equal 1, calls.length, "the Azure CLI supplies the token"
    end

    {
      "ManagedIdentityCredential" => "ManagedIdentityCredential", "AzureDeveloperCliCredential" => "AzureDeveloperCliCredential",
      "DefaultAzureCredential" => "DefaultAzureCredential", "WorkloadIdentityCredential" => "WorkloadIdentityCredential",
      "azureclicredential" => "azureclicredential", "Azure\nCliCredential" => "(unprintable or too long)"
    }.each do |selector, shown|
      calls, cli = counting_cli
      requests_before = @server.requests.length
      status, stdout, stderr = run_sample([], sample_env("AZURE_TOKEN_CREDENTIALS" => selector), cli: cli)
      assert_equal 1, status, "#{shown}: exit status"
      assert_equal "Error: AZURE_TOKEN_CREDENTIALS=#{shown} is not supported: the Azure CLI (AzureCliCredential) is this sample's only built-in token " \
                   "source. Unset it, or pass your own token provider to ClientFactory for other credentials.\n", stderr, "#{shown}: stderr"
      assert_equal "", stdout
      assert_empty calls, "#{shown}: the Azure CLI must not start"
      assert_equal requests_before, @server.requests.length, "#{shown}: no request"
    end

    status, _stdout, stderr = run_sample([], sample_env("AUTH_MODE" => "api_key", "CLAUDE_API_KEY" => "sample-key", "AZURE_TOKEN_CREDENTIALS" => "ManagedIdentityCredential"))
    assert_equal 0, status, "key mode ignores the selector: #{stderr}"
  end

  def test_the_sample_sets_its_own_120_second_timeout_and_the_factory_itself_keeps_the_sdk_default
    serve
    assert_equal 120.0, ClaudeSample::Sample::REQUEST_TIMEOUT_SECONDS
    client, = with_env { ClaudeSample::Sample.configure(sample_env, CLI_OK) }
    assert_equal 120.0, client.timeout
    assert_equal Anthropic::Client::DEFAULT_MAX_RETRIES, client.max_retries, "the SDK retries are kept"
    assert_equal 600.0, ClaudeSample::ClientFactory.create_client(base_url: @server.base_url, api_key: "sample-key").timeout
  end

  def test_a_response_without_text_thinking_only_is_an_error_not_a_silent_success
    thinking_only = message_body
    thinking_only["content"] = [{"type" => "thinking", "thinking" => "not for display", "signature" => "sample"}]
    serve { |_request, _count| LoopbackServer.json_response(thinking_only) }
    status, stdout, stderr = run_sample([], sample_env)
    assert_equal 1, status
    assert_equal "", stdout
    assert_equal "Error: No text response (stop_reason=end_turn). Increase max_tokens if the response exhausted its budget.\n", stderr

    events = [
      ["message_start", {"type" => "message_start", "message" => {"id" => "m", "type" => "message", "role" => "assistant", "model" => MODEL, "content" => [],
                                                                    "stop_reason" => nil, "stop_sequence" => nil, "usage" => {"input_tokens" => 1, "output_tokens" => 1}}}],
      ["content_block_start", {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "thinking", "thinking" => "", "signature" => ""}}],
      ["content_block_delta", {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "thinking_delta", "thinking" => "hidden"}}],
      ["content_block_stop", {"type" => "content_block_stop", "index" => 0}],
      ["message_delta", {"type" => "message_delta", "delta" => {"stop_reason" => "max_tokens", "stop_sequence" => nil}, "usage" => {"output_tokens" => 9}}],
      ["message_stop", {"type" => "message_stop"}]
    ]
    body = events.map { |type, payload| "event: #{type}\ndata: #{JSON.generate(payload)}\n\n" }.join
    serve { |_request, _count| [200, {"content-type" => "text/event-stream"}, body] }
    status, stdout, stderr = run_sample(["--stream"], sample_env)
    assert_equal 1, status
    assert_equal "", stdout
    assert_equal "Error: No text response (stop_reason=max_tokens). Increase max_tokens if the response exhausted its budget.\n", stderr
  end

  def test_real_api_and_credential_failures_exit_1_and_never_print_the_token
    serve { |_request, _count| LoopbackServer.json_response(error_body("authentication_error", "invalid credential"), 401) }
    status, stdout, stderr = run_sample([], sample_env)
    assert_equal 1, status
    assert_equal "", stdout
    assert stderr.start_with?("Error: AuthenticationError: "), "the SDK error is named: #{stderr}"
    assert_includes stderr, "invalid credential"
    refute_includes stderr, "entra-test-token"

    serve { |_request, _count| LoopbackServer.json_response(error_body("api_error", "overloaded"), 500, "x-should-retry" => "false") }
    status, _stdout, stderr = run_sample(["--stream"], sample_env)
    assert_equal 1, status
    assert stderr.start_with?("Error: InternalServerError: "), "the streaming error is reported too: #{stderr}"

    serve
    status, stdout, stderr = run_sample([], sample_env, cli: ->(_arguments) { [1, '{"accessToken":"never-printed-token"}'] })
    assert_equal 1, status
    assert_equal "", stdout
    assert_equal %(Error: Azure CLI exited with code 1 while requesting a token for scope https://ai.azure.com/.default. ) +
                 %(Run "az login" and retry, or supply your own token provider.\n), stderr
    assert_empty @server.requests, "no request without a token"
  end

  def test_unknown_arguments_are_a_usage_error_help_prints_usage
    serve
    status, _stdout, stderr = run_sample(["--bogus"], sample_env)
    assert_equal 2, status
    assert_equal "Unknown argument: --bogus\nUsage: ruby main.rb [--stream]\n", stderr
    status, stdout, = run_sample(["--help"], {})
    assert_equal 0, status
    assert_equal "Usage: ruby main.rb [--stream]\n", stdout
  end

  def test_ambient_anthropic_credentials_in_the_process_environment_never_reach_the_sample_request
    serve
    ambient = {
      "ANTHROPIC_API_KEY" => "ambient-key-canary", "ANTHROPIC_AUTH_TOKEN" => "ambient-token-canary",
      "ANTHROPIC_PROFILE" => "nonexistent-profile-canary", "ANTHROPIC_CUSTOM_HEADERS" => "x-api-key: header-canary\napi-key: alias-canary"
    }
    [{}, {"AUTH_MODE" => "api_key", "CLAUDE_API_KEY" => "sample-key"}].each do |mode|
      status, _stdout, stderr = run_sample([], sample_env(mode), ambient: ambient)
      assert_equal 0, status, stderr
      refute_includes @server.requests.last.wire, "canary"
    end
  end
end
