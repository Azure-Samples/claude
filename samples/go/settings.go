package main

import "fmt"

// configError is a problem with the environment configuration. Its message names only
// variables, never values.
type configError struct{ message string }

func (e *configError) Error() string { return e.message }

const (
	defaultTokenScope = "https://ai.azure.com/.default"
	defaultCredential = "AzureCliCredential"

	profileCanonical = "anthropic" // the ANTHROPIC_* variable family
	profileLegacy    = "claude"    // the CLAUDE_* variable family
)

type authSettings struct {
	mode string // "bearer" or "api_key"

	// bearer
	credential, tenantID, clientID, scope string

	// api_key
	apiKey, keyHeader string
}

type settings struct {
	profile        string
	baseURL, model string
	// apiVersion is sent as anthropic-version only when ANTHROPIC_API_VERSION is set;
	// otherwise the SDK default applies.
	apiVersion string
	auth       authSettings
}

type profileVariables struct {
	baseURL, model, apiKey string
	// otherModel and otherKey name the other family's variables in errors; they are never
	// read for this profile.
	otherModel, otherKey string
	// explicitAuthMode: the canonical profile never defaults to a token, so an ambient URL
	// cannot silently receive one.
	explicitAuthMode bool
}

var profiles = map[string]profileVariables{
	profileCanonical: {
		baseURL: "ANTHROPIC_BASE_URL", model: "ANTHROPIC_MODEL", apiKey: "ANTHROPIC_API_KEY",
		otherModel: "CLAUDE_DEPLOYMENT_NAME", otherKey: "CLAUDE_API_KEY",
		explicitAuthMode: true,
	},
	profileLegacy: {
		baseURL: "CLAUDE_BASE_URL", model: "CLAUDE_DEPLOYMENT_NAME", apiKey: "CLAUDE_API_KEY",
		otherModel: "ANTHROPIC_MODEL", otherKey: "ANTHROPIC_API_KEY",
	},
}

// loadSettings selects the canonical profile when ANTHROPIC_BASE_URL is set and the legacy one
// when only CLAUDE_BASE_URL is. The URL, model and key all come from the selected family, so a
// value from one family is never combined with another family's endpoint.
func loadSettings(getenv func(string) string) (settings, error) {
	profile, baseURL := "", ""
	if value := getenv("ANTHROPIC_BASE_URL"); value != "" {
		profile, baseURL = profileCanonical, value
	} else if value := getenv("CLAUDE_BASE_URL"); value != "" {
		profile, baseURL = profileLegacy, value
	}
	if profile == "" {
		return settings{}, &configError{"Set ANTHROPIC_BASE_URL, ANTHROPIC_MODEL and AUTH_MODE, or the legacy CLAUDE_BASE_URL and CLAUDE_DEPLOYMENT_NAME."}
	}
	names := profiles[profile]

	model := getenv(names.model)
	if model == "" {
		return settings{}, &configError{fmt.Sprintf("%s is set, so %s is required; %s is not used with it.", names.baseURL, names.model, names.otherModel)}
	}
	mode := getenv("AUTH_MODE")
	if mode == "" {
		if names.explicitAuthMode {
			return settings{}, &configError{fmt.Sprintf("%s is set, so AUTH_MODE must be set explicitly to bearer or api_key.", names.baseURL)}
		}
		mode = "bearer"
	}
	loaded := settings{profile: profile, baseURL: baseURL, model: model, apiVersion: getenv("ANTHROPIC_API_VERSION")}

	switch mode {
	case "bearer":
		loaded.auth = authSettings{
			mode:       mode,
			credential: orDefault(getenv("AZURE_TOKEN_CREDENTIALS"), defaultCredential),
			tenantID:   getenv("AZURE_TENANT_ID"),
			clientID:   getenv("AZURE_CLIENT_ID"),
			scope:      orDefault(getenv("TOKEN_SCOPE"), defaultTokenScope),
		}
	case "api_key":
		apiKey := getenv(names.apiKey)
		if apiKey == "" {
			return settings{}, &configError{fmt.Sprintf("AUTH_MODE=api_key with %s requires %s; %s is not used with it.", names.baseURL, names.apiKey, names.otherKey)}
		}
		loaded.auth = authSettings{mode: mode, apiKey: apiKey, keyHeader: orDefault(getenv("API_KEY_HEADER"), "Authorization")}
	default:
		return settings{}, &configError{"AUTH_MODE must be bearer or api_key."}
	}
	return loaded, nil
}

func orDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
