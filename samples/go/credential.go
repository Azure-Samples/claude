package main

import (
	"context"
	"fmt"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"

	"github.com/Azure-Samples/claude/samples/go/clientauth"
)

// credentialFactories lets tests observe which credential is built and with which options.
type credentialFactories struct {
	azureCLI          func(*azidentity.AzureCLICredentialOptions) (azcore.TokenCredential, error)
	azureDeveloperCLI func(*azidentity.AzureDeveloperCLICredentialOptions) (azcore.TokenCredential, error)
	managedIdentity   func(*azidentity.ManagedIdentityCredentialOptions) (azcore.TokenCredential, error)
}

var azureIdentityCredentials = credentialFactories{
	azureCLI: func(o *azidentity.AzureCLICredentialOptions) (azcore.TokenCredential, error) {
		credential, err := azidentity.NewAzureCLICredential(o)
		if err != nil {
			return nil, err
		}
		return credential, nil
	},
	azureDeveloperCLI: func(o *azidentity.AzureDeveloperCLICredentialOptions) (azcore.TokenCredential, error) {
		credential, err := azidentity.NewAzureDeveloperCLICredential(o)
		if err != nil {
			return nil, err
		}
		return credential, nil
	},
	managedIdentity: func(o *azidentity.ManagedIdentityCredentialOptions) (azcore.TokenCredential, error) {
		credential, err := azidentity.NewManagedIdentityCredential(o)
		if err != nil {
			return nil, err
		}
		return credential, nil
	},
}

// createCredential builds exactly the credential named by AZURE_TOKEN_CREDENTIALS, with no
// fallback chain. The tenant applies to the two CLI credentials and the client ID to the
// managed identity.
func createCredential(source, tenantID, clientID string, factories credentialFactories) (azcore.TokenCredential, error) {
	switch source {
	case "AzureCliCredential":
		return factories.azureCLI(&azidentity.AzureCLICredentialOptions{TenantID: tenantID})
	case "AzureDeveloperCliCredential":
		return factories.azureDeveloperCLI(&azidentity.AzureDeveloperCLICredentialOptions{TenantID: tenantID})
	case "ManagedIdentityCredential":
		options := &azidentity.ManagedIdentityCredentialOptions{}
		if clientID != "" {
			options.ID = azidentity.ClientID(clientID)
		}
		return factories.managedIdentity(options)
	default:
		return nil, &configError{"AZURE_TOKEN_CREDENTIALS must be AzureCliCredential, AzureDeveloperCliCredential, ManagedIdentityCredential."}
	}
}

// tokenProvider asks the credential for a token on every call, with no cache or retry of its
// own. ManagedIdentityCredential keeps the tokens it receives and refreshes them before they
// expire, while AzureCliCredential and AzureDeveloperCliCredential run their command each
// time they are asked, so each HTTP attempt with a CLI credential starts a short-lived process.
func tokenProvider(credential azcore.TokenCredential, scope string) clientauth.CredentialProvider {
	return func(ctx context.Context) (string, error) {
		token, err := credential.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{scope}})
		if err != nil {
			return "", err
		}
		return token.Token, nil
	}
}

type credentialSetupError struct{ cause error }

func (e *credentialSetupError) Error() string {
	return fmt.Sprintf("could not create the Azure credential: %v", e.cause)
}
func (e *credentialSetupError) Unwrap() error { return e.cause }
