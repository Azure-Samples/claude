package main

import (
	"errors"
	"net/http"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2"

	"github.com/Azure-Samples/claude/samples/go/clientauth"
)

// clientOverrides lets tests replace the Microsoft Entra ID token provider and the transport.
type clientOverrides struct {
	tokenProvider  clientauth.CredentialProvider
	httpClient     *http.Client
	maxRetries     *int
	requestTimeout time.Duration
}

func configuredClient(s settings, overrides clientOverrides) (anthropic.Client, error) {
	options := clientauth.Options{
		BaseURL:        s.baseURL,
		APIVersion:     s.apiVersion,
		HTTPClient:     overrides.httpClient,
		MaxRetries:     overrides.maxRetries,
		RequestTimeout: overrides.requestTimeout,
	}
	if s.auth.mode == "api_key" {
		options.APIKey = s.auth.apiKey
		options.KeyHeader = s.auth.keyHeader
		return clientauth.CreateClient(options)
	}

	options.TokenProvider = overrides.tokenProvider
	if options.TokenProvider == nil {
		credential, err := createCredential(s.auth.credential, s.auth.tenantID, s.auth.clientID, azureIdentityCredentials)
		if err != nil {
			var config *configError
			if errors.As(err, &config) {
				return anthropic.Client{}, err
			}
			return anthropic.Client{}, &credentialSetupError{cause: err}
		}
		options.TokenProvider = tokenProvider(credential, s.auth.scope)
	}
	return clientauth.CreateClient(options)
}
