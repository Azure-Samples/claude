# frozen_string_literal: true

require "json"
require "open3"

module ClaudeSample
  # A token provider for local development that asks a command-line tool for the current token. The one built-in
  # tool is the Azure CLI, used as a documented fallback; production code passes its own provider to ClientFactory.
  #
  # Every token request starts `az account get-access-token --scope <scope> --output json`. The CLI owns token caching
  # and renewal, so the price is one CLI process per request and this module keeps no cache of its own. Production code
  # should give ClientFactory a token provider backed by its own identity library instead.
  #
  # The command is a fixed argument list, never shell text. Every argument is checked against a short allowlist, which
  # also keeps cmd.exe metacharacters out when the CLI is a Windows batch file (az.cmd / az.bat).
  #
  # Each CLI process gets a finite allowance (60 seconds: a cold start under load can exceed 10). When it runs out the
  # process (and, on Windows, its children) is stopped and the call fails; there is no fallback to another credential.
  module CliTokenProvider
    TIMEOUT_SECONDS = 60.0
    # Letters, digits and . _ : / - only: no quotes, spaces, or shell and cmd.exe metacharacters.
    SAFE_ARGUMENT = %r{\A[A-Za-z0-9._:/-]+\z}
    TENANT = /\A[A-Za-z0-9.-]+\z/
    VISIBLE_ASCII = /\A[\x21-\x7E]+\z/
    EXTENSIONS = %w[.com .exe .bat .cmd].freeze

    class << self
      # @param run [#call, nil] replaces the process launch: receives the arguments after `az`, returns [exit status, stdout]
      # @param timeout [Float, nil] seconds each CLI process may take; nil means TIMEOUT_SECONDS
      # @return [Proc] returns an access token string; every call starts the CLI
      def provider(scope, tenant_id = nil, run: nil, timeout: nil)
        arguments = ["account", "get-access-token", "--scope", safe!(scope, "The token scope"), "--output", "json"]
        unless tenant_id.nil? || tenant_id.empty?
          raise ArgumentError, 'The tenant ID may only contain letters, digits, "." and "-".' unless TENANT.match?(tenant_id)

          arguments.push("--tenant", tenant_id)
        end
        run ||= ->(args) { self.run(args, nil, timeout: timeout) }

        lambda do
          exit_status, stdout = run.call(arguments)
          unless exit_status.zero?
            raise "Azure CLI exited with code #{exit_status} while requesting a token for scope #{scope}. " \
                  'Run "az login" and retry, or supply your own token provider.'
          end

          payload = begin
            JSON.parse(stdout)
          rescue JSON::ParserError
            nil
          end
          raise "Azure CLI returned output that is not a JSON object." unless payload.is_a?(Hash)

          token = payload["accessToken"]
          raise "Azure CLI response has no usable accessToken." unless token.is_a?(String) && VISIBLE_ASCII.match?(token)

          token
        end
      end

      # Starts the Azure CLI found on search_path (default: PATH) and returns [exit status, stdout]. stderr is discarded.
      # A CLI that is still running after timeout seconds (default TIMEOUT_SECONDS) is stopped and the call raises.
      #
      # @param arguments [Array<String>]
      # @return [Array(Integer, String)]
      def run(arguments, search_path = nil, timeout: nil)
        timeout ||= TIMEOUT_SECONDS
        arguments.each { |argument| safe!(argument, "Azure CLI arguments") }
        windows = Gem.win_platform?
        executable = locate(search_path || ENV.fetch("PATH", ""), windows: windows)
        raise 'Azure CLI ("az") was not found on PATH. Install it and run "az login", or supply your own token provider.' if executable.nil?

        argv, directory = command(executable, arguments, windows: windows)
        options = {}
        options[:chdir] = directory if directory
        Open3.popen3(*argv, **options) do |stdin, stdout, stderr, waiter|
          stdin.close
          discard = Thread.new { stderr.read } # drained and dropped, so the CLI never blocks on it
          output = +""
          reader = Thread.new do
            loop { output << stdout.readpartial(16_384) }
          rescue EOFError, IOError
            nil
          end
          unless waiter.join(timeout)
            stop(waiter.pid, windows)
            reader.kill
            discard.kill
            raise "Azure CLI did not finish within its #{timeout.round(1).to_s.delete_suffix(".0")} second allowance and was stopped; " \
                  'try "az account get-access-token --output none" by hand, or supply your own token provider.'
          end
          reader.join(1) # whatever the finished process left in the pipe
          reader.kill
          discard.kill
          [waiter.value.exitstatus || 1, output.force_encoding(Encoding::UTF_8)]
        end
      rescue SystemCallError
        raise "Azure CLI could not be started."
      end

      # Finds `az` in the absolute directories of search_path. On Windows it honors PATHEXT, limited to .com, .exe, .bat and .cmd.
      def locate(search_path, pathext: nil, windows: Gem.win_platform?)
        names = ["az"]
        if windows
          extensions = (pathext || ENV.fetch("PATHEXT", "")).split(";").map(&:downcase).select { |extension| EXTENSIONS.include?(extension) }
          names = (extensions.empty? ? EXTENSIONS : extensions).map { |extension| "az#{extension}" }
        end
        search_path.split(windows ? ";" : ":").each do |directory|
          directory = directory.strip.delete('"')
          absolute = windows ? directory.match?(%r{\A(?:[A-Za-z]:[\\/]|\\\\)}) : directory.start_with?("/")
          next unless absolute

          names.each do |name|
            candidate = File.join(directory, name)
            return candidate if File.file?(candidate) && (windows || File.executable?(candidate))
          end
        end
        nil
      end

      # Builds the argument list and working directory for one launch.
      #
      # A Windows batch file can only run under cmd.exe. It is started by bare file name from its own directory, so a
      # path with spaces or parentheses needs no quoting; /d skips AutoRun commands. Arguments are allowlisted by run.
      #
      # @return [Array(Array<String>, String, nil)] argv and working directory
      def command(executable, arguments, windows:, interpreter: nil)
        if windows && executable.match?(/\.(?:bat|cmd)\z/i)
          return [[interpreter || command_interpreter, "/d", "/c", File.basename(executable), *arguments], File.dirname(executable)]
        end

        [[executable, *arguments], nil]
      end

      private

      # Stops the CLI; on Windows also its children (az.cmd runs the CLI as a child of cmd.exe).
      def stop(pid, windows)
        if windows
          taskkill = File.join(ENV.fetch("SystemRoot", "C:\\Windows"), "System32", "taskkill.exe")
          system(taskkill, "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
        end
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end

      def command_interpreter
        configured = ENV.fetch("ComSpec", "")
        return configured if File.basename(configured).casecmp?("cmd.exe") && File.file?(configured)

        File.join(ENV.fetch("SystemRoot", "C:\\Windows"), "System32", "cmd.exe")
      end

      def safe!(value, what)
        return value if value.is_a?(String) && SAFE_ARGUMENT.match?(value)

        raise ArgumentError, "#{what} may only contain letters, digits and the characters . _ : / -"
      end
    end
  end
end
