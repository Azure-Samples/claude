# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "claude_sample/message_threads"

class MessageThreadsTest < Minitest::Test
  include EnvHelper

  BETA = "message-threads-2026-08-12"
  FIRST = {"role" => "user", "content" => ClaudeSample::MessageThreads::FIRST_PROMPT}
  SECOND = {"role" => "user", "content" => ClaudeSample::MessageThreads::SECOND_PROMPT}

  def with_replies(*replies)
    server = LoopbackServer.new { |_request, count| replies.fetch(count - 1) }
    yield server
  ensure
    server&.close
  end

  def client(server)
    ClaudeSample::ClientFactory.create_client(
      base_url: server.base_url, token_provider: -> { "test-token" }, max_retries: 0
    )
  end

  def response(text = "OK")
    LoopbackServer.json_response(message_body(text))
  end

  def failure(status, code)
    body = error_body(status == 404 ? "not_found_error" : "invalid_request_error", "canary-error-body")
    body["error"]["details"] = {"error_code" => code}
    LoopbackServer.json_response(body, status)
  end

  def test_create_and_continue_send_only_the_new_turn
    with_env do
      with_replies(response, response("ORCHID-47")) do |server|
        output = StringIO.new
        ClaudeSample::MessageThreads.converse(client(server), MODEL, output)
        assert_equal "ORCHID-47\n", output.string
        assert_equal 2, server.requests.length
        server.requests.each do |request|
          assert_equal "POST", request.verb
          assert_equal "/anthropic/v1/messages", request.path.split("?").first
          assert_equal BETA, request.header("anthropic-beta")
          assert_equal "Bearer test-token", request.header("authorization")
          assert_equal MODEL, request.json["model"]
          assert_equal 1024, request.json["max_tokens"]
        end
        first, second = server.requests.map(&:json)
        assert_equal({"type" => "create"}, first["thread"])
        assert_equal "Keep replies short.", first["system"]
        assert_equal [FIRST], first["messages"]
        assert_equal({"type" => "continue", "previous_message_id" => "msg_test"}, second["thread"])
        assert_equal [SECOND], second["messages"]
        refute second.key?("system")
        refute second.key?("tools")
      end
    end
  end

  def test_expired_thread_replays_the_whole_conversation
    with_env do
      with_replies(response, failure(404, "thread_not_found"), response("ORCHID-47")) do |server|
        ClaudeSample::MessageThreads.converse(client(server), MODEL, StringIO.new)
        assert_equal 3, server.requests.length
        replay = server.requests.last.json
        assert_equal({"type" => "create"}, replay["thread"])
        assert_equal "Keep replies short.", replay["system"]
        assert_equal [FIRST, {"role" => "assistant", "content" => message_body["content"]}, SECOND], replay["messages"]
        assert server.requests.all? { |request| request.header("anthropic-beta") == BETA }
      end
    end
  end

  def test_other_errors_do_not_replay_or_continue_unthreaded
    [[404, "model_not_found"], [400, "thread_unsupported_request"]].each do |status, code|
      with_env do
        with_replies(response, failure(status, code)) do |server|
          assert_raises(Anthropic::Errors::APIStatusError) do
            ClaudeSample::MessageThreads.converse(client(server), MODEL, StringIO.new)
          end
          assert_equal 2, server.requests.length
        end
      end
    end
  end

  def test_blank_or_thinking_only_reply_fails
    [[], [{"type" => "text", "text" => " \n "}], [{"type" => "thinking", "thinking" => "hidden", "signature" => "test"}]].each do |content|
      body = message_body
      body["content"] = content
      with_env do
        with_replies(response, LoopbackServer.json_response(body)) do |server|
          output = StringIO.new
          assert_raises(RuntimeError) { ClaudeSample::MessageThreads.converse(client(server), MODEL, output) }
          assert_equal "", output.string
        end
      end
    end
  end

  def test_usage_and_configuration_errors
    output, error = StringIO.new, StringIO.new
    assert_equal 0, ClaudeSample::MessageThreads.run(["--help"], {}, output, error)
    assert_equal 2, ClaudeSample::MessageThreads.run(["--stream"], {}, output, error)
    assert_equal 1, ClaudeSample::MessageThreads.run([], {}, output, error)
    assert_includes error.string, "CLAUDE_BASE_URL"
  end
end
