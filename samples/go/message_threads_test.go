package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Azure-Samples/claude/samples/go/internal/testserver"
)

const (
	threadsBeta        = "message-threads-2026-08-12"
	threadNotFoundBody = `{"type":"error","error":{"type":"not_found_error","message":"test failure","details":{"error_code":"thread_not_found"}}}`
	wantFirstTurn      = "user: Remember the code ORCHID-47. Reply with OK."
	wantSecondTurn     = "user: What code did I ask you to remember? Reply with only the code."
	createThread       = `{"type":"create"}`
	continueThread     = `{"previous_message_id":"msg_first","type":"continue"}`
	keepRepliesShort   = `[{"text":"Keep replies short.","type":"text"}]`
)

var (
	firstReply  = testserver.Respond(threadMessage("msg_first", "OK"))
	secondReply = testserver.Respond(threadMessage("msg_second", "ORCHID-47"))
)

func threadMessage(id, text string) string {
	return fmt.Sprintf(`{"id":%q,"type":"message","role":"assistant","model":"claude-test","content":[%s],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":2}}`, id, testserver.TextBlock(text))
}

// script answers the nth request with the nth handler.
func script(handlers ...testserver.Handler) testserver.Handler {
	return func(w http.ResponseWriter, r *http.Request, count int) {
		handlers[min(count, len(handlers))-1](w, r, count)
	}
}

// threadRequest is a request body: its top-level fields and its messages as "role: text" lines.
type threadRequest struct {
	fields   map[string]any
	messages []string
}

func parseThreadRequest(t *testing.T, r testserver.Request) threadRequest {
	t.Helper()
	request := threadRequest{}
	if err := json.Unmarshal([]byte(r.Body), &request.fields); err != nil {
		t.Fatalf("request body %q: %v", r.Body, err)
	}
	messages, _ := request.fields["messages"].([]any)
	for _, m := range messages {
		message, _ := m.(map[string]any)
		blocks, _ := message["content"].([]any)
		for _, b := range blocks {
			block, _ := b.(map[string]any)
			request.messages = append(request.messages, fmt.Sprintf("%v: %v", message["role"], block["text"]))
		}
	}
	return request
}

// field returns a top-level field as JSON with sorted keys, or "" when it is absent (null counts as present).
func (r threadRequest) field(name string) string {
	value, ok := r.fields[name]
	if !ok {
		return ""
	}
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func TestThreadsCreateThenContinueWithOnlyTheNewMessage(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, script(firstReply, secondReply))
	var out output

	if code := out.run([]string{"-threads"}, sampleEnv(server, nil), runOptions{}); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}

	if out.stdout.String() != "ORCHID-47\n" || out.stderr.Len() != 0 {
		t.Errorf("stdout %q, stderr %q", out.stdout.String(), out.stderr.String())
	}
	requests := server.Requests()
	if len(requests) != 2 {
		t.Fatalf("got %d requests", len(requests))
	}
	for i, r := range requests {
		request := parseThreadRequest(t, r)
		if r.Method != http.MethodPost || !strings.HasPrefix(r.URL, "/anthropic/v1/messages") || r.Header.Get("Anthropic-Beta") != threadsBeta {
			t.Errorf("request %d: %s %s, anthropic-beta %q", i, r.Method, r.URL, r.Header.Get("Anthropic-Beta"))
		}
		if request.field("model") != `"sample-deployment"` || request.field("max_tokens") != "1024" || request.field("tools") != "" {
			t.Errorf("request %d: body %s", i, r.Body)
		}
	}
	create, next := parseThreadRequest(t, requests[0]), parseThreadRequest(t, requests[1])
	if create.field("thread") != createThread || create.field("system") != keepRepliesShort || !reflect.DeepEqual(create.messages, []string{wantFirstTurn}) {
		t.Errorf("create request = %s", requests[0].Body)
	}
	if next.field("thread") != continueThread || next.field("system") != "" || !reflect.DeepEqual(next.messages, []string{wantSecondTurn}) {
		t.Errorf("continue request = %s", requests[1].Body)
	}
}

func TestThreadsUseTheExistingBearerAuthenticationOnBothTurns(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, script(firstReply, secondReply))
	var calls atomic.Int32
	options := runOptions{clientOverrides: clientOverrides{tokenProvider: func(context.Context) (string, error) {
		return fmt.Sprintf("entra-test-token-%d", calls.Add(1)), nil
	}}}
	var out output

	code := out.run([]string{"-threads"}, map[string]string{"ANTHROPIC_BASE_URL": server.URL, "ANTHROPIC_MODEL": "sample-deployment", "AUTH_MODE": "bearer"}, options)

	if code != 0 || server.Count() != 2 {
		t.Fatalf("exit code %d, %d requests, stderr %q", code, server.Count(), out.stderr.String())
	}
	for i, r := range server.Requests() {
		if got, want := r.Header.Get("Authorization"), fmt.Sprintf("Bearer entra-test-token-%d", i+1); got != want || r.Header.Get("X-Api-Key") != "" || r.Header.Get("Anthropic-Beta") != threadsBeta {
			t.Errorf("request %d: headers %v", i, r.Header)
		}
	}
}

func TestThreadsReplayTheWholeConversationWhenTheThreadIsNotFound(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, script(firstReply, testserver.JSON(http.StatusNotFound, threadNotFoundBody), secondReply))
	var out output

	if code := out.run([]string{"-threads"}, sampleEnv(server, nil), fastRetries()); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}

	if out.stdout.String() != "ORCHID-47\n" || out.stderr.Len() != 0 {
		t.Errorf("stdout %q, stderr %q", out.stdout.String(), out.stderr.String())
	}
	requests := server.Requests()
	if len(requests) != 3 {
		t.Fatalf("got %d requests", len(requests))
	}
	rejected, replay := parseThreadRequest(t, requests[1]), parseThreadRequest(t, requests[2])
	if rejected.field("thread") != continueThread || rejected.field("system") != "" {
		t.Errorf("rejected request = %s", requests[1].Body)
	}
	wantConversation := []string{wantFirstTurn, "assistant: OK", wantSecondTurn}
	if replay.field("thread") != createThread || replay.field("system") != keepRepliesShort || !reflect.DeepEqual(replay.messages, wantConversation) || requests[2].Header.Get("Anthropic-Beta") != threadsBeta {
		t.Errorf("replay request = %s", requests[2].Body)
	}
}

func TestThreadsDoNotReplayAnUnrelated404(t *testing.T) {
	testserver.CleanEnvironment(t)
	bodies := map[string]string{
		"no details":   `{"type":"error","error":{"type":"not_found_error","message":"test failure"}}`,
		"another code": `{"type":"error","error":{"type":"not_found_error","message":"test failure","details":{"error_code":"model_not_found"}}}`,
	}
	for name, body := range bodies {
		server := testserver.New(t, script(firstReply, testserver.JSON(http.StatusNotFound, body)))
		var out output

		code := out.run([]string{"-threads"}, sampleEnv(server, nil), fastRetries())

		if code != 1 || out.stdout.Len() != 0 || !strings.Contains(out.stderr.String(), "HTTP 404 (not_found_error)") || strings.Contains(out.stderr.String(), "model_not_found") {
			t.Errorf("%s: exit code %d, stdout %q, stderr %q", name, code, out.stdout.String(), out.stderr.String())
		}
		if server.Count() != 2 {
			t.Errorf("%s: got %d requests, want the rejected continue and no replay", name, server.Count())
		}
	}
}

func TestThreadFailuresAreReportedWithoutSecrets(t *testing.T) {
	testserver.CleanEnvironment(t)
	cases := []struct {
		name     string
		status   int
		handler  testserver.Handler
		requests int
	}{
		{"first turn", 401, testserver.Error(401), 1},
		{"second turn", 500, script(firstReply, testserver.Error(500)), 2},
	}
	for _, c := range cases {
		server := testserver.New(t, c.handler)
		var out output

		code := out.run([]string{"-threads"}, sampleEnv(server, nil), fastRetries())

		if want := fmt.Sprintf("HTTP %d (api_error)", c.status); code != 1 || !strings.Contains(out.stderr.String(), want) || out.stdout.Len() != 0 {
			t.Errorf("%s: exit code %d, stdout %q, stderr %q", c.name, code, out.stdout.String(), out.stderr.String())
		}
		for _, secret := range []string{"sample-key", server.URL, strings.TrimPrefix(server.URL, "http://"), "sample-deployment", "test failure"} {
			if strings.Contains(out.stderr.String(), secret) {
				t.Errorf("%s: %q leaked: %s", c.name, secret, out.stderr.String())
			}
		}
		if server.Count() != c.requests {
			t.Errorf("%s: got %d requests, want %d", c.name, server.Count(), c.requests)
		}
	}
}

func TestAThreadReplyWithoutTextExitsNonzero(t *testing.T) {
	testserver.CleanEnvironment(t)
	replies := map[string]string{
		"thinking only": thinkingOnly,
		"blank text":    testserver.Message("end_turn", testserver.TextBlock("  \n")),
	}
	for name, reply := range replies {
		server := testserver.New(t, script(firstReply, testserver.Respond(reply)))
		var out output

		code := out.run([]string{"-threads"}, sampleEnv(server, nil), runOptions{})

		if code != 1 || out.stdout.Len() != 0 || !strings.Contains(out.stderr.String(), "No text response (stop_reason=") {
			t.Errorf("%s: exit code %d, stdout %q, stderr %q", name, code, out.stdout.String(), out.stderr.String())
		}
	}
}

func TestThreadsTakeNoPromptAndDoNotCombineWithStream(t *testing.T) {
	for _, args := range [][]string{{"-threads", "-stream"}, {"-threads", "Say", "hi"}} {
		var out output

		if code := out.run(args, nil, runOptions{}); code != 2 || !strings.Contains(out.stderr.String(), "Usage: go run .") {
			t.Errorf("%v: exit code %d, stderr %q", args, code, out.stderr.String())
		}
	}
	var help output
	if code := help.run([]string{"-h"}, nil, runOptions{}); code != 0 || !strings.Contains(help.stdout.String(), "go run . -threads") {
		t.Errorf("help: exit code %d, stdout %q", code, help.stdout.String())
	}
}

func TestOnlyThreadsSendTheBetaHeader(t *testing.T) {
	testserver.CleanEnvironment(t)
	plain := testserver.New(t, testserver.Respond(textReply))
	streamed := testserver.New(t, testserver.Stream(testserver.Block{Kind: "text", Text: "Hello"}))
	var first, second output

	if code := first.run(nil, sampleEnv(plain, nil), runOptions{}); code != 0 {
		t.Fatalf("plain: exit code %d, stderr %q", code, first.stderr.String())
	}
	if code := second.run([]string{"-stream"}, sampleEnv(streamed, nil), runOptions{}); code != 0 {
		t.Fatalf("stream: exit code %d, stderr %q", code, second.stderr.String())
	}

	for _, server := range []*testserver.Server{plain, streamed} {
		r := server.Requests()[0]
		if r.Header.Get("Anthropic-Beta") != "" || strings.Contains(r.URL, "beta=") || strings.Contains(r.Body, `"thread"`) {
			t.Errorf("%s %v %s", r.URL, r.Header, r.Body)
		}
	}
}
