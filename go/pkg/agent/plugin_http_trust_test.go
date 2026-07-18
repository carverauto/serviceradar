package agent

import (
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestPluginHTTPClientWithTrustedCAsAugmentsSystemRoots(t *testing.T) {
	t.Parallel()

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	caPath := filepath.Join(t.TempDir(), "integration-ca.pem")
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(caPath, caPEM, 0o600); err != nil {
		t.Fatalf("write CA bundle: %v", err)
	}

	client, err := pluginHTTPClientWithTrustedCAs([]string{caPath})
	if err != nil {
		t.Fatalf("build plugin HTTP client: %v", err)
	}
	require.NotNil(t, client, "expected configured plugin HTTP client")

	request, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := client.Do(request)
	if err != nil {
		t.Fatalf("verified request with configured CA: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
	transport, ok := client.Transport.(*http.Transport)
	if !ok || transport.TLSClientConfig == nil {
		t.Fatalf("expected TLS transport, got %T", client.Transport)
	}
	if transport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("configured CA must not disable certificate verification")
	}
}

func TestPluginHTTPClientWithTrustedCAsFailsClosed(t *testing.T) {
	t.Parallel()

	for name, paths := range map[string][]string{
		"relative path": {"ca.pem"},
		"missing file":  {filepath.Join(t.TempDir(), "missing.pem")},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			client, err := pluginHTTPClientWithTrustedCAs(paths)
			if err == nil || client != nil {
				t.Fatalf("client=%v err=%v, want nil client and error", client, err)
			}
			if !errors.Is(err, errPluginHTTPTrustUnavailable) {
				t.Fatalf("error = %v, want %v", err, errPluginHTTPTrustUnavailable)
			}
		})
	}
}

func TestUnavailablePluginHTTPClientRejectsTransport(t *testing.T) {
	t.Parallel()

	expected := fmt.Errorf("test invalid CA configuration: %w", errPluginHTTPTrustUnavailable)
	client := unavailablePluginHTTPClient(expected)
	request, err := http.NewRequestWithContext(
		t.Context(),
		http.MethodGet,
		"https://awx.example.test/api/v2/ping/",
		nil,
	)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := client.Do(request)
	if resp != nil {
		defer func() { _ = resp.Body.Close() }()
	}
	if !errors.Is(err, expected) {
		t.Fatalf("request error = %v, want %v", err, expected)
	}
}

func TestInvalidPluginHTTPTrustRemainsUnavailableForInsecureRequest(t *testing.T) {
	t.Parallel()

	var dials atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		dials.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	configuredClient, trustErr := pluginHTTPClientWithTrustedCAs([]string{
		filepath.Join(t.TempDir(), "missing-ca.pem"),
	})
	if trustErr == nil || configuredClient != nil {
		t.Fatalf("client=%v err=%v, want invalid trust configuration", configuredClient, trustErr)
	}

	unavailable := unavailablePluginHTTPClient(trustErr)
	client := pluginHTTPClient(unavailable, true, time.Second)
	request, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := client.Do(request)
	if resp != nil {
		_ = resp.Body.Close()
		t.Fatalf("response = %#v, want no network response", resp)
	}
	if !errors.Is(err, errPluginHTTPTrustUnavailable) {
		t.Fatalf("request error = %v, want %v", err, errPluginHTTPTrustUnavailable)
	}
	if got := dials.Load(); got != 0 {
		t.Fatalf("network requests = %d, want 0", got)
	}
	if client.Transport != unavailable.Transport {
		t.Fatalf("transport = %T, want original unavailable transport", client.Transport)
	}
}
