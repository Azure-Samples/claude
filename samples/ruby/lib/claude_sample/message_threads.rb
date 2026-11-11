# frozen_string_literal: true

require_relative "sample"

module ClaudeSample
  module MessageThreads
    SYSTEM = "Keep replies short."
    FIRST_PROMPT = "Remember the code ORCHID-47. Reply with OK."
    SECOND_PROMPT = "What code did I ask you to remember? Reply with only the code."
    USAGE = "Usage: ruby message_threads.rb\n"

    class << self
      # @param argv [Array<String>] command-line arguments
      # @param env [Hash{String=>String}]
      # @param run_cli [#call, nil] Azure CLI process override (tests)
      # @return [Integer] the exit status
      def run(argv, env, stdout, stderr, run_cli: nil)
        argv.each do |argument|
          case argument
          when "-h", "--help"
            stdout.write(USAGE)
            return 0
          else
            stderr.write("Unknown argument: #{argument}\n#{USAGE}")
            return 2
          end
        end

        begin
          client, model = Sample.configure(env, run_cli)
          converse(client, model, stdout)
          0
        rescue StandardError => e
          stderr.write("Error: #{Sample.describe(e)}\n")
          1
        end
      end

      # @param client [Anthropic::Client] a standard client, however it was built
      # @param model [String] the model or deployment name
      # @raise [RuntimeError] if the second reply has no text
      def converse(client, model, stdout)
        thread = client.beta.messages.thread(model: model, max_tokens: Sample::MAX_TOKENS, system_: SYSTEM)
        thread.send_message({role: "user", content: FIRST_PROMPT})
        reply = thread.send_message({role: "user", content: SECOND_PROMPT})

        texts = reply.content.filter_map { |block| block.text if block.type == :text && !block.text.strip.empty? }
        raise Sample.no_text(reply.stop_reason) if texts.empty?

        texts.each { |text| stdout.write("#{text}\n") }
      end
    end
  end
end
