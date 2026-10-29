package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"

	"github.com/Azure-Samples/claude/samples/go/internal/testserver"
)

func env(pairs map[string]string) func(string) string {
	return func(name string) string { return pairs[name] }
}

func retries(n int) *int { return &n }

type fakeCredential struct {
	calls  atomic.Int32
	scopes [][]string
	err    error
}

func (f *fakeCredential) GetToken(_ context.Context, options policy.TokenRequestOptions) (azcore.AccessToken, error) {
	f.scopes = append(f.scopes, options.Scopes)
	n := f.calls.Add(1)
	if f.err != nil {
		return azcore.AccessToken{}, f.err
	}
	return azcore.AccessToken{Token: fmt.Sprintf("token-%d", n), ExpiresOn: time.Now().Add(time.Hour)}, nil
}

const (
	canonicalURL = "https://example.services.ai.azure.com/anthropic"
	legacyURL    = "https://legacy.example"
)

func canonicalEnv(extra map[string]string) map[string]string {
	environment := map[string]string{"ANTHROPIC_BASE_URL": canonicalURL, "ANTHROPIC_MODEL": "sample-deployment"}
	for k, v := range extra {
		environment[k] = v
	}
	return environment
}

func legacyEnv(extra map[string]string) map[string]string {
	environment := map[string]string{"CLAUDE_BASE_URL": legacyURL, "CLAUDE_DEPLOYMENT_NAME": "legacy-deployment"}
	for k, v := range extra {
		environment[k] = v
	}
	return environment
}

func TestCanonicalProfileRequiresAnExplicitAuthMode(t *testing.T) {
	_, err := loadSettings(env(canonicalEnv(nil)))
	var config *configError
	if !errors.As(err, &config) || err.Error() != "ANTHROPIC_BASE_URL is set, so AUTH_MODE must be set explicitly to bearer or api_key." {
		t.Fatalf("err = %v", err)
	}

	got, err := loadSettings(env(canonicalEnv(map[string]string{"AUTH_MODE": "bearer"})))
	if err != nil {
		t.Fatal(err)
	}
	want := settings{
		profile: "anthropic",
		baseURL: canonicalURL,
		model:   "sample-deployment",
		auth:    authSettings{mode: "bearer", credential: "AzureCliCredential", scope: "https://ai.azure.com/.default"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("settings = %+v, want %+v", got, want)
	}
}

func TestLegacyProfileDefaultsToBearer(t *testing.T) {
	got, err := loadSettings(env(legacyEnv(nil)))
	if err != nil {
		t.Fatal(err)
	}
	if got.profile != "claude" || got.baseURL != legacyURL || got.model != "legacy-deployment" || got.auth.mode != "bearer" || got.apiVersion != "" {
		t.Errorf("settings = %+v", got)
	}
}

func TestACompleteCanonicalProfileOverridesTheLegacyOneEntirely(t *testing.T) {
	environment := canonicalEnv(map[string]string{
		"AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-key",
		"CLAUDE_BASE_URL": legacyURL, "CLAUDE_DEPLOYMENT_NAME": "legacy-deployment", "CLAUDE_API_KEY": "legacy-key",
	})
	got, err := loadSettings(env(environment))
	want := settings{
		profile: "anthropic",
		baseURL: canonicalURL,
		model:   "sample-deployment",
		auth:    authSettings{mode: "api_key", apiKey: "native-key", keyHeader: "Authorization"},
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Errorf("settings = %+v, %v; want %+v", got, err, want)
	}
}

func TestLoadSettingsBearerAndAPIKeyDetails(t *testing.T) {
	bearer, err := loadSettings(env(canonicalEnv(map[string]string{
		"AUTH_MODE": "bearer", "AZURE_TOKEN_CREDENTIALS": "ManagedIdentityCredential", "AZURE_TENANT_ID": "example-tenant",
		"AZURE_CLIENT_ID": "example-client", "TOKEN_SCOPE": "https://example.test/.default",
	})))
	want := authSettings{mode: "bearer", credential: "ManagedIdentityCredential", tenantID: "example-tenant", clientID: "example-client", scope: "https://example.test/.default"}
	if err != nil || bearer.auth != want {
		t.Errorf("bearer settings: %+v, %v", bearer.auth, err)
	}

	keyed, err := loadSettings(env(legacyEnv(map[string]string{"AUTH_MODE": "api_key", "CLAUDE_API_KEY": "legacy-key"})))
	if err != nil || keyed.auth != (authSettings{mode: "api_key", apiKey: "legacy-key", keyHeader: "Authorization"}) || keyed.apiVersion != "" {
		t.Errorf("legacy api key defaults: %+v, %v", keyed, err)
	}
	custom, err := loadSettings(env(canonicalEnv(map[string]string{
		"AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-key", "API_KEY_HEADER": "x-api-key", "ANTHROPIC_API_VERSION": "2023-06-01",
	})))
	if err != nil || custom.auth.apiKey != "native-key" || custom.auth.keyHeader != "x-api-key" || custom.apiVersion != "2023-06-01" {
		t.Errorf("api key overrides: %+v, %v", custom, err)
	}
}

func TestTheFamiliesAreNeverMixed(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"canonical URL, legacy model",
			map[string]string{"ANTHROPIC_BASE_URL": "https://example.test", "AUTH_MODE": "bearer", "CLAUDE_DEPLOYMENT_NAME": "legacy-deployment"},
			"ANTHROPIC_BASE_URL is set, so ANTHROPIC_MODEL is required; CLAUDE_DEPLOYMENT_NAME is not used with it."},
		{"canonical URL, legacy key",
			map[string]string{"ANTHROPIC_BASE_URL": "https://example.test", "ANTHROPIC_MODEL": "native-model", "AUTH_MODE": "api_key", "CLAUDE_API_KEY": "legacy-key-canary"},
			"AUTH_MODE=api_key with ANTHROPIC_BASE_URL requires ANTHROPIC_API_KEY; CLAUDE_API_KEY is not used with it."},
		{"legacy URL, canonical model",
			map[string]string{"CLAUDE_BASE_URL": "https://example.test", "AUTH_MODE": "bearer", "ANTHROPIC_MODEL": "native-model"},
			"CLAUDE_BASE_URL is set, so CLAUDE_DEPLOYMENT_NAME is required; ANTHROPIC_MODEL is not used with it."},
		{"legacy URL, canonical key",
			legacyEnv(map[string]string{"AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-key-canary"}),
			"AUTH_MODE=api_key with CLAUDE_BASE_URL requires CLAUDE_API_KEY; ANTHROPIC_API_KEY is not used with it."},
	}
	for _, c := range cases {
		_, err := loadSettings(env(c.env))
		var config *configError
		if !errors.As(err, &config) || err.Error() != c.want {
			t.Errorf("%s: err = %v", c.name, err)
		}
	}
}

func TestLoadSettingsReportsMissingOrInvalidConfigurationWithoutValues(t *testing.T) {
	_, err := loadSettings(env(nil))
	want := "Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME."
	if err == nil || err.Error() != want {
		t.Errorf("err = %v", err)
	}
	if _, err := loadSettings(env(map[string]string{"ANTHROPIC_MODEL": "native-model", "CLAUDE_DEPLOYMENT_NAME": "legacy"})); err == nil {
		t.Error("a model without a base URL must not select a profile")
	}
	for _, family := range []map[string]string{canonicalEnv(nil), legacyEnv(nil)} {
		family["AUTH_MODE"] = "basic"
		if _, err := loadSettings(env(family)); err == nil || err.Error() != "AUTH_MODE must be bearer or api_key." {
			t.Errorf("err = %v", err)
		}
	}
}

type recordedFactory struct {
	name    string
	options any
}

func recordingFactories() (*[]recordedFactory, credentialFactories) {
	var calls []recordedFactory
	fake := &fakeCredential{}
	return &calls, credentialFactories{
		azureCLI: func(o *azidentity.AzureCLICredentialOptions) (azcore.TokenCredential, error) {
			calls = append(calls, recordedFactory{"AzureCliCredential", *o})
			return fake, nil
		},
		azureDeveloperCLI: func(o *azidentity.AzureDeveloperCLICredentialOptions) (azcore.TokenCredential, error) {
			calls = append(calls, recordedFactory{"AzureDeveloperCliCredential", *o})
			return fake, nil
		},
		managedIdentity: func(o *azidentity.ManagedIdentityCredentialOptions) (azcore.TokenCredential, error) {
			calls = append(calls, recordedFactory{"ManagedIdentityCredential", *o})
			return fake, nil
		},
	}
}

func TestCreateCredentialBuildsExactlyTheNamedCredential(t *testing.T) {
	calls, factories := recordingFactories()
	for _, source := range []string{"AzureCliCredential", "AzureDeveloperCliCredential", "ManagedIdentityCredential"} {
		if _, err := createCredential(source, "example-tenant", "example-client", factories); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := createCredential("ManagedIdentityCredential", "example-tenant", "", factories); err != nil {
		t.Fatal(err)
	}

	want := []recordedFactory{
		{"AzureCliCredential", azidentity.AzureCLICredentialOptions{TenantID: "example-tenant"}},
		{"AzureDeveloperCliCredential", azidentity.AzureDeveloperCLICredentialOptions{TenantID: "example-tenant"}},
		{"ManagedIdentityCredential", azidentity.ManagedIdentityCredentialOptions{ID: azidentity.ClientID("example-client")}},
		{"ManagedIdentityCredential", azidentity.ManagedIdentityCredentialOptions{}},
	}
	if !reflect.DeepEqual(*calls, want) {
		t.Errorf("factory calls = %+v\nwant %+v", *calls, want)
	}
}

func TestCreateCredentialHasNoFallback(t *testing.T) {
	calls, factories := recordingFactories()
	for _, source := range []string{"DefaultAzureCredential", "typo", "azureclicredential", ""} {
		_, err := createCredential(source, "", "", factories)
		var config *configError
		if !errors.As(err, &config) || !strings.Contains(err.Error(), "AZURE_TOKEN_CREDENTIALS") {
			t.Errorf("%q: err = %v", source, err)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("no credential may be built, got %v", *calls)
	}
}

func TestCreateCredentialBuildsTheRealAzureIdentityTypesWithoutContactingAnything(t *testing.T) {
	cli, err := createCredential("AzureCliCredential", "example-tenant", "", azureIdentityCredentials)
	if _, ok := cli.(*azidentity.AzureCLICredential); !ok || err != nil {
		t.Errorf("AzureCliCredential: %T, %v", cli, err)
	}
	azd, err := createCredential("AzureDeveloperCliCredential", "", "", azureIdentityCredentials)
	if _, ok := azd.(*azidentity.AzureDeveloperCLICredential); !ok || err != nil {
		t.Errorf("AzureDeveloperCliCredential: %T, %v", azd, err)
	}
	identity, err := createCredential("ManagedIdentityCredential", "", "example-client", azureIdentityCredentials)
	if _, ok := identity.(*azidentity.ManagedIdentityCredential); !ok || err != nil {
		t.Errorf("ManagedIdentityCredential: %T, %v", identity, err)
	}
}

func TestTokenProviderRequestsTheScopeOnEveryCallWithoutCachingOfItsOwn(t *testing.T) {
	credential := &fakeCredential{}
	provider := tokenProvider(credential, defaultTokenScope)
	if credential.calls.Load() != 0 {
		t.Fatal("the provider must be lazy")
	}

	first, err1 := provider(context.Background())
	second, err2 := provider(context.Background())

	if err1 != nil || err2 != nil || first != "token-1" || second != "token-2" {
		t.Errorf("tokens = %q, %q (%v, %v)", first, second, err1, err2)
	}
	if want := [][]string{{defaultTokenScope}, {defaultTokenScope}}; !reflect.DeepEqual(credential.scopes, want) {
		t.Errorf("scopes = %v", credential.scopes)
	}

	failing := &fakeCredential{err: errors.New("login required")}
	if _, err := tokenProvider(failing, defaultTokenScope)(context.Background()); !errors.Is(err, failing.err) {
		t.Errorf("err = %v", err)
	}
}

type output struct{ stdout, stderr bytes.Buffer }

func (o *output) run(args []string, environment map[string]string, options runOptions) int {
	return run(context.Background(), args, env(environment), &o.stdout, &o.stderr, options)
}

var (
	textReply    = testserver.Message("end_turn", testserver.ThinkingBlock, testserver.TextBlock("OK"))
	thinkingOnly = testserver.Message("max_tokens", testserver.ThinkingBlock)
)

func sampleEnv(server *testserver.Server, extra map[string]string) map[string]string {
	environment := map[string]string{
		"ANTHROPIC_BASE_URL": server.URL + "/anthropic",
		"ANTHROPIC_MODEL":    "sample-deployment",
		"AUTH_MODE":          "api_key",
		"ANTHROPIC_API_KEY":  "sample-key",
	}
	for k, v := range extra {
		environment[k] = v
	}
	return environment
}

func fastRetries() runOptions {
	return runOptions{clientOverrides: clientOverrides{maxRetries: retries(0)}}
}

func TestPrintsReplyTextAndUsageButNotThinking(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(textReply))
	var out output

	if code := out.run(nil, sampleEnv(server, nil), runOptions{}); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}

	if got, want := out.stdout.String(), "OK\n\n[usage] input=1 output=2\n"; got != want {
		t.Errorf("stdout = %q, want %q", got, want)
	}
	if out.stderr.Len() != 0 {
		t.Errorf("stderr = %q", out.stderr.String())
	}
	r := server.Requests()[0]
	if r.URL != "/anthropic/v1/messages" || r.Header.Get("Authorization") != "Bearer sample-key" {
		t.Errorf("request = %s %v", r.URL, r.Header)
	}
	for _, name := range []string{"X-Api-Key", "Anthropic-Beta"} {
		if r.Header.Get(name) != "" {
			t.Errorf("%s must be absent", name)
		}
	}
	if r.Header.Get("Anthropic-Version") == "" || r.Header.Get("Anthropic-Version") == "2023-06-01" {
		t.Errorf("the SDK's own anthropic-version must be used, got %q", r.Header.Get("Anthropic-Version"))
	}
	wantBody := `"max_tokens":1024`
	if !strings.Contains(r.Body, wantBody) || !strings.Contains(r.Body, `"model":"sample-deployment"`) || !strings.Contains(r.Body, "What are 3 things to visit in Seattle?") {
		t.Errorf("body = %s", r.Body)
	}
}

func TestHonoursAPIKeyHeaderAndAPIVersion(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(textReply))
	var out output

	environment := sampleEnv(server, map[string]string{"API_KEY_HEADER": "x-api-key", "ANTHROPIC_API_VERSION": "2023-06-01"})
	if code := out.run(nil, environment, runOptions{}); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}

	r := server.Requests()[0]
	if r.Header.Get("X-Api-Key") != "sample-key" || r.Header.Get("Authorization") != "" || r.Header.Get("Anthropic-Version") != "2023-06-01" {
		t.Errorf("headers = %v", r.Header)
	}
}

func TestReadsTheLegacyVariableNames(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(textReply))
	var out output
	environment := map[string]string{"CLAUDE_BASE_URL": server.URL, "CLAUDE_DEPLOYMENT_NAME": "legacy-deployment", "AUTH_MODE": "api_key", "CLAUDE_API_KEY": "legacy-key"}

	if code := out.run(nil, environment, runOptions{}); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}

	r := server.Requests()[0]
	if r.URL != "/v1/messages" || r.Header.Get("Authorization") != "Bearer legacy-key" || !strings.Contains(r.Body, `"model":"legacy-deployment"`) {
		t.Errorf("request = %s %v %s", r.URL, r.Header, r.Body)
	}
}

func TestBearerTokenForEveryAttemptAndNoAmbientCredentials(t *testing.T) {
	testserver.CleanEnvironment(t)
	t.Setenv("ANTHROPIC_API_KEY", "ambient-key-canary")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "ambient-token-canary")
	t.Setenv("ANTHROPIC_PROFILE", "nonexistent-canary-profile")
	t.Setenv("ANTHROPIC_CUSTOM_HEADERS", "x-api-key: header-canary")
	server := testserver.New(t, func(w http.ResponseWriter, r *http.Request, count int) {
		if count < 2 {
			testserver.Error(500, "retry-after-ms", "1")(w, r, count)
			return
		}
		testserver.Respond(textReply)(w, r, count)
	})
	var calls atomic.Int32
	var out output
	options := runOptions{clientOverrides: clientOverrides{tokenProvider: func(context.Context) (string, error) {
		return fmt.Sprintf("entra-test-token-%d", calls.Add(1)), nil
	}}}

	// The canonical profile needs an explicit AUTH_MODE.
	code := out.run(nil, map[string]string{"ANTHROPIC_BASE_URL": server.URL, "ANTHROPIC_MODEL": "sample-deployment", "AUTH_MODE": "bearer"}, options)

	if code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, out.stderr.String())
	}
	requests := server.Requests()
	if len(requests) != 2 {
		t.Fatalf("got %d requests", len(requests))
	}
	for i, r := range requests {
		if got, want := r.Header.Get("Authorization"), fmt.Sprintf("Bearer entra-test-token-%d", i+1); got != want {
			t.Errorf("attempt %d Authorization = %q, want %q", i, got, want)
		}
		if r.Header.Get("X-Api-Key") != "" || r.Header.Get("Anthropic-Beta") != "" || strings.Contains(fmt.Sprint(r.Header), "canary") {
			t.Errorf("headers = %v", r.Header)
		}
	}
}

func TestStreamsOnlyTheTextAndUsesACustomPrompt(t *testing.T) {
	testserver.CleanEnvironment(t)
	for _, flagForm := range []string{"-stream", "--stream"} {
		server := testserver.New(t, testserver.Stream(
			testserver.Block{Kind: "thinking", Text: "not for display"},
			testserver.Block{Kind: "text", Text: "Hello"},
			testserver.Block{Kind: "text", Text: " there"},
		))
		var out output

		if code := out.run([]string{flagForm, "Say", "hi"}, sampleEnv(server, nil), runOptions{}); code != 0 {
			t.Fatalf("%s: exit code %d, stderr %q", flagForm, code, out.stderr.String())
		}

		if got := out.stdout.String(); got != "Hello there\n" {
			t.Errorf("%s: stdout = %q", flagForm, got)
		}
		body := server.Requests()[0].Body
		for _, want := range []string{`"stream":true`, `"max_tokens":1024`, `"content":[{"text":"Say hi"`} {
			if !strings.Contains(body, want) {
				t.Errorf("%s: body %s lacks %s", flagForm, body, want)
			}
		}
	}
}

func TestRepliesWithoutTextExitNonzero(t *testing.T) {
	testserver.CleanEnvironment(t)
	cases := map[string]string{
		"thinking only": thinkingOnly,
		"empty":         testserver.Message("end_turn"),
		"blank text":    testserver.Message("end_turn", testserver.TextBlock("  \n")),
	}
	for name, reply := range cases {
		server := testserver.New(t, testserver.Respond(reply))
		var out output
		if code := out.run(nil, sampleEnv(server, nil), runOptions{}); code != 1 {
			t.Errorf("%s: exit code %d", name, code)
		}
		if !strings.Contains(out.stderr.String(), "No text response (stop_reason=") {
			t.Errorf("%s: stderr = %q", name, out.stderr.String())
		}
		if strings.Contains(out.stdout.String(), "not for display") || strings.Contains(out.stdout.String(), "[usage]") {
			t.Errorf("%s: stdout = %q", name, out.stdout.String())
		}
	}
	server := testserver.New(t, testserver.Respond(thinkingOnly))
	var out output
	out.run(nil, sampleEnv(server, nil), runOptions{})
	if !strings.Contains(out.stderr.String(), "max_tokens") {
		t.Errorf("stderr = %q", out.stderr.String())
	}
}

func TestAStreamWithoutTextExitsNonzero(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Stream(testserver.Block{Kind: "thinking", Text: "not for display"}))
	var out output

	if code := out.run([]string{"-stream"}, sampleEnv(server, nil), runOptions{}); code != 1 {
		t.Errorf("exit code %d", code)
	}

	if !strings.Contains(out.stderr.String(), "No text response") || strings.Contains(out.stdout.String(), "not for display") {
		t.Errorf("stdout %q stderr %q", out.stdout.String(), out.stderr.String())
	}
}

func TestHTTPFailuresAreReportedWithoutSecrets(t *testing.T) {
	testserver.CleanEnvironment(t)
	for _, stream := range []bool{false, true} {
		for _, status := range []int{401, 403, 404, 429, 500} {
			server := testserver.New(t, testserver.Error(status))
			var out output
			args := []string(nil)
			if stream {
				args = []string{"-stream"}
			}

			code := out.run(args, sampleEnv(server, nil), fastRetries())

			if code != 1 {
				t.Errorf("status %d: exit code %d", status, code)
			}
			if want := fmt.Sprintf("HTTP %d (api_error)", status); !strings.Contains(out.stderr.String(), want) {
				t.Errorf("status %d: stderr = %q", status, out.stderr.String())
			}
			for _, secret := range []string{"sample-key", server.URL, strings.TrimPrefix(server.URL, "http://"), "sample-deployment", "test failure", "Request-ID"} {
				if strings.Contains(out.stderr.String(), secret) {
					t.Errorf("status %d: %q leaked: %s", status, secret, out.stderr.String())
				}
			}
			if out.stdout.Len() != 0 && !(stream && out.stdout.String() == "\n") {
				t.Errorf("status %d: stdout = %q", status, out.stdout.String())
			}
		}
	}
}

func TestARedirectIsAnErrorAndIsNotFollowed(t *testing.T) {
	testserver.CleanEnvironment(t)
	other := testserver.New(t, testserver.Respond(textReply))
	server := testserver.New(t, testserver.Redirect(http.StatusTemporaryRedirect, other.URL+"/v1/messages"))
	var out output

	if code := out.run(nil, sampleEnv(server, nil), fastRetries()); code != 1 {
		t.Errorf("exit code %d", code)
	}

	if !strings.Contains(out.stderr.String(), "redirect") || strings.Contains(out.stderr.String(), other.URL) {
		t.Errorf("stderr = %q", out.stderr.String())
	}
	if other.Count() != 0 {
		t.Errorf("the redirect target saw %d requests", other.Count())
	}
}

func TestCredentialFailuresDoNotPrintTheProviderMessage(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(textReply))
	environment := map[string]string{"ANTHROPIC_BASE_URL": server.URL, "ANTHROPIC_MODEL": "sample-deployment", "AUTH_MODE": "bearer"}
	options := runOptions{clientOverrides: clientOverrides{
		maxRetries: retries(0),
		tokenProvider: func(context.Context) (string, error) {
			return "", errors.New("tenant details that must not be printed")
		},
	}}
	for _, args := range [][]string{nil, {"-stream"}} {
		var out output

		if code := out.run(args, environment, options); code != 1 {
			t.Errorf("%v: exit code %d", args, code)
		}

		if !strings.Contains(out.stderr.String(), "The credential provider failed.") || strings.Contains(out.stderr.String(), "tenant details") {
			t.Errorf("%v: stderr = %q", args, out.stderr.String())
		}
	}
	if server.Count() != 0 {
		t.Errorf("no request may be sent, got %d", server.Count())
	}
}

func TestMissingConfigurationExitsNonzeroWithoutContactingAnything(t *testing.T) {
	testserver.CleanEnvironment(t)
	var out output

	if code := out.run(nil, nil, runOptions{}); code != 1 {
		t.Errorf("exit code %d", code)
	}

	if !strings.HasPrefix(out.stderr.String(), "Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL") || out.stdout.Len() != 0 {
		t.Errorf("stdout %q stderr %q", out.stdout.String(), out.stderr.String())
	}
}

func TestNoCredentialGoesToTheEndpointOfTheOtherVariableFamily(t *testing.T) {
	testserver.CleanEnvironment(t)
	native := testserver.New(t, testserver.Respond(textReply))
	legacy := testserver.New(t, testserver.Respond(textReply))
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"canonical URL, legacy model and key",
			map[string]string{"ANTHROPIC_BASE_URL": native.URL, "AUTH_MODE": "api_key", "CLAUDE_DEPLOYMENT_NAME": "legacy-model", "CLAUDE_API_KEY": "legacy-key-canary"},
			"ANTHROPIC_MODEL is required"},
		{"canonical URL and model, legacy key",
			map[string]string{"ANTHROPIC_BASE_URL": native.URL, "ANTHROPIC_MODEL": "native-model", "AUTH_MODE": "api_key", "CLAUDE_API_KEY": "legacy-key-canary"},
			"requires ANTHROPIC_API_KEY"},
		{"legacy URL and model, canonical key",
			map[string]string{"CLAUDE_BASE_URL": legacy.URL, "CLAUDE_DEPLOYMENT_NAME": "legacy-model", "AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-key-canary"},
			"requires CLAUDE_API_KEY"},
		{"legacy URL, canonical model and key",
			map[string]string{"CLAUDE_BASE_URL": legacy.URL, "ANTHROPIC_MODEL": "native-model", "AUTH_MODE": "api_key", "ANTHROPIC_API_KEY": "native-key-canary"},
			"CLAUDE_DEPLOYMENT_NAME is required"},
	}
	for _, c := range cases {
		var out output
		if code := out.run(nil, c.env, runOptions{}); code != 1 {
			t.Errorf("%s: exit code %d", c.name, code)
		}
		if !strings.Contains(out.stderr.String(), c.want) || strings.Contains(out.stderr.String(), "canary") {
			t.Errorf("%s: stderr = %q", c.name, out.stderr.String())
		}
	}
	if native.Count()+legacy.Count() != 0 {
		t.Errorf("nothing may be sent, got %d and %d requests", native.Count(), legacy.Count())
	}
}

func TestOnlyTheSelectedFamilyIsUsedWhenBothAreComplete(t *testing.T) {
	testserver.CleanEnvironment(t)
	native := testserver.New(t, testserver.Respond(textReply))
	legacy := testserver.New(t, testserver.Respond(textReply))
	both := map[string]string{
		"ANTHROPIC_BASE_URL": native.URL + "/anthropic", "ANTHROPIC_MODEL": "native-model", "ANTHROPIC_API_KEY": "native-key",
		"CLAUDE_BASE_URL": legacy.URL, "CLAUDE_DEPLOYMENT_NAME": "legacy-model", "CLAUDE_API_KEY": "legacy-key",
		"AUTH_MODE": "api_key",
	}
	var first, second output

	if code := first.run(nil, both, runOptions{}); code != 0 {
		t.Fatalf("canonical: exit code %d, stderr %q", code, first.stderr.String())
	}
	legacyOnly := map[string]string{}
	for k, v := range both {
		if k != "ANTHROPIC_BASE_URL" && k != "ANTHROPIC_MODEL" {
			legacyOnly[k] = v // an ambient ANTHROPIC_API_KEY stays, and must not matter
		}
	}
	if code := second.run(nil, legacyOnly, runOptions{}); code != 0 {
		t.Fatalf("legacy: exit code %d, stderr %q", code, second.stderr.String())
	}

	if native.Count() != 1 || legacy.Count() != 1 {
		t.Fatalf("requests: native=%d legacy=%d", native.Count(), legacy.Count())
	}
	nativeRequest, legacyRequest := native.Requests()[0], legacy.Requests()[0]
	if nativeRequest.URL != "/anthropic/v1/messages" || nativeRequest.Header.Get("Authorization") != "Bearer native-key" || !strings.Contains(nativeRequest.Body, `"model":"native-model"`) {
		t.Errorf("canonical request = %s %v %s", nativeRequest.URL, nativeRequest.Header, nativeRequest.Body)
	}
	if legacyRequest.Header.Get("Authorization") != "Bearer legacy-key" || !strings.Contains(legacyRequest.Body, `"model":"legacy-model"`) {
		t.Errorf("legacy request = %v %s", legacyRequest.Header, legacyRequest.Body)
	}
}

func TestACanonicalURLGetsATokenOnlyWhenBearerIsChosenExplicitly(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Respond(textReply))
	var calls atomic.Int32
	options := runOptions{clientOverrides: clientOverrides{tokenProvider: func(context.Context) (string, error) {
		return fmt.Sprintf("entra-test-token-%d", calls.Add(1)), nil
	}}}
	canonical := map[string]string{"ANTHROPIC_BASE_URL": server.URL, "ANTHROPIC_MODEL": "sample-deployment"}

	var implicit output
	if code := implicit.run(nil, canonical, options); code != 1 || !strings.Contains(implicit.stderr.String(), "AUTH_MODE must be set explicitly") {
		t.Errorf("implicit: exit code %d, stderr %q", code, implicit.stderr.String())
	}
	if calls.Load() != 0 || server.Count() != 0 {
		t.Errorf("no token may be acquired and nothing sent: calls=%d requests=%d", calls.Load(), server.Count())
	}

	var explicit output
	canonical["AUTH_MODE"] = "bearer"
	if code := explicit.run(nil, canonical, options); code != 0 {
		t.Fatalf("explicit: exit code %d, stderr %q", code, explicit.stderr.String())
	}
	var legacy output
	if code := legacy.run(nil, map[string]string{"CLAUDE_BASE_URL": server.URL, "CLAUDE_DEPLOYMENT_NAME": "legacy-deployment"}, options); code != 0 {
		t.Fatalf("legacy default: exit code %d, stderr %q", code, legacy.stderr.String())
	}
	requests := server.Requests()
	if len(requests) != 2 || requests[0].Header.Get("Authorization") != "Bearer entra-test-token-1" || requests[1].Header.Get("Authorization") != "Bearer entra-test-token-2" {
		t.Errorf("requests = %v", requests)
	}
}

func TestAnUnreachableEndpointIsReportedWithoutNamingIt(t *testing.T) {
	testserver.CleanEnvironment(t)
	closed := testserver.New(t, testserver.Respond(textReply))
	environment := sampleEnv(closed, nil)
	closed.CloseClientConnections()
	closed.Close()
	var out output

	if code := out.run(nil, environment, fastRetries()); code != 1 {
		t.Errorf("exit code %d", code)
	}

	if got := out.stderr.String(); got != "Could not connect to the endpoint.\n" {
		t.Errorf("stderr = %q", got)
	}
}

func TestTheWholeCallHasADeadline(t *testing.T) {
	testserver.CleanEnvironment(t)
	server := testserver.New(t, testserver.Hang)
	var out output

	code := out.run(nil, sampleEnv(server, nil), runOptions{totalTimeout: 100 * time.Millisecond})

	if code != 1 || !strings.Contains(out.stderr.String(), "timed out after 0.1 seconds") || strings.Contains(out.stderr.String(), server.URL) {
		t.Errorf("exit code %d, stderr %q", code, out.stderr.String())
	}
}

func TestHelpAndUnknownFlags(t *testing.T) {
	var help output
	if code := help.run([]string{"-h"}, nil, runOptions{}); code != 0 || !strings.Contains(help.stdout.String(), "Usage: go run .") {
		t.Errorf("help: exit code %d, stdout %q", code, help.stdout.String())
	}
	var unknown output
	if code := unknown.run([]string{"-nope"}, nil, runOptions{}); code != 2 || !strings.Contains(unknown.stderr.String(), "Usage: go run .") {
		t.Errorf("unknown flag: exit code %d, stderr %q", code, unknown.stderr.String())
	}
}

func TestTheProcessEnvironmentIsNotModified(t *testing.T) {
	testserver.CleanEnvironment(t)
	t.Setenv("ANTHROPIC_FOUNDRY_RESOURCE", "unchanged-resource")
	server := testserver.New(t, testserver.Respond(textReply))
	before := strings.Join(os.Environ(), "\x00")
	var out output

	out.run(nil, sampleEnv(server, nil), runOptions{})

	if strings.Join(os.Environ(), "\x00") != before {
		t.Error("the process environment changed")
	}
}

const helperEnv = "CLAUDE_SAMPLE_HELPER_PROCESS"

// TestHelperProcess is the command itself, started again by TestRunsAsACommand.
func TestHelperProcess(t *testing.T) {
	if os.Getenv(helperEnv) != "1" {
		t.Skip("only runs as a helper process")
	}
	args := os.Args
	for i, arg := range args {
		if arg == "--" {
			args = args[i+1:]
			break
		}
	}
	os.Exit(run(context.Background(), args, os.Getenv, os.Stdout, os.Stderr, runOptions{}))
}

func TestRunsAsACommand(t *testing.T) {
	testserver.CleanEnvironment(t)
	ok := testserver.New(t, testserver.Respond(textReply))
	streamed := testserver.New(t, testserver.Stream(testserver.Block{Kind: "text", Text: "Hello"}))
	denied := testserver.New(t, testserver.Error(401))
	command := func(args []string, extra map[string]string) (int, string, string) {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run=^TestHelperProcess$", "--"}, args...)...)
		cmd.Env = append(os.Environ(), helperEnv+"=1")
		for k, v := range extra {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		err := cmd.Run()
		code := 0
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("running the command: %v", err)
		}
		return code, stdout.String(), stderr.String()
	}

	if code, stdout, stderr := command(nil, sampleEnv(ok, nil)); code != 0 || stdout != "OK\n\n[usage] input=1 output=2\n" || stderr != "" {
		t.Errorf("plain: %d %q %q", code, stdout, stderr)
	}
	if code, stdout, stderr := command([]string{"-stream"}, sampleEnv(streamed, nil)); code != 0 || stdout != "Hello\n" || stderr != "" {
		t.Errorf("stream: %d %q %q", code, stdout, stderr)
	}
	code, stdout, stderr := command(nil, sampleEnv(denied, nil))
	if code != 1 || stdout != "" || !strings.Contains(stderr, "HTTP 401") || strings.Contains(stderr, "sample-key") {
		t.Errorf("failure: %d %q %q", code, stdout, stderr)
	}
	if code, _, _ := command(nil, nil); code != 1 {
		t.Errorf("missing configuration: exit code %d", code)
	}
	if code, _, _ := command([]string{"-bogus"}, nil); code != 2 {
		t.Errorf("unknown flag: exit code %d", code)
	}
}
