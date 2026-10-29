# frozen_string_literal: true

# Every gem, Minitest included, comes from the Gemfile (`bundle install`), wherever Bundler put it.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "minitest/autorun"
require "json"
require "socket"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "claude_sample/sample"

MODEL = "sample-deployment"

def message_body(text = "OK")
  {
    "id" => "msg_test", "type" => "message", "role" => "assistant", "model" => MODEL,
    "content" => [{"type" => "text", "text" => text}],
    "stop_reason" => "end_turn", "stop_sequence" => nil,
    "usage" => {"input_tokens" => 1, "output_tokens" => 2}
  }
end

def error_body(type, message)
  {"type" => "error", "error" => {"type" => type, "message" => message}}
end

# A Server-Sent Events body: one text block streamed as the given chunks.
def sse_body(chunks, input: 5, output: 7)
  events = [
    ["message_start", {"type" => "message_start", "message" => {
      "id" => "msg_stream", "type" => "message", "role" => "assistant", "model" => MODEL, "content" => [],
      "stop_reason" => nil, "stop_sequence" => nil, "usage" => {"input_tokens" => input, "output_tokens" => 1}
    }}],
    ["content_block_start", {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "text", "text" => ""}}]
  ]
  chunks.each do |chunk|
    events << ["content_block_delta", {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => chunk}}]
  end
  events << ["content_block_stop", {"type" => "content_block_stop", "index" => 0}]
  events << ["message_delta", {"type" => "message_delta", "delta" => {"stop_reason" => "end_turn", "stop_sequence" => nil},
                               "usage" => {"output_tokens" => output}}]
  events << ["message_stop", {"type" => "message_stop"}]
  events.map { |type, payload| "event: #{type}\ndata: #{JSON.generate(payload)}\n\n" }.join
end

# A real HTTP server on a loopback port: the SDK's own Net::HTTP transport talks to it, so the tests see the bytes the
# SDK actually sends. The responder returns [status, headers, body] for each request.
class LoopbackServer
  Request = Struct.new(:verb, :path, :headers, :body) do
    # Header values by lower-case name; a header sent twice has two values.
    def header(name) = headers[name.downcase]&.join(", ")

    def json = JSON.parse(body)

    # Everything the request shows on the wire, for canary searches.
    def wire = JSON.generate([verb, path, headers, body])
  end

  REASONS = {200 => "OK", 302 => "Found", 307 => "Temporary Redirect"}.freeze

  attr_reader :requests, :port

  def self.json_response(body, status = 200, headers = {})
    [status, {"content-type" => "application/json"}.merge(headers), JSON.generate(body)]
  end

  def initialize(&responder)
    @responder = responder || ->(_request, _count) { LoopbackServer.json_response(message_body) }
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def base_url(path = "/anthropic") = "http://127.0.0.1:#{port}#{path}"

  def close
    @server.close
    @thread.join(5)
  end

  private

  def serve
    loop { handle(@server.accept) }
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(socket)
    verb, path, = socket.gets.to_s.split(" ")
    return if verb.nil?

    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.chomp.split(":", 2)
      (headers[name.downcase] ||= []) << value.to_s.strip
    end
    request = Request.new(verb, path, headers, read_body(socket, headers))
    @requests << request
    status, response_headers, body = @responder.call(request, @requests.length)
    head = +"HTTP/1.1 #{status} #{REASONS.fetch(status, "Status")}\r\n"
    response_headers.each { |name, value| head << "#{name}: #{value}\r\n" }
    socket.write("#{head}content-length: #{body.bytesize}\r\nconnection: close\r\n\r\n#{body}")
  rescue Errno::ECONNRESET, Errno::EPIPE
    nil
  ensure
    socket.close
  end

  def read_body(socket, headers)
    if headers["transfer-encoding"]&.join&.include?("chunked")
      body = +""
      while (size = socket.gets.to_s.to_i(16)).positive?
        body << socket.read(size)
        socket.gets
      end
      socket.gets
      body
    else
      socket.read(headers.fetch("content-length", ["0"]).first.to_i).to_s
    end
  end
end

module EnvHelper
  MANAGED = /\A(?:ANTHROPIC_|CLAUDE_|AZURE_|FAKE_AZ_|AUTH_MODE\z|API_KEY_HEADER\z|TOKEN_SCOPE\z)/

  # Runs the block with exactly the ANTHROPIC_*, CLAUDE_*, AZURE_*, AUTH_MODE, API_KEY_HEADER, TOKEN_SCOPE and
  # FAKE_AZ_* variables in set, and restores the previous environment afterwards.
  def with_env(set = {})
    saved = ENV.to_h
    ENV.keys.grep(MANAGED).each { |name| ENV.delete(name) }
    ENV["ANTHROPIC_CONFIG_DIR"] = File.expand_path("no-profile-here", __dir__)
    set.each { |name, value| ENV[name] = value }
    yield
  ensure
    ENV.replace(saved)
  end
end
