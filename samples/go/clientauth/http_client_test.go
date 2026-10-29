package clientauth

import (
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestDefaultHTTPClientMirrorsTheSDKDefaultAndRefusesRedirects(t *testing.T) {
	shared := http.DefaultTransport.(*http.Transport)
	client := httpClient(nil)

	transport, ok := client.Transport.(*http.Transport)
	if !ok || transport == shared {
		t.Fatalf("the transport must be a clone of http.DefaultTransport, got %T", client.Transport)
	}
	if transport.ResponseHeaderTimeout != 10*time.Minute {
		t.Errorf("ResponseHeaderTimeout = %v, want the SDK default of 10 minutes", transport.ResponseHeaderTimeout)
	}
	if shared.ResponseHeaderTimeout != 0 {
		t.Error("http.DefaultTransport must not be modified")
	}
	if err := client.CheckRedirect(nil, nil); !errors.Is(err, ErrRedirectRefused) {
		t.Errorf("CheckRedirect = %v", err)
	}
}

func TestASuppliedClientKeepsItsTransportAndIsNotModified(t *testing.T) {
	transport := &http.Transport{}
	supplied := &http.Client{Transport: transport, Timeout: 7 * time.Second}

	client := httpClient(supplied)

	if client.Transport != transport || client.Timeout != 7*time.Second {
		t.Errorf("transport or timeout changed: %T %v", client.Transport, client.Timeout)
	}
	if transport.ResponseHeaderTimeout != 0 {
		t.Error("the supplied transport must not be modified")
	}
	if supplied.CheckRedirect != nil {
		t.Error("the supplied client must not be modified")
	}
	if err := client.CheckRedirect(nil, nil); !errors.Is(err, ErrRedirectRefused) {
		t.Errorf("CheckRedirect = %v", err)
	}
}
