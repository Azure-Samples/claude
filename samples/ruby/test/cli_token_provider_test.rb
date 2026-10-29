# frozen_string_literal: true

require_relative "test_helper"

class CliTokenProviderTest < Minitest::Test
  include EnvHelper

  FAKE_AZ = File.expand_path("fixtures/fake-az", __dir__)
  SCOPE = "https://ai.azure.com/.default"
  TOKEN_ARGUMENTS = ["account", "get-access-token", "--scope", SCOPE, "--output", "json"].freeze
  CLI = ClaudeSample::CliTokenProvider

  def failure_message(provider)
    assert_raises(RuntimeError) { provider.call }.message
  end

  def test_asks_for_the_scope_with_a_fixed_argument_list_once_per_token_request
    calls = []
    provider = CLI.provider(SCOPE, run: lambda { |arguments|
      calls << arguments
      [0, JSON.generate("accessToken" => "cli-token-#{calls.length}", "expiresOn" => "2099-01-01 00:00:00.000000", "tokenType" => "Bearer")]
    })
    assert_empty calls, "nothing runs at creation"
    assert_equal "cli-token-1", provider.call
    assert_equal "cli-token-2", provider.call, "this module keeps no cache of its own"
    assert_equal [TOKEN_ARGUMENTS, TOKEN_ARGUMENTS], calls
  end

  def test_adds_tenant_only_when_a_tenant_is_configured
    calls = []
    run = lambda { |arguments|
      calls << arguments
      [0, '{"accessToken":"t"}']
    }
    CLI.provider(SCOPE, "tenant-1.example", run: run).call
    CLI.provider(SCOPE, "", run: run).call
    CLI.provider(SCOPE, nil, run: run).call
    assert_equal [[*TOKEN_ARGUMENTS, "--tenant", "tenant-1.example"], TOKEN_ARGUMENTS, TOKEN_ARGUMENTS], calls
  end

  def test_arguments_are_allowlisted_so_nothing_is_interpreted_by_a_shell_or_cmd_exe
    ["", "a b", "a&b", "a|b", "a^b", "a%PATH%", 'a"b', "a'b", "a;b", "a`b", "a$b", "a(b)", "a<b", "a\nb", "a\\b"].each do |value|
      assert_raises(ArgumentError, "scope #{value.inspect}") { CLI.provider(value) }
      assert_raises(ArgumentError, "tenant #{value.inspect}") { CLI.provider(SCOPE, value.empty? ? "x y" : value) }
      assert_raises(ArgumentError, "run #{value.inspect}") { CLI.run(["account", value]) }
    end
    assert_raises(ArgumentError) { CLI.provider(nil) }
  end

  def test_cli_failure_malformed_output_and_empty_tokens_raise_exact_errors_without_echoing_the_payload
    leak = "raw-payload-secret-value"
    cases = {
      "non-zero exit" => [7, %({"accessToken":"#{leak}"}),
                          %(Azure CLI exited with code 7 while requesting a token for scope #{SCOPE}. Run "az login" and retry, or supply your own token provider.)],
      "not JSON" => [0, "ERROR #{leak}", "Azure CLI returned output that is not a JSON object."],
      "JSON scalar" => [0, %("#{leak}"), "Azure CLI returned output that is not a JSON object."],
      "JSON list" => [0, %(["#{leak}"]), "Azure CLI returned output that is not a JSON object."],
      "no accessToken" => [0, %({"refreshToken":"#{leak}"}), "Azure CLI response has no usable accessToken."],
      "empty accessToken" => [0, %({"accessToken":"","refreshToken":"#{leak}"}), "Azure CLI response has no usable accessToken."],
      "null accessToken" => [0, %({"accessToken":null,"x":"#{leak}"}), "Azure CLI response has no usable accessToken."],
      "numeric accessToken" => [0, %({"accessToken":12345,"x":"#{leak}"}), "Azure CLI response has no usable accessToken."],
      "spaced accessToken" => [0, %({"accessToken":"two words","x":"#{leak}"}), "Azure CLI response has no usable accessToken."],
      "multi-line accessToken" => [0, %({"accessToken":"line\\nbreak","x":"#{leak}"}), "Azure CLI response has no usable accessToken."]
    }
    cases.each do |label, (exit_status, stdout, expected)|
      message = failure_message(CLI.provider(SCOPE, run: ->(_arguments) { [exit_status, stdout] }))
      assert_equal expected, message, label
      refute_includes message, leak, "#{label} echoed the CLI payload"
    end
  end

  def test_a_cli_that_does_not_finish_within_its_allowance_is_stopped_and_reported_never_replaced_by_a_fallback
    File.chmod(0o755, File.join(FAKE_AZ, "az")) unless Gem.win_platform?
    assert_equal 60.0, CLI::TIMEOUT_SECONDS, "the default allowance is finite and generous"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    provider = CLI.provider(SCOPE, run: ->(arguments) { CLI.run(arguments, FAKE_AZ, timeout: 1.0) })
    message = with_env("FAKE_AZ_MODE" => "slow") { failure_message(provider) }
    assert_equal 'Azure CLI did not finish within its 1 second allowance and was stopped; try "az account get-access-token --output none" ' \
                 "by hand, or supply your own token provider.", message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4.5, "the CLI must be stopped at its allowance (the fixture takes about 7 seconds)"
    refute_includes message, "too-late-token"
  end

  def test_a_missing_azure_cli_is_reported_with_an_actionable_message
    error = assert_raises(RuntimeError) { CLI.run(["version"], File.expand_path("no-such-directory", __dir__)) }
    assert_equal 'Azure CLI ("az") was not found on PATH. Install it and run "az login", or supply your own token provider.', error.message
  end

  def test_command_a_windows_batch_file_runs_under_cmd_exe_from_its_own_directory_anything_else_runs_directly
    arguments = %w[account get-access-token]
    cmd = "C:/Windows/System32/cmd.exe"
    assert_equal [[cmd, "/d", "/c", "az.cmd", *arguments], "C:/Program Files (x86)/Azure CLI/wbin"],
                 CLI.command("C:/Program Files (x86)/Azure CLI/wbin/az.cmd", arguments, windows: true, interpreter: cmd)
    assert_equal [[cmd, "/d", "/c", "az.BAT", *arguments], "C:/tools"], CLI.command("C:/tools/az.BAT", arguments, windows: true, interpreter: cmd)
    assert_equal [["C:/tools/az.exe", *arguments], nil], CLI.command("C:/tools/az.exe", arguments, windows: true, interpreter: cmd)
    assert_equal [["/usr/bin/az", *arguments], nil], CLI.command("/usr/bin/az", arguments, windows: false)
    assert_equal [["/opt/tools/az.cmd", *arguments], nil], CLI.command("/opt/tools/az.cmd", arguments, windows: false)
  end

  def test_locate_searches_only_absolute_path_entries_and_honors_pathext_on_windows
    if Gem.win_platform?
      assert_equal "#{FAKE_AZ}/az.cmd", CLI.locate(FAKE_AZ, pathext: ".COM;.EXE;.BAT;.CMD", windows: true)
      assert_equal "#{FAKE_AZ}/az.cmd", CLI.locate("relative-dir;#{FAKE_AZ}", pathext: "", windows: true), "relative entries are skipped; default extensions"
      assert_nil CLI.locate("relative-dir;#{File.expand_path("nowhere", __dir__)}", pathext: ".EXE", windows: true)
      assert_nil CLI.locate(FAKE_AZ, pathext: ".EXE;.COM", windows: true), "extensions missing from PATHEXT are not tried"
    else
      File.chmod(0o755, File.join(FAKE_AZ, "az"))
      assert_equal "#{FAKE_AZ}/az", CLI.locate("relative-dir:#{FAKE_AZ}", windows: false)
      assert_nil CLI.locate("relative-dir", windows: false), "relative entries are skipped"
    end
  end

  def test_real_process_launch_the_fixture_cli_receives_exactly_the_fixed_arguments_and_its_status_is_returned
    File.chmod(0o755, File.join(FAKE_AZ, "az")) unless Gem.win_platform?
    run = ->(arguments) { CLI.run(arguments, FAKE_AZ) }

    exit_status, stdout = with_env("FAKE_AZ_MODE" => "args") { run.call([*TOKEN_ARGUMENTS, "--tenant", "tenant-1.example"]) }
    assert_equal 0, exit_status
    assert_equal "account get-access-token --scope #{SCOPE} --output json --tenant tenant-1.example", JSON.parse(stdout)["accessToken"]

    assert_equal "fixture-cli-token", with_env("FAKE_AZ_MODE" => "ok") { CLI.provider(SCOPE, run: run).call }
    assert_equal 3, with_env("FAKE_AZ_MODE" => "fail") { run.call(TOKEN_ARGUMENTS).first }
    message = with_env("FAKE_AZ_MODE" => "empty") { failure_message(CLI.provider(SCOPE, run: run)) }
    assert_equal "Azure CLI response has no usable accessToken.", message
  end
end
