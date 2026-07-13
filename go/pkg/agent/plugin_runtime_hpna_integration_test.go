package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const hpnaWasmPathEnv = "SERVICERADAR_HPNA_WASM_PATH"

func TestHPNAPluginRunsThroughAgentHost(t *testing.T) {
	wasmPath := strings.TrimSpace(os.Getenv(hpnaWasmPathEnv))
	if wasmPath == "" {
		t.Skipf("%s is not set", hpnaWasmPathEnv)
	}
	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read HPNA Wasm module: %v", err)
	}

	var tokenRequests atomic.Int32
	var inventoryRequests atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oauth/token":
			tokenRequests.Add(1)
			if r.Method != http.MethodPost {
				http.Error(w, "method", http.StatusMethodNotAllowed)
				return
			}
			if err := r.ParseForm(); err != nil {
				http.Error(w, "form", http.StatusBadRequest)
				return
			}
			if r.Form.Get("username") != "svc-hpna" ||
				r.Form.Get("password") != "test-secret" ||
				r.Form.Get("grant_type") != "password" {
				http.Error(w, "credentials", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"access_token":"short-lived-token"}`))
		case "/api/v1/commands":
			inventoryRequests.Add(1)
			if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer short-lived-token" {
				http.Error(w, "authorization", http.StatusUnauthorized)
				return
			}
			var request struct {
				Command    string         `json:"command"`
				Parameters map[string]any `json:"parameters"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				http.Error(w, "request", http.StatusBadRequest)
				return
			}
			if request.Command != "list device" || request.Parameters["type"] != "Switch" {
				http.Error(w, "query", http.StatusBadRequest)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`[{"deviceID":101,"hostName":"iad-asw-01","primaryIPAddress":"192.0.2.10","primaryMACAddress":"00:11:22:33:44:55","serialNumber":"SER-101","vendor":"Cisco","model":"C9300","deviceType":"Switch","siteName":"IAD","managementStatus":"Managed"}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	parsedURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse HPNA test URL: %v", err)
	}
	port, err := strconv.Atoi(parsedURL.Port())
	if err != nil {
		t.Fatalf("parse HPNA test port: %v", err)
	}
	tokenURL := server.URL + "/oauth/token"
	apiURL := server.URL + "/api/v1/commands"
	paramsJSON := mustJSON(t, map[string]any{
		"instance_id": "lab-hpna",
		"token_url":   tokenURL,
		"api_url":     apiURL,
		"queries": []map[string]any{{
			"name":       "switches",
			"parameters": map[string]any{"type": "Switch"},
		}},
		"page_size":               100,
		"max_rows":                1000,
		"max_result_bytes":        10 * 1024 * 1024,
		"request_timeout_seconds": 5,
		"max_retries":             0,
	})
	permissionsJSON := mustJSON(t, map[string]any{
		"allowed_domains": []string{parsedURL.Hostname()},
		"allowed_ports":   []int{port},
	})

	const objectKey = "hpna_inventory.wasm"
	localStore := t.TempDir()
	if err := os.WriteFile(filepath.Join(localStore, objectKey), wasm, 0o600); err != nil {
		t.Fatalf("stage HPNA Wasm module: %v", err)
	}
	resolver := &hpnaIntegrationCredentialResolver{}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:           logger.NewTestLogger(),
		CacheDir:         t.TempDir(),
		LocalStoreDir:    localStore,
		HTTPClient:       server.Client(),
		CredentialBroker: resolver,
	})
	defer manager.Stop()

	assignmentConfig := &proto.PluginAssignmentConfig{
		AssignmentId:    "hpna-inventory-lab",
		PluginId:        "hpna-inventory",
		PackageId:       "hpna-inventory-package",
		Name:            "HPNA Inventory",
		Entrypoint:      "run_check",
		Runtime:         "wasi-preview1",
		Enabled:         true,
		TimeoutSec:      30,
		WasmObjectKey:   objectKey,
		ParamsJson:      paramsJSON,
		PermissionsJson: permissionsJSON,
		Capabilities: []string{
			"get_config",
			"log",
			"submit_result",
			"http_request",
			pluginCapabilityActionResultIngest,
			pluginCapabilityActionOnly,
		},
	}
	assignment := newPluginAssignment(assignmentConfig, logger.NewTestLogger())
	manager.mu.Lock()
	manager.actions[assignment.AssignmentID] = assignment
	manager.mu.Unlock()

	expiresAt := time.Now().Add(time.Minute).UTC().Format(time.RFC3339)
	invocation := mustJSON(t, map[string]any{
		"schema":    "serviceradar.producer_schedule_invocation.v1",
		"action_id": "hpna.inventory.refresh",
		"credential_brokers": []credentialBrokerGrant{
			{
				Schema:              "serviceradar.edge_credential_broker_grant.v1",
				GrantID:             "hpna-token",
				CredentialSecretRef: "credentialref:network-credential-secret:hpna",
				Allow: credentialBrokerACL{
					Methods: []string{http.MethodPost},
					Hosts:   []string{parsedURL.Hostname()},
					Ports:   []int{port},
					Paths:   []string{"/oauth/token"},
				},
				Inject: map[string]string{
					"type":             "form_urlencoded",
					"method":           http.MethodPost,
					"host":             parsedURL.Hostname(),
					"path":             "/oauth/token",
					"field_username":   "username",
					"field_password":   "password",
					"fixed_grant_type": "password",
				},
				ExpiresAt: expiresAt,
			},
			{
				Schema:              "serviceradar.edge_credential_broker_grant.v1",
				GrantID:             "hpna-inventory",
				CredentialSecretRef: "credentialref:network-credential-secret:hpna",
				Allow: credentialBrokerACL{
					Methods: []string{http.MethodPost},
					Hosts:   []string{parsedURL.Hostname()},
					Ports:   []int{port},
					Paths:   []string{"/api/v1/commands"},
				},
				ExpiresAt: expiresAt,
			},
		},
	})

	ackPayload, err := manager.RunAction(
		t.Context(), assignment.AssignmentID, invocation, 30*time.Second,
	)
	if err != nil {
		t.Fatalf("run HPNA plugin through agent host: %v", err)
	}
	var ack map[string]any
	if err := json.Unmarshal(ackPayload, &ack); err != nil {
		t.Fatalf("decode action-result acknowledgement: %v", err)
	}
	queued := manager.DrainResults(1)
	if len(queued) != 1 {
		t.Fatalf("queued results = %d, want 1", len(queued))
	}
	if ack["schema"] != actionResultAckSchema || ack["status"] != "succeeded" || ack["device_count"] != float64(1) {
		t.Fatalf("unexpected action-result acknowledgement: %#v; result: %s", ack, queued[0].Payload)
	}
	if tokenRequests.Load() != 1 || inventoryRequests.Load() != 1 || resolver.calls.Load() != 1 {
		t.Fatalf(
			"requests token=%d inventory=%d credential_resolutions=%d, want 1 each",
			tokenRequests.Load(), inventoryRequests.Load(), resolver.calls.Load(),
		)
	}

	var result map[string]any
	if err := json.Unmarshal(queued[0].Payload, &result); err != nil {
		t.Fatalf("decode queued HPNA result: %v", err)
	}
	discoveries, ok := result["device_discovery"].([]any)
	if !ok || len(discoveries) != 1 {
		t.Fatalf("device discovery envelopes = %#v, want one", result["device_discovery"])
	}
	discovery, ok := discoveries[0].(map[string]any)
	if !ok || discovery["source"] != "hpna" {
		t.Fatalf("unexpected HPNA discovery envelope: %#v", discoveries[0])
	}
	devices, ok := discovery["devices"].([]any)
	if !ok || len(devices) != 1 {
		t.Fatalf("discovered devices = %#v, want one", discovery["devices"])
	}
	device := devices[0].(map[string]any)
	metadata := device["metadata"].(map[string]any)
	if device["device_id"] != "hpna:v1:lab-hpna:device:101" ||
		metadata["integration_id"] != "hpna:v1:lab-hpna:device:101" ||
		metadata["integration_type"] != "hpna" {
		t.Fatalf("unexpected HPNA identity metadata: device=%#v metadata=%#v", device, metadata)
	}
}

type hpnaIntegrationCredentialResolver struct {
	calls atomic.Int32
}

func (r *hpnaIntegrationCredentialResolver) ResolveCredentialGrant(
	_ context.Context,
	grant credentialBrokerGrant,
) (CredentialBrokerMaterial, error) {
	r.calls.Add(1)
	if grant.GrantID != "hpna-token" {
		return CredentialBrokerMaterial{}, fmt.Errorf("unexpected credential grant %q", grant.GrantID)
	}
	return CredentialBrokerMaterial{Fields: map[string]string{
		"username": "svc-hpna",
		"password": "test-secret",
	}}, nil
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal JSON fixture: %v", err)
	}
	return payload
}
