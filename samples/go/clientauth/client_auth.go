// Package clientauth builds a stock anthropic.Client whose credential is chosen
// explicitly and resolved for every HTTP attempt.
//
// It only uses public SDK options. option.WithoutEnvironmentDefaults stops the SDK
// from reading ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_PROFILE, a profile
// on disk, ANTHROPIC_BASE_URL and ANTHROPIC_CUSTOM_HEADERS. One middleware, registered
// last so that it sits closest to the network, then runs for each attempt (including
// SDK retries) and:
//
//   - refuses any request whose origin differs from the configured base URL;
//   - replaces every credential-bearing header (SDK, per-call and default headers)
//     with the single selected credential;
//
// while the HTTP client it installs refuses to follow redirects. The SDK's
// credential-provider options are not used, so no OAuth beta header is added and the
// helper has no token cache or retry of its own. The SDK's retry and timeout defaults
// are preserved: MaxRetries and RequestTimeout are applied only when set.
//
// Errors returned by the middleware (a failing provider, an invalid credential value, a
// different origin) are transport errors to the SDK, which retries them up to MaxRetries
// times. A refused redirect is final: net/http returns the redirect response together
// with the error, and the SDK does not retry a 3xx response. Do not pass
// option.WithHTTPClient to individual calls: it would replace the redirect policy.
package clientauth

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/anthropics/anthropic-sdk-go/v2/option"
)

// sdkResponseHeaderTimeout is the response-header timeout of the SDK's own default HTTP client
// (internal/requestconfig.DefaultHTTPClient). The client installed here mirrors it so that
// replacing the redirect policy does not change the SDK's timeout behavior.
const sdkResponseHeaderTimeout = 10 * time.Minute

// CredentialProvider returns the credential for one HTTP attempt; ctx is that
// attempt's request context. It is called again for every retry.
type CredentialProvider func(ctx context.Context) (string, error)

// Options configures CreateClient.
type Options struct {
	// BaseURL is the Messages API base URL. HTTPS only; plain HTTP is accepted for loopback hosts.
	BaseURL string
	// TokenProvider is a bearer-token callback, sent as "Authorization: Bearer <token>".
	// Set this or APIKey.
	TokenProvider CredentialProvider
	// APIKey is a static key. Set this or TokenProvider.
	APIKey string
	// KeyHeader carries APIKey: "Authorization" (the default, sent as "Bearer <key>") or a
	// raw-key header such as "x-api-key".
	KeyHeader string
	// APIVersion overrides the SDK's anthropic-version header; the SDK default applies when empty.
	APIVersion string
	// MaxRetries overrides the SDK retry count; the SDK default applies when nil.
	MaxRetries *int
	// RequestTimeout bounds one HTTP attempt; the SDK's default applies when zero.
	RequestTimeout time.Duration
	// HTTPClient supplies the transport. Its redirect policy is always replaced.
	HTTPClient *http.Client
}

var (
	// ErrDifferentOrigin is returned, before anything is sent, for a request whose origin differs from BaseURL.
	ErrDifferentOrigin = errors.New("clientauth: refusing to send credentials to a different origin")
	// ErrRedirectRefused is returned when the server answers with a redirect.
	ErrRedirectRefused = errors.New("clientauth: refusing to follow a redirect")
	// ErrCredentialProvider wraps a failure of the credential provider.
	ErrCredentialProvider = errors.New("clientauth: the credential provider failed")
	// ErrInvalidCredential is returned when the provider returns an empty or multi-line value.
	ErrInvalidCredential = errors.New("clientauth: the credential must be a nonempty, single-line string")

	errInvalidBaseURL = errors.New("clientauth: BaseURL must be an HTTPS URL without credentials, query, or fragment")
	headerName        = regexp.MustCompile("^[!#$%&'*+\\-.^_`|~0-9A-Za-z]+$")
	versionValue      = regexp.MustCompile(`^[\x21-\x7e]+$`)
)

var credentialHeaders = []string{"Authorization", "X-Api-Key", "Api-Key"}

// CreateClient returns a stock anthropic.Client; see the package documentation.
func CreateClient(opts Options) (anthropic.Client, error) {
	base, err := parseBaseURL(opts.BaseURL)
	if err != nil {
		return anthropic.Client{}, err
	}
	if (opts.TokenProvider == nil) == (opts.APIKey == "") {
		return anthropic.Client{}, errors.New("clientauth: provide exactly one of TokenProvider or APIKey")
	}
	if opts.APIKey != "" && !validSecret(opts.APIKey) {
		return anthropic.Client{}, errors.New("clientauth: APIKey must be a nonempty, single-line string")
	}
	keyHeader := opts.KeyHeader
	if keyHeader == "" {
		keyHeader = "Authorization"
	}
	if !headerName.MatchString(keyHeader) {
		return anthropic.Client{}, errors.New("clientauth: KeyHeader must be a valid HTTP header name")
	}
	if opts.APIVersion != "" && !versionValue.MatchString(opts.APIVersion) {
		return anthropic.Client{}, errors.New("clientauth: APIVersion must be a string of printable ASCII characters")
	}
	if opts.MaxRetries != nil && *opts.MaxRetries < 0 {
		return anthropic.Client{}, errors.New("clientauth: MaxRetries must not be negative")
	}
	if opts.RequestTimeout < 0 {
		return anthropic.Client{}, errors.New("clientauth: RequestTimeout must not be negative")
	}

	provider := opts.TokenProvider
	header := keyHeader
	if provider != nil {
		header = "Authorization"
	} else {
		key := opts.APIKey
		provider = func(context.Context) (string, error) { return key, nil }
	}

	sdkOptions := []option.RequestOption{
		option.WithoutEnvironmentDefaults(),
		option.WithBaseURL(opts.BaseURL),
		option.WithHTTPClient(httpClient(opts.HTTPClient)),
	}
	if opts.RequestTimeout > 0 {
		sdkOptions = append(sdkOptions, option.WithRequestTimeout(opts.RequestTimeout))
	}
	if opts.APIVersion != "" {
		sdkOptions = append(sdkOptions, option.WithHeader("anthropic-version", opts.APIVersion))
	}
	if opts.MaxRetries != nil {
		sdkOptions = append(sdkOptions, option.WithMaxRetries(*opts.MaxRetries))
	}
	sdkOptions = append(sdkOptions, option.WithMiddleware(authorizer(originOf(base), header, strings.EqualFold(header, "Authorization"), provider)))
	return anthropic.NewClient(sdkOptions...), nil
}

func authorizer(allowed origin, header string, bearer bool, provide CredentialProvider) option.Middleware {
	return func(req *http.Request, next option.MiddlewareNext) (*http.Response, error) {
		if originOf(req.URL) != allowed {
			return nil, ErrDifferentOrigin
		}
		value, err := provide(req.Context())
		if err != nil {
			return nil, fmt.Errorf("%w: %w", ErrCredentialProvider, err)
		}
		if !validSecret(value) {
			return nil, ErrInvalidCredential
		}
		for _, name := range credentialHeaders {
			req.Header.Del(name)
		}
		req.Header.Del(header)
		if bearer {
			value = "Bearer " + value
		}
		req.Header.Set(header, value)
		return next(req)
	}
}

func httpClient(supplied *http.Client) *http.Client {
	client := &http.Client{}
	if supplied != nil {
		copied := *supplied
		client = &copied
	} else if transport, ok := http.DefaultTransport.(*http.Transport); ok {
		cloned := transport.Clone()
		cloned.ResponseHeaderTimeout = sdkResponseHeaderTimeout
		client.Transport = cloned
	}
	// When the policy refuses, net/http returns the redirect response together with the
	// error, which the SDK treats as final instead of retrying.
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return ErrRedirectRefused }
	return client
}

func parseBaseURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return nil, errInvalidBaseURL
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
	case "http":
		if !loopback(u.Hostname()) {
			return nil, errInvalidBaseURL
		}
	default:
		return nil, errInvalidBaseURL
	}
	return u, nil
}

func loopback(host string) bool {
	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1":
		return true
	}
	return false
}

type origin struct{ scheme, host, port string }

func originOf(u *url.URL) origin {
	scheme := strings.ToLower(u.Scheme)
	port := u.Port()
	if port == "" {
		switch scheme {
		case "https":
			port = "443"
		case "http":
			port = "80"
		}
	}
	return origin{scheme, strings.ToLower(u.Hostname()), port}
}

func validSecret(value string) bool {
	return strings.TrimSpace(value) != "" && !strings.ContainsAny(value, "\r\n\x00")
}
