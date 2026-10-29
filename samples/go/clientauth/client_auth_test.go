package clientauth_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/anthropics/anthropic-sdk-go/v2/option"

	"github.com/Azure-Samples/claude/samples/go/clientauth"
	"github.com/Azure-Samples/claude/samples/go/internal/testserver"
)

func params() anthropic.MessageNewParams {
	return anthropic.MessageNewParams{
		Model:     "claude-test",
		MaxTokens: 32,
		Messages:  []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock("Hello"))},
	}
}

func retries(n int) *int { return &n }

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func newClient(t *testing.T, opts clientauth.Options) anthropic.Client {
	t.Helper()
	client, err := clientauth.CreateClient(opts)
	if err != nil {
		t.Fatalf("CreateClient: %v", err)
	}
	return client
}

func headerValues(r testserver.Request, name string) []string { return r.Header.Values(name) }

func requireAbsent(t *testing.T, r testserver.Request, names ...string) {
	t.Helper()
	for _, name := range names {
		if values := headerValues(r, name); len(values) != 0 {
			t.Errorf("header %s must be absent, got %q", name, values)
		}
	}
}

func requireClean(t *testing.T, requests []testserver.Request) {
	t.Helper()
	for _, r := range requests {
		for name, values := range r.Header {
			for _, value := range values {
				if strings.Contains(value, "oauth-2025-04-20") {
					t.Errorf("the OAuth beta must not be added: %s: %s", name, value)
				}
			}
		}
	}
}

func TestStockClientAndFreshTokenForEveryRequest(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	var calls atomic.Int32
	client := newClient(t, clientauth.Options{
		BaseURL: server.URL,
		TokenProvider: func(context.Context) (string, error) {
			return fmt.Sprintf("token-%d", calls.Add(1)), nil
		},
		MaxRetries: retries(0),
	})
	if calls.Load() != 0 {
		t.Fatal("the provider must not be called until a request is made")
	}

	for range 2 {
		if _, err := client.Messages.New(testContext(t), params()); err != nil {
			t.Fatalf("Messages.New: %v", err)
		}
	}

	requests := server.Requests()
	if len(requests) != 2 {
		t.Fatalf("got %d requests", len(requests))
	}
	for i, want := range []string{"Bearer token-1", "Bearer token-2"} {
		if got := requests[i].Header.Get("Authorization"); got != want {
			t.Errorf("request %d Authorization = %q, want %q", i, got, want)
		}
	}
	if requests[0].URL != "/v1/messages" {
		t.Errorf("path = %q", requests[0].URL)
	}
	if !strings.Contains(requests[0].Body, `"model":"claude-test"`) {
		t.Errorf("body = %s", requests[0].Body)
	}
	requireAbsent(t, requests[0], "Anthropic-Beta")
	requireClean(t, requests)
}

func TestBaseURLPathPrefix(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	for _, suffix := range []string{"/anthropic", "/anthropic/"} {
		client := newClient(t, clientauth.Options{
			BaseURL:       server.URL + suffix,
			TokenProvider: func(context.Context) (string, error) { return "token", nil },
			MaxRetries:    retries(0),
		})
		if _, err := client.Messages.New(testContext(t), params()); err != nil {
			t.Fatalf("Messages.New: %v", err)
		}
	}
	for i, r := range server.Requests() {
		if r.URL != "/anthropic/v1/messages" {
			t.Errorf("request %d path = %q", i, r.URL)
		}
	}
}

func TestAmbientAndPerCallCredentialsAreIgnored(t *testing.T) {
	testserver.CleanEnvironment(t)
	t.Setenv("ANTHROPIC_API_KEY", "ambient-key-canary")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "ambient-token-canary")
	t.Setenv("ANTHROPIC_PROFILE", "nonexistent-canary-profile")
	t.Setenv("ANTHROPIC_BASE_URL", "https://wrong.example")
	t.Setenv("ANTHROPIC_CUSTOM_HEADERS", "Authorization: Bearer custom-canary\nx-api-key: key-canary\napi-key: alias-canary\nx-note: ambient-header")
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))

	// Control: a plain SDK client under the same environment does send the ambient credentials and headers.
	stock := anthropic.NewClient(option.WithBaseURL(server.URL), option.WithMaxRetries(0))
	if _, err := stock.Messages.New(testContext(t), params()); err != nil {
		t.Fatalf("control request: %v", err)
	}
	control := fmt.Sprint(server.Requests()[0].Header)
	if !strings.Contains(control, "canary") {
		t.Fatalf("the canaries must be live, control headers: %s", control)
	}

	for _, mode := range []struct {
		name    string
		options clientauth.Options
		header  string
		want    string
	}{
		{"bearer", clientauth.Options{TokenProvider: func(context.Context) (string, error) { return "selected-token", nil }}, "Authorization", "Bearer selected-token"},
		{"x-api-key", clientauth.Options{APIKey: "selected-key", KeyHeader: "x-api-key"}, "X-Api-Key", "selected-key"},
	} {
		t.Run(mode.name, func(t *testing.T) {
			before := server.Count()
			mode.options.BaseURL = server.URL
			mode.options.MaxRetries = retries(0)
			client := newClient(t, mode.options)

			_, err := client.Messages.New(testContext(t), params(),
				option.WithHeader("Authorization", "Bearer request-canary"),
				option.WithHeader("X-Api-Key", "request-key-canary"),
				option.WithHeader("anthropic-beta", "a-requested-beta"),
				option.WithHeader("X-Request-Note", "request-header"),
			)
			if err != nil {
				t.Fatalf("Messages.New: %v", err)
			}

			r := server.Requests()[before]
			if got := r.Header.Get(mode.header); got != mode.want {
				t.Errorf("%s = %q, want %q", mode.header, got, mode.want)
			}
			for _, other := range []string{"Authorization", "X-Api-Key", "Api-Key"} {
				if other != mode.header {
					requireAbsent(t, r, other)
				}
			}
			if got := r.Header.Get("Anthropic-Beta"); got != "a-requested-beta" {
				t.Errorf("anthropic-beta = %q", got)
			}
			if got := r.Header.Get("X-Request-Note"); got != "request-header" {
				t.Errorf("x-request-note = %q", got)
			}
			requireAbsent(t, r, "X-Note")
			if strings.Contains(fmt.Sprint(r.Header), "canary") {
				t.Errorf("a canary reached the wire: %v", r.Header)
			}
		})
	}
}

func TestKeyHeaderAndAPIVersion(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	stock := anthropic.NewClient(option.WithAPIKey("stock-key"), option.WithBaseURL(server.URL), option.WithMaxRetries(0))
	if _, err := stock.Messages.New(testContext(t), params()); err != nil {
		t.Fatalf("stock request: %v", err)
	}
	sdkVersion := server.Requests()[0].Header.Get("Anthropic-Version")
	if sdkVersion == "" {
		t.Fatal("the SDK sends no anthropic-version")
	}

	cases := []struct{ keyHeader, header, want string }{
		{"", "Authorization", "Bearer selected-key"},
		{"Authorization", "Authorization", "Bearer selected-key"},
		{"x-api-key", "X-Api-Key", "selected-key"},
		{"api-key", "Api-Key", "selected-key"},
	}
	for _, c := range cases {
		before := server.Count()
		client := newClient(t, clientauth.Options{BaseURL: server.URL, APIKey: "selected-key", KeyHeader: c.keyHeader, MaxRetries: retries(0)})
		if _, err := client.Messages.New(testContext(t), params()); err != nil {
			t.Fatalf("Messages.New: %v", err)
		}
		r := server.Requests()[before]
		if got := r.Header.Get(c.header); got != c.want {
			t.Errorf("keyHeader %q: %s = %q, want %q", c.keyHeader, c.header, got, c.want)
		}
		for _, other := range []string{"Authorization", "X-Api-Key", "Api-Key"} {
			if other != c.header {
				requireAbsent(t, r, other)
			}
		}
		if got := r.Header.Get("Anthropic-Version"); got != sdkVersion {
			t.Errorf("anthropic-version = %q, want the SDK default %q", got, sdkVersion)
		}
	}

	before := server.Count()
	client := newClient(t, clientauth.Options{BaseURL: server.URL, APIKey: "selected-key", APIVersion: "2023-06-01", MaxRetries: retries(0)})
	if _, err := client.Messages.New(testContext(t), params()); err != nil {
		t.Fatalf("Messages.New: %v", err)
	}
	if got := server.Requests()[before].Header.Get("Anthropic-Version"); got != "2023-06-01" {
		t.Errorf("anthropic-version = %q", got)
	}
}

func TestUserHeadersAndBetasArePreserved(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "token", nil }, MaxRetries: retries(0)})

	_, err := client.Messages.New(testContext(t), params(), option.WithHeader("X-Team", "platform"), option.WithHeader("anthropic-beta", "prompt-caching-2024-07-31"))
	if err != nil {
		t.Fatalf("Messages.New: %v", err)
	}

	r := server.Requests()[0]
	if r.Header.Get("X-Team") != "platform" || r.Header.Get("Anthropic-Beta") != "prompt-caching-2024-07-31" {
		t.Errorf("headers = %v", r.Header)
	}
	requireClean(t, server.Requests())
}

func TestInvalidConfigurationFailsBeforeAnyRequest(t *testing.T) {
	provider := func(context.Context) (string, error) { return "token", nil }
	base := "https://example.services.ai.azure.com/anthropic"
	cases := map[string]clientauth.Options{
		"no credential":            {BaseURL: base},
		"two credentials":          {BaseURL: base, APIKey: "key", TokenProvider: provider},
		"plain HTTP":               {BaseURL: "http://insecure.example", APIKey: "key"},
		"HTTP on a lookalike host": {BaseURL: "http://localhost.example", APIKey: "key"},
		"embedded credentials":     {BaseURL: "https://user:secret@example.com", APIKey: "key"},
		"query string":             {BaseURL: "https://example.com/anthropic?x=1", APIKey: "key"},
		"fragment":                 {BaseURL: "https://example.com/anthropic#x", APIKey: "key"},
		"not a URL":                {BaseURL: "not a url", APIKey: "key"},
		"empty base URL":           {APIKey: "key"},
		"blank key":                {BaseURL: base, APIKey: "   "},
		"multi-line key":           {BaseURL: base, APIKey: "key\nx-injected: 1"},
		"bad header name":          {BaseURL: base, APIKey: "key", KeyHeader: "bad header"},
		"bad API version":          {BaseURL: base, APIKey: "key", APIVersion: "bad\nversion"},
		"negative retries":         {BaseURL: base, APIKey: "key", MaxRetries: retries(-1)},
		"negative timeout":         {BaseURL: base, APIKey: "key", RequestTimeout: -time.Second},
	}
	for name, opts := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := clientauth.CreateClient(opts); err == nil {
				t.Fatal("expected an error")
			} else if strings.Contains(err.Error(), "secret") {
				t.Fatalf("the error echoes the URL credentials: %v", err)
			}
		})
	}
}

func TestHTTPSAndLoopbackBaseURLsAreAccepted(t *testing.T) {
	for _, base := range []string{"https://example.com", "https://example.com:8443/anthropic", "http://localhost:1", "http://127.0.0.1:1", "http://[::1]:1"} {
		if _, err := clientauth.CreateClient(clientauth.Options{BaseURL: base, APIKey: "key"}); err != nil {
			t.Errorf("%s: %v", base, err)
		}
	}
}

func TestRedirectsAreNeverFollowed(t *testing.T) {
	testserver.CleanEnvironment(t)
	other := testserver.New(t, testserver.Respond(testserver.OKMessage))
	origin := testserver.New(t, testserver.Redirect(http.StatusTemporaryRedirect, other.URL+"/v1/messages"))
	sameOrigin := testserver.New(t, testserver.Redirect(http.StatusPermanentRedirect, "/elsewhere"))

	for _, c := range []struct {
		name   string
		server *testserver.Server
		opts   clientauth.Options
	}{
		{"bearer, cross-origin", origin, clientauth.Options{TokenProvider: func(context.Context) (string, error) { return "selected-token", nil }}},
		{"x-api-key, cross-origin", origin, clientauth.Options{APIKey: "selected-key", KeyHeader: "x-api-key"}},
		{"bearer, same-origin", sameOrigin, clientauth.Options{TokenProvider: func(context.Context) (string, error) { return "selected-token", nil }}},
	} {
		before := c.server.Count()
		c.opts.BaseURL = c.server.URL
		client := newClient(t, c.opts)
		_, err := client.Messages.New(testContext(t), params())
		if !errors.Is(err, clientauth.ErrRedirectRefused) {
			t.Errorf("%s: err = %v, want ErrRedirectRefused", c.name, err)
		}
		if got := c.server.Count() - before; got != 1 {
			t.Errorf("%s: the origin saw %d requests; a refused redirect is final, so the SDK must not retry it", c.name, got)
		}
	}
	if other.Count() != 0 {
		t.Errorf("no credential may reach the redirect target, it saw %d requests", other.Count())
	}
}

func TestRedirectPolicyOfASuppliedClientIsReplaced(t *testing.T) {
	testserver.CleanEnvironment(t)
	other := testserver.New(t, testserver.Respond(testserver.OKMessage))
	origin := testserver.New(t, testserver.Redirect(http.StatusTemporaryRedirect, other.URL+"/v1/messages"))
	var used atomic.Int32
	supplied := &http.Client{
		Transport:     roundTripFunc(func(r *http.Request) (*http.Response, error) { used.Add(1); return http.DefaultTransport.RoundTrip(r) }),
		CheckRedirect: func(*http.Request, []*http.Request) error { return nil },
	}
	client := newClient(t, clientauth.Options{BaseURL: origin.URL, APIKey: "selected-key", KeyHeader: "x-api-key", HTTPClient: supplied, MaxRetries: retries(0)})

	_, err := client.Messages.New(testContext(t), params())

	if !errors.Is(err, clientauth.ErrRedirectRefused) {
		t.Errorf("err = %v", err)
	}
	if used.Load() != 1 || other.Count() != 0 {
		t.Errorf("transport used %d times, redirect target saw %d requests", used.Load(), other.Count())
	}
	if supplied.CheckRedirect == nil {
		t.Error("the caller's client was modified")
	} else if err := supplied.CheckRedirect(nil, nil); err != nil {
		t.Error("the caller's client was modified")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestCredentialsAreBoundToTheConfiguredOrigin(t *testing.T) {
	testserver.CleanEnvironment(t)
	other := testserver.New(t, testserver.Respond(testserver.OKMessage))
	origin := testserver.New(t, testserver.Respond(testserver.OKMessage))
	var calls atomic.Int32
	client := newClient(t, clientauth.Options{
		BaseURL:       origin.URL,
		TokenProvider: func(context.Context) (string, error) { calls.Add(1); return "selected-token", nil },
		MaxRetries:    retries(0),
	})

	_, err := client.Messages.New(testContext(t), params(), option.WithBaseURL(other.URL))
	if !errors.Is(err, clientauth.ErrDifferentOrigin) {
		t.Errorf("per-call base URL: err = %v", err)
	}
	err = client.Post(testContext(t), other.URL+"/v1/messages", params(), nil)
	if !errors.Is(err, clientauth.ErrDifferentOrigin) {
		t.Errorf("absolute URL: err = %v", err)
	}

	if other.Count() != 0 || origin.Count() != 0 || calls.Load() != 0 {
		t.Errorf("requests: other=%d origin=%d, provider calls=%d; nothing may be sent or resolved", other.Count(), origin.Count(), calls.Load())
	}
}

func TestProviderFailureIsWrappedAndRetriedLikeATransportError(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	failure := errors.New("credential unavailable")
	var calls atomic.Int32
	client := newClient(t, clientauth.Options{
		BaseURL:       server.URL,
		TokenProvider: func(context.Context) (string, error) { calls.Add(1); return "", failure },
		MaxRetries:    retries(1),
	})

	_, err := client.Messages.New(testContext(t), params())

	if !errors.Is(err, failure) || !errors.Is(err, clientauth.ErrCredentialProvider) {
		t.Errorf("err = %v", err)
	}
	if calls.Load() != 2 {
		t.Errorf("provider called %d times, want 2 (one attempt and one retry)", calls.Load())
	}
	if server.Count() != 0 {
		t.Errorf("no request may be sent, got %d", server.Count())
	}
}

func TestInvalidCredentialValuesAreRejected(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	for _, value := range []string{"", "   ", "a\nb", "a\r\nb"} {
		client := newClient(t, clientauth.Options{
			BaseURL:       server.URL,
			TokenProvider: func(context.Context) (string, error) { return value, nil },
			MaxRetries:    retries(0),
		})
		if _, err := client.Messages.New(testContext(t), params()); !errors.Is(err, clientauth.ErrInvalidCredential) {
			t.Errorf("value %q: err = %v", value, err)
		}
	}
	if server.Count() != 0 {
		t.Errorf("no request may be sent, got %d", server.Count())
	}
}

func TestHTTPStatusesArePreserved(t *testing.T) {
	testserver.CleanEnvironment(t)
	for _, status := range []int{401, 403, 429, 500} {
		server := testserver.New(t, testserver.Error(status))
		client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "token", nil }, MaxRetries: retries(0)})

		_, err := client.Messages.New(testContext(t), params())

		var apiErr *anthropic.Error
		if !errors.As(err, &apiErr) || apiErr.StatusCode != status {
			t.Errorf("status %d: err = %v", status, err)
		}
	}
}

func TestAuthenticationAndPermissionFailuresAreNotRetried(t *testing.T) {
	testserver.CleanEnvironment(t)
	for _, status := range []int{401, 403} {
		server := testserver.New(t, testserver.Error(status))
		client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "token", nil }})

		_, err := client.Messages.New(testContext(t), params())

		var apiErr *anthropic.Error
		if !errors.As(err, &apiErr) || apiErr.StatusCode != status {
			t.Errorf("status %d: err = %v", status, err)
		}
		if server.Count() != 1 {
			t.Errorf("status %d: %d requests, want 1", status, server.Count())
		}
	}
}

func TestSDKRetryReacquiresTheCredential(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, func(w http.ResponseWriter, r *http.Request, count int) {
		if count < 3 {
			testserver.Error(500, "retry-after-ms", "1")(w, r, count)
			return
		}
		testserver.Respond(testserver.OKMessage)(w, r, count)
	})
	var calls atomic.Int32
	client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) {
		return fmt.Sprintf("token-%d", calls.Add(1)), nil
	}})

	if _, err := client.Messages.New(testContext(t), params()); err != nil {
		t.Fatalf("Messages.New: %v", err)
	}

	requests := server.Requests()
	if len(requests) != 3 {
		t.Fatalf("got %d requests, want 3 (the SDK default of two retries)", len(requests))
	}
	for i, r := range requests {
		if got, want := r.Header.Get("Authorization"), fmt.Sprintf("Bearer token-%d", i+1); got != want {
			t.Errorf("attempt %d Authorization = %q, want %q", i, got, want)
		}
		if got := r.Header.Get("X-Stainless-Retry-Count"); got != fmt.Sprint(i) {
			t.Errorf("attempt %d retry count = %q", i, got)
		}
	}
}

func TestStreamingThroughTheStandardSDKHelper(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Stream(testserver.Block{Kind: "thinking", Text: "not for display"}, testserver.Block{Kind: "text", Text: "OK"}))
	client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "stream-token", nil }, MaxRetries: retries(0)})

	stream := client.Messages.NewStreaming(testContext(t), params())
	defer stream.Close()
	var text strings.Builder
	for stream.Next() {
		if event, ok := stream.Current().AsAny().(anthropic.ContentBlockDeltaEvent); ok {
			if delta, ok := event.Delta.AsAny().(anthropic.TextDelta); ok {
				text.WriteString(delta.Text)
			}
		}
	}
	if err := stream.Err(); err != nil {
		t.Fatalf("stream: %v", err)
	}

	if text.String() != "OK" {
		t.Errorf("text = %q", text.String())
	}
	r := server.Requests()[0]
	if r.Header.Get("Authorization") != "Bearer stream-token" || !strings.Contains(r.Body, `"stream":true`) {
		t.Errorf("request = %v %s", r.Header, r.Body)
	}
	requireClean(t, server.Requests())
}

func TestCancellationReachesTheProvider(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	started := make(chan struct{})
	observed := make(chan error, 1)
	client := newClient(t, clientauth.Options{
		BaseURL: server.URL,
		TokenProvider: func(ctx context.Context) (string, error) {
			close(started)
			<-ctx.Done()
			observed <- ctx.Err()
			return "", ctx.Err()
		},
		MaxRetries: retries(2),
	})
	ctx, cancel := context.WithCancel(testContext(t))
	done := make(chan error, 1)
	go func() {
		_, err := client.Messages.New(ctx, params())
		done <- err
	}()

	<-started
	cancel()

	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v, want context.Canceled", err)
	}
	if err := <-observed; !errors.Is(err, context.Canceled) {
		t.Errorf("the provider saw %v", err)
	}
	if server.Count() != 0 {
		t.Errorf("no request may be sent, got %d", server.Count())
	}
}

func TestCancellationAndDeadlinesOfARequestInFlight(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Hang)
	client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "token", nil }, MaxRetries: retries(0)})

	ctx, cancel := context.WithCancel(testContext(t))
	done := make(chan error, 1)
	go func() {
		_, err := client.Messages.New(ctx, params())
		done <- err
	}()
	for server.Count() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Errorf("cancel: err = %v", err)
	}

	deadline, stop := context.WithTimeout(testContext(t), 100*time.Millisecond)
	defer stop()
	if _, err := client.Messages.New(deadline, params()); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("deadline: err = %v", err)
	}
}

func TestEachAttemptIsBoundedByTheRequestTimeout(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Hang)
	client := newClient(t, clientauth.Options{
		BaseURL:        server.URL,
		TokenProvider:  func(context.Context) (string, error) { return "token", nil },
		MaxRetries:     retries(0),
		RequestTimeout: 50 * time.Millisecond,
	})

	_, err := client.Messages.New(testContext(t), params())

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("err = %v", err)
	}
	if server.Count() != 1 {
		t.Errorf("server saw %d requests", server.Count())
	}
}

func TestSDKTimeoutDefaultsArePreserved(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(testserver.OKMessage))
	stock := anthropic.NewClient(option.WithAPIKey("stock-key"), option.WithBaseURL(server.URL), option.WithMaxRetries(0))
	if _, err := stock.Messages.New(testContext(t), params()); err != nil {
		t.Fatalf("stock request: %v", err)
	}
	sdkTimeout := server.Requests()[0].Header.Get("X-Stainless-Timeout")
	if sdkTimeout == "" {
		t.Fatal("the SDK sends no timeout header")
	}

	for _, c := range []struct {
		name    string
		timeout time.Duration
		want    string
	}{
		{"unset keeps the SDK default", 0, sdkTimeout},
		{"set is applied to each attempt", 30 * time.Second, "30"},
	} {
		before := server.Count()
		client := newClient(t, clientauth.Options{
			BaseURL:        server.URL,
			TokenProvider:  func(context.Context) (string, error) { return "token", nil },
			MaxRetries:     retries(0),
			RequestTimeout: c.timeout,
		})
		if _, err := client.Messages.New(testContext(t), params()); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := server.Requests()[before].Header.Get("X-Stainless-Timeout"); got != c.want {
			t.Errorf("%s: X-Stainless-Timeout = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestMaxRetriesIsHonoured(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Error(500, "retry-after-ms", "1"))
	client := newClient(t, clientauth.Options{BaseURL: server.URL, TokenProvider: func(context.Context) (string, error) { return "token", nil }, MaxRetries: retries(1)})

	_, err := client.Messages.New(testContext(t), params())

	var apiErr *anthropic.Error
	if !errors.As(err, &apiErr) || apiErr.StatusCode != 500 {
		t.Errorf("err = %v", err)
	}
	if server.Count() != 2 {
		t.Errorf("server saw %d requests, want 2", server.Count())
	}
}
