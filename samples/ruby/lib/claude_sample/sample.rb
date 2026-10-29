# frozen_string_literal: true

require_relative "cli_token_provider"
require_relative "client_factory"

module ClaudeSample
  # The command-line sample: one Messages call, printed whole or streamed (--stream).
  #
  # All configuration comes from the environment passed to run, in one of two profiles that never borrow from each other:
  # ANTHROPIC_BASE_URL selects the canonical profile (ANTHROPIC_MODEL, ANTHROPIC_API_KEY; AUTH_MODE must be set
  # explicitly), otherwise CLAUDE_BASE_URL selects the legacy one (CLAUDE_DEPLOYMENT_NAME, CLAUDE_API_KEY; AUTH_MODE
  # defaults to bearer). The bearer credential is an Azure CLI token, a local-development fallback.
  module Sample
    PROMPT = "What are 3 things to visit in Seattle?"
    MAX_TOKENS = 1024
    DEFAULT_TOKEN_SCOPE = "https://ai.azure.com/.default"

    # Application policy of this sample, passed to the factory explicitly: the factory itself keeps the SDK default.
    REQUEST_TIMEOUT_SECONDS = 120.0
    USAGE = "Usage: ruby main.rb [--stream]\n"

    class << self
      # @param argv [Array<String>] command-line arguments
      # @param env [Hash{String=>String}]
      # @param run_cli [#call, nil] Azure CLI process override (tests)
      # @return [Integer] the exit status
      def run(argv, env, stdout, stderr, run_cli: nil)
        stream = false
        argv.each do |argument|
          case argument
          when "--stream"
            stream = true
          when "-h", "--help"
            stdout.write(USAGE)
            return 0
          else
            stderr.write("Unknown argument: #{argument}\n#{USAGE}")
            return 2
          end
        end

        begin
          client, model = configure(env, run_cli)
          stream ? stream_message(client, model, stdout) : message(client, model, stdout)
          0
        rescue StandardError => e
          stderr.write("Error: #{describe(e)}\n")
          1
        end
      end

      # Builds the client and returns it with the model name.
      #
      # ANTHROPIC_BASE_URL selects the canonical profile: ANTHROPIC_MODEL and, for an API key, ANTHROPIC_API_KEY. AUTH_MODE
      # must be set explicitly (api_key or bearer), so an ambient native endpoint and key can never silently receive an
      # Azure token, nor an ambient Azure setup a native key. Otherwise CLAUDE_BASE_URL selects the legacy profile:
      # CLAUDE_DEPLOYMENT_NAME and CLAUDE_API_KEY, with AUTH_MODE defaulting to bearer. A profile never falls back to the
      # other one's model or key, so a secret can never be paired with the endpoint of the other family.
      #
      # @return [Array(Anthropic::Client, String)]
      def configure(env, run_cli = nil)
        if setting(env, "ANTHROPIC_BASE_URL")
          base_url = setting(env, "ANTHROPIC_BASE_URL")
          model = setting(env, "ANTHROPIC_MODEL")
          key_name = "ANTHROPIC_API_KEY"
          default_mode = nil
          missing_model = "ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings: also set ANTHROPIC_MODEL (CLAUDE_DEPLOYMENT_NAME is not used with it)."
          missing_key = "Set ANTHROPIC_API_KEY (CLAUDE_API_KEY is not used with ANTHROPIC_BASE_URL)."
        else
          base_url = setting(env, "CLAUDE_BASE_URL")
          model = setting(env, "CLAUDE_DEPLOYMENT_NAME")
          key_name = "CLAUDE_API_KEY"
          default_mode = "bearer"
          missing_model = "CLAUDE_BASE_URL selects the CLAUDE_* settings: also set CLAUDE_DEPLOYMENT_NAME (ANTHROPIC_MODEL is not used with it)."
          missing_key = "Set CLAUDE_API_KEY (ANTHROPIC_API_KEY is not used with CLAUDE_BASE_URL)."
        end
        if base_url.nil?
          raise ArgumentError, "Set CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME, or ANTHROPIC_BASE_URL and ANTHROPIC_MODEL. The two sets are never mixed."
        end
        raise ArgumentError, missing_model if model.nil?

        mode = setting(env, "AUTH_MODE") || default_mode
        if mode.nil?
          raise ArgumentError, "ANTHROPIC_BASE_URL selects the ANTHROPIC_* settings and requires an explicit AUTH_MODE: " \
                               "set AUTH_MODE=api_key (uses ANTHROPIC_API_KEY) or AUTH_MODE=bearer (uses an Azure CLI token)."
        end

        token_provider = nil
        api_key = nil
        case mode
        when "bearer"
          # The selector is shared with the other language samples. Only the Azure CLI is built in here, so any other
          # explicit choice is refused rather than silently answered with the CLI.
          selector = setting(env, "AZURE_TOKEN_CREDENTIALS")
          if selector && selector != "AzureCliCredential"
            shown = selector.match?(/\A[A-Za-z0-9_.-]{1,64}\z/) ? selector : "(unprintable or too long)"
            raise ArgumentError, "AZURE_TOKEN_CREDENTIALS=#{shown} is not supported: the Azure CLI (AzureCliCredential) is this sample's " \
                                 "only built-in token source. Unset it, or pass your own token provider to ClientFactory for other credentials."
          end
          token_provider = CliTokenProvider.provider(
            setting(env, "TOKEN_SCOPE") || DEFAULT_TOKEN_SCOPE, setting(env, "AZURE_TENANT_ID"), run: run_cli
          )
        when "api_key"
          api_key = setting(env, key_name) || raise(ArgumentError, missing_key)
        else
          raise ArgumentError, "AUTH_MODE must be bearer or api_key."
        end

        client = ClientFactory.create_client(
          base_url: base_url,
          token_provider: token_provider,
          api_key: api_key,
          key_header: setting(env, "API_KEY_HEADER") || "Authorization",
          api_version: setting(env, "ANTHROPIC_API_VERSION"),
          timeout: REQUEST_TIMEOUT_SECONDS
        )
        [client, model]
      end

      private

      def message(client, model, stdout)
        message = client.messages.create(
          max_tokens: MAX_TOKENS, messages: [{role: "user", content: PROMPT}], model: model
        )
        texts = message.content.filter_map { |block| block.text if block.type == :text && !block.text.strip.empty? }
        raise no_text(message.stop_reason) if texts.empty?

        texts.each { |text| stdout.write("#{text}\n") }
        stdout.write("\n[usage] input=#{message.usage.input_tokens} output=#{message.usage.output_tokens}\n")
      end

      def stream_message(client, model, stdout)
        events = client.messages.stream(
          max_tokens: MAX_TOKENS, messages: [{role: "user", content: PROMPT}], model: model
        )
        printed = false
        input = 0
        output = 0
        stop_reason = nil
        events.each do |event|
          case event.type
          when :message_start
            input = event.message.usage.input_tokens
            output = event.message.usage.output_tokens
          when :text
            stdout.write(event.text)
            stdout.flush
            printed ||= !event.text.strip.empty?
          when :message_delta
            input = event.usage.input_tokens || input
            output = event.usage.output_tokens
            stop_reason = event.delta.stop_reason
          end
        end
        raise no_text(stop_reason) unless printed

        stdout.write("\n\n[usage] input=#{input} output=#{output}\n")
      end

      def no_text(stop_reason)
        "No text response (stop_reason=#{stop_reason || "none"}). Increase max_tokens if the response exhausted its budget."
      end

      def describe(error)
        own = error.instance_of?(ArgumentError) || error.instance_of?(RuntimeError)
        own ? error.message : "#{error.class.name.split("::").last}: #{error.message}"
      end

      # The first of names that is set and not empty.
      def setting(env, *names)
        names.each do |name|
          value = env[name]
          return value unless value.nil? || value.empty?
        end
        nil
      end
    end
  end
end
