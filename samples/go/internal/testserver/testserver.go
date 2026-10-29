// Package testserver provides loopback servers and fixtures for the sample's offline tests.
package testserver

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
)

// Request is one request as the server saw it.
type Request struct {
	Method string
	URL    string
	Header http.Header
	Body   string
}

// Handler answers a request; count is the number of requests received so far, including this one.
type Handler func(w http.ResponseWriter, r *http.Request, count int)

// Server records every request before running its handler.
type Server struct {
	*httptest.Server
	mu       sync.Mutex
	requests []Request
}

// New starts a loopback HTTP server that is closed when the test ends.
func New(t testing.TB, handler Handler) *Server {
	t.Helper()
	s := &Server{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.requests = append(s.requests, Request{Method: r.Method, URL: r.URL.RequestURI(), Header: r.Header.Clone(), Body: string(body)})
		count := len(s.requests)
		s.mu.Unlock()
		handler(w, r, count)
	}))
	t.Cleanup(func() {
		s.CloseClientConnections()
		s.Close()
	})
	return s
}

// Requests returns a copy of the recorded requests.
func (s *Server) Requests() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Request(nil), s.requests...)
}

// Count is the number of requests received.
func (s *Server) Count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.requests)
}

// ThinkingBlock is a content block the samples must never print.
const ThinkingBlock = `{"type":"thinking","thinking":"not for display","signature":"sample"}`

// TextBlock is a text content block.
func TextBlock(text string) string {
	return fmt.Sprintf(`{"type":"text","text":%q}`, text)
}

// Message builds a Messages API response with the given JSON content blocks.
func Message(stopReason string, blocks ...string) string {
	return fmt.Sprintf(`{"id":"msg_test","type":"message","role":"assistant","model":"claude-test","content":[%s],"stop_reason":%q,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":2}}`,
		strings.Join(blocks, ","), stopReason)
}

// OKMessage is a reply with the text "OK".
var OKMessage = Message("end_turn", TextBlock("OK"))

// JSON answers with a JSON body.
func JSON(status int, body string, headers ...string) Handler {
	return func(w http.ResponseWriter, _ *http.Request, _ int) {
		w.Header().Set("Content-Type", "application/json")
		for i := 0; i+1 < len(headers); i += 2 {
			w.Header().Set(headers[i], headers[i+1])
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}
}

// Respond answers 200 with the given message.
func Respond(message string) Handler { return JSON(http.StatusOK, message) }

// Error answers with an API error of the given status.
func Error(status int, headers ...string) Handler {
	return JSON(status, `{"type":"error","error":{"type":"api_error","message":"test failure"}}`, headers...)
}

// Hang never answers; it returns when the client gives up.
func Hang(_ http.ResponseWriter, r *http.Request, _ int) { <-r.Context().Done() }

// Redirect answers with a redirect to location.
func Redirect(status int, location string) Handler {
	return func(w http.ResponseWriter, _ *http.Request, _ int) {
		w.Header().Set("Location", location)
		w.WriteHeader(status)
	}
}

// Block is one streamed content block: Kind is "text" or "thinking".
type Block struct{ Kind, Text string }

// EventStream builds a Messages API event stream for the blocks.
func EventStream(blocks ...Block) string {
	var b strings.Builder
	event := func(name, data string) { fmt.Fprintf(&b, "event: %s\ndata: %s\n\n", name, data) }
	event("message_start", `{"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","model":"claude-test","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}`)
	for i, block := range blocks {
		if block.Kind == "text" {
			event("content_block_start", fmt.Sprintf(`{"type":"content_block_start","index":%d,"content_block":{"type":"text","text":""}}`, i))
			event("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":{"type":"text_delta","text":%q}}`, i, block.Text))
		} else {
			event("content_block_start", fmt.Sprintf(`{"type":"content_block_start","index":%d,"content_block":{"type":"thinking","thinking":"","signature":""}}`, i))
			event("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":{"type":"thinking_delta","thinking":%q}}`, i, block.Text))
		}
		event("content_block_stop", fmt.Sprintf(`{"type":"content_block_stop","index":%d}`, i))
	}
	event("message_delta", `{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}`)
	event("message_stop", `{"type":"message_stop"}`)
	return b.String()
}

// Stream answers with an event stream for the blocks.
func Stream(blocks ...Block) Handler {
	return func(w http.ResponseWriter, _ *http.Request, _ int) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, EventStream(blocks...))
	}
}

var ambientPrefixes = []string{"ANTHROPIC_", "CLAUDE_", "AZURE_"}
var ambientNames = []string{"AUTH_MODE", "API_KEY_HEADER", "TOKEN_SCOPE"}

// CleanEnvironment removes every variable the SDK or the samples read for this test.
func CleanEnvironment(t testing.TB) {
	t.Helper()
	for _, entry := range os.Environ() {
		name, value, _ := strings.Cut(entry, "=")
		ambient := false
		for _, n := range ambientNames {
			ambient = ambient || n == name
		}
		for _, p := range ambientPrefixes {
			ambient = ambient || strings.HasPrefix(name, p)
		}
		if ambient {
			_ = os.Unsetenv(name)
			t.Cleanup(func() { _ = os.Setenv(name, value) })
		}
	}
}
