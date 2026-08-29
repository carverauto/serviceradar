package agent

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	actionFixtureAssignmentID           = "action-fixture-1"
	actionFixturePluginID               = "hello-wasm-action"
	actionFixtureObjectKey              = "hello_wasm.wasm"
	actionFixtureInvocationID           = "018f2fd1-f0ff-7cf0-9dc0-000000000001"
	sampleNorthboundFixtureAssignmentID = "sample-northbound-action"
	sampleNorthboundFixturePluginID     = "sample-northbound-nms"
	sampleNorthboundFixtureObjectKey    = "sample_northbound.wasm"
	resolvedToken                       = "resolved-token"
	testCredentialAPIURL                = "https://api.example.com/api/v1/devices"
)

func TestPluginManagerRunActionWithFixtureWasm(t *testing.T) {
	manager := newActionFixtureManager(t, actionFixtureObjectKey, &proto.PluginAssignmentConfig{
		AssignmentId:  actionFixtureAssignmentID,
		PluginId:      actionFixturePluginID,
		PackageId:     "fixture-package",
		Name:          "Hello Wasm Action",
		Entrypoint:    "run_check",
		Runtime:       "wasi-preview1",
		Enabled:       true,
		TimeoutSec:    5,
		WasmObjectKey: actionFixtureObjectKey,
		Capabilities:  []string{"get_config", "log", "submit_result"},
		ParamsJson:    []byte(`{"plugin_setting":"base-config"}`),
	})
	defer manager.Stop()

	payload := json.RawMessage(`{
		"invocation_id":"` + actionFixtureInvocationID + `",
		"descriptor_id":"fixture.hello.run",
		"targets":[{"kind":"device","device_uid":"sr:device-1","device_ip":"192.0.2.10"}],
		"input_values":{"reason":"integration-test"}
	}`)

	result, err := manager.RunAction(t.Context(), actionFixtureAssignmentID, payload, 10*time.Second)
	if err != nil {
		t.Fatalf("RunAction returned error: %v", err)
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode action result: %v\npayload: %s", err, result)
	}

	if got := decoded["status"]; got != "OK" {
		t.Fatalf("status = %v, want OK; payload: %s", got, result)
	}
	if got := decoded["summary"]; got != "hello from wasm (config received)" {
		t.Fatalf("summary = %v, want fixture config confirmation; payload: %s", got, result)
	}
	if queued := manager.DrainResults(1); len(queued) != 0 {
		t.Fatalf("action result should not be queued as scheduled output, got %d queued result(s)", len(queued))
	}
}

func TestPluginManagerActionAdmissionIsScopedToAssignment(t *testing.T) {
	t.Parallel()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{})
	defer manager.Stop()

	if !manager.acquireAction("inventory-primary") {
		t.Fatal("first action should acquire the assignment")
	}
	if manager.acquireAction("inventory-primary") {
		t.Fatal("overlapping action for the same assignment should be rejected")
	}
	if !manager.acquireAction("other-inventory") {
		t.Fatal("an unrelated assignment should be admitted")
	}

	manager.releaseAction("inventory-primary")
	if !manager.acquireAction("inventory-primary") {
		t.Fatal("assignment should be admitted after the active action completes")
	}

	manager.releaseAction("inventory-primary")
	manager.releaseAction("other-inventory")
}

func TestPluginManagerRunPluginVerbWithFixtureWasm(t *testing.T) {
	manager := newActionFixtureManager(t, actionFixtureObjectKey, &proto.PluginAssignmentConfig{
		AssignmentId:  actionFixtureAssignmentID,
		PluginId:      "awx",
		PackageId:     "fixture-package",
		Name:          "Hello Wasm Verb",
		Entrypoint:    "run_check",
		Runtime:       "wasi-preview1",
		Enabled:       true,
		TimeoutSec:    5,
		WasmObjectKey: actionFixtureObjectKey,
		Capabilities:  []string{"get_config", "log", "submit_result"},
	})
	defer manager.Stop()

	configJSON := json.RawMessage(`{
		"verb": "awx.ping",
		"base_url": "https://awx.example.com",
		"api_token": "resolved-by-credential-broker"
	}`)

	result, err := manager.RunPluginVerb(t.Context(), "awx", configJSON, nil, 10*time.Second)
	if err != nil {
		t.Fatalf("RunPluginVerb returned error: %v", err)
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode verb result: %v\npayload: %s", err, result)
	}

	if got := decoded["status"]; got != "OK" {
		t.Fatalf("status = %v, want OK; payload: %s", got, result)
	}
	if got := decoded["summary"]; got != "hello from wasm (config received)" {
		t.Fatalf("summary = %v, want config passthrough confirmation; payload: %s", got, result)
	}
	if queued := manager.DrainResults(1); len(queued) != 0 {
		t.Fatalf("verb result should not be queued as scheduled output, got %d queued result(s)", len(queued))
	}
}

func TestPluginManagerRunActionWithSampleNorthboundWasm(t *testing.T) {
	manager := newActionFixtureManager(t, sampleNorthboundFixtureObjectKey, &proto.PluginAssignmentConfig{
		AssignmentId:  sampleNorthboundFixtureAssignmentID,
		PluginId:      sampleNorthboundFixturePluginID,
		PackageId:     "sample-northbound-package",
		Name:          "Sample Northbound NMS",
		Entrypoint:    "run_check",
		Runtime:       "wasi-preview1",
		Enabled:       true,
		TimeoutSec:    5,
		WasmObjectKey: sampleNorthboundFixtureObjectKey,
		Capabilities:  []string{"get_config", "log", "submit_result"},
		ParamsJson: []byte(`{
			"api_base_url": "mock://lab-nms",
			"inventory_prefix": "lab",
			"interface_default_vlan": 410
		}`),
	})
	defer manager.Stop()

	deviceResult := runFixtureAction(t, manager, json.RawMessage(`{
		"schema": "serviceradar.northbound_action_invocation.v1",
		"invocation_id": "inv-device-1",
		"action_id": "sample.device.lookup",
		"targets": [{
			"kind": "device",
			"device_uid": "sr:device-1",
			"device_name": "edge-sw01",
			"device_ip": "192.0.2.10",
			"model": "EX4300"
		}],
		"input_values": {
			"query_mode": "full",
			"include_neighbors": true
		}
	}`))

	if got := deviceResult["status"]; got != "succeeded" {
		t.Fatalf("device status = %v, want succeeded; payload: %#v", got, deviceResult)
	}

	deviceTarget := firstTargetResult(t, deviceResult)
	deviceTargetResult := targetResultMap(t, deviceTarget)

	if got := deviceTargetResult["api_query"]; got != "GET /devices/192.0.2.10?mode=full" {
		t.Fatalf("device api query = %v", got)
	}
	if got := deviceTargetResult["external_inventory_id"]; got != "lab-sr-device-1" {
		t.Fatalf("device inventory id = %v", got)
	}
	if got := deviceTargetResult["neighbors_included"]; got != true {
		t.Fatalf("device neighbors_included = %v", got)
	}

	interfaceResult := runFixtureAction(t, manager, json.RawMessage(`{
		"schema": "serviceradar.northbound_action_invocation.v1",
		"invocation_id": "inv-interface-1",
		"action_id": "sample.interface.audit",
		"targets": [{
			"kind": "interface",
			"device_uid": "sr:device-2",
			"device_ip": "198.51.100.20",
			"interface_uid": "if-2",
			"if_name": "Gi1/0/12",
			"if_admin_status": "up",
			"if_oper_status": "down"
		}],
		"input_values": {
			"operation": "simulate_remediation",
			"dry_run": true,
			"change_ticket": "CHG-123"
		}
	}`))

	if got := interfaceResult["status"]; got != "succeeded" {
		t.Fatalf("interface status = %v, want succeeded; payload: %#v", got, interfaceResult)
	}

	interfaceTarget := firstTargetResult(t, interfaceResult)
	interfaceTargetResult := targetResultMap(t, interfaceTarget)

	if got := interfaceTargetResult["api_query"]; got != "POST /devices/198.51.100.20/interfaces/Gi1/0/12/actions/simulate_remediation" {
		t.Fatalf("interface api query = %v", got)
	}
	if got := interfaceTargetResult["vlan"]; got != float64(410) {
		t.Fatalf("interface vlan = %v", got)
	}
	if got := interfaceTargetResult["remediation_preview"]; got != "would run simulate_remediation for Gi1/0/12" {
		t.Fatalf("interface remediation preview = %v", got)
	}

	if queued := manager.DrainResults(1); len(queued) != 0 {
		t.Fatalf("action results should not be queued as scheduled output, got %d queued result(s)", len(queued))
	}
}

func TestPluginActionCredentialGrantsParseAndDedupe(t *testing.T) {
	t.Parallel()

	grants, err := pluginActionCredentialGrants(json.RawMessage(`{
		"credential_broker": {
			"schema": "serviceradar.edge_credential_broker_grant.v1",
			"grant_id": "grant-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1"
		},
		"credential_brokers": [{
			"schema": "serviceradar.edge_credential_broker_grant.v1",
			"grant_id": "grant-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1"
		}, {
			"schema": "serviceradar.edge_credential_broker_grant.v1",
			"grant_id": "grant-2",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-2"
		}]
	}`))
	if err != nil {
		t.Fatalf("pluginActionCredentialGrants returned error: %v", err)
	}
	if len(grants) != 2 {
		t.Fatalf("grants len = %d, want 2: %#v", len(grants), grants)
	}
	if grants[0].GrantID != "grant-1" || grants[1].GrantID != "grant-2" {
		t.Fatalf("unexpected grant order: %#v", grants)
	}
}

func TestValidatePluginActionHTTPGrantAllowsScopedRequest(t *testing.T) {
	t.Parallel()

	reqURL := mustParseURL(t, "https://api.example.com:8443/api/v1/devices")
	grants := []credentialBrokerGrant{{
		Schema:              "serviceradar.edge_credential_broker_grant.v1",
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Allow: credentialBrokerACL{
			Methods: []string{"GET", "POST"},
			Paths:   []string{"/api/v1/"},
			Hosts:   []string{"api.example.com"},
			Ports:   []int{8443},
		},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}}

	if _, err := pluginActionGrantForHTTPRequest(grants, "POST", reqURL, time.Now()); err != nil {
		t.Fatalf("pluginActionGrantForHTTPRequest returned error: %v", err)
	}
}

func TestNotificationHTTPGrantRequiresAndHonorsExplicitIntent(t *testing.T) {
	t.Parallel()

	now := time.Now()
	reqURL := mustParseURL(t, "https://api.example.com/v1/incidents")
	grant := func(id, secretRef, mode string) credentialBrokerGrant {
		return credentialBrokerGrant{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             id,
			GrantType:           "notification_credential",
			CredentialSecretRef: secretRef,
			Allow: credentialBrokerACL{
				Methods: []string{"POST"},
				Paths:   []string{"/v1/"},
				Hosts:   []string{"api.example.com"},
				Ports:   []int{443},
			},
			Inject:    map[string]string{"type": mode},
			ExpiresAt: now.Add(time.Minute).Format(time.RFC3339),
		}
	}

	grants := []credentialBrokerGrant{
		grant("grant-a", "credentialref:network-credential-secret:secret-a", "bearer_token"),
		grant("grant-b", "credentialref:network-credential-secret:secret-b", "http_header"),
	}

	selected, err := pluginActionGrantForHTTPRequestIntent(
		grants,
		"POST",
		reqURL,
		now,
		&credentialInjectionIntent{
			Mode:                "http_header",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-b",
		},
	)
	if err != nil {
		t.Fatalf("selecting grant B returned error: %v", err)
	}
	if selected == nil || selected.GrantID != "grant-b" {
		t.Fatalf("selected grant = %#v, want grant-b", selected)
	}

	selected, err = pluginActionGrantForHTTPRequestIntent(grants, "POST", reqURL, now, nil)
	if err != nil || selected != nil {
		t.Fatalf("ambient notification selection = (%#v, %v), want (nil, nil)", selected, err)
	}

	_, err = pluginActionGrantForHTTPRequestIntent(
		grants,
		"POST",
		reqURL,
		now,
		&credentialInjectionIntent{
			Mode:                "bearer_token",
			CredentialSecretRef: "credentialref:network-credential-secret:unknown",
		},
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("unknown credential ref error = %v, want denied", err)
	}

	_, err = pluginActionGrantForHTTPRequestIntent(
		grants,
		"POST",
		mustParseURL(t, "https://other.example.com/v1/incidents"),
		now,
		&credentialInjectionIntent{Mode: "bearer_token", GrantID: "grant-a"},
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("mismatched host error = %v, want denied", err)
	}
}

func TestNotificationHTTPGrantDeniesAmbiguousModeOnlyIntent(t *testing.T) {
	t.Parallel()

	now := time.Now()
	reqURL := mustParseURL(t, "https://api.example.com/v1/incidents")
	grants := make([]credentialBrokerGrant, 0, 2)
	for _, id := range []string{"a", "b"} {
		grants = append(grants, credentialBrokerGrant{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-" + id,
			GrantType:           "notification_credential",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-" + id,
			Allow: credentialBrokerACL{
				Methods: []string{"POST"},
				Paths:   []string{"/v1/"},
				Hosts:   []string{"api.example.com"},
				Ports:   []int{443},
			},
			Inject:    map[string]string{"type": "bearer_token"},
			ExpiresAt: now.Add(time.Minute).Format(time.RFC3339),
		})
	}

	_, err := pluginActionGrantForHTTPRequestIntent(
		grants,
		"POST",
		reqURL,
		now,
		&credentialInjectionIntent{Mode: "bearer_token"},
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("ambiguous selector error = %v, want denied", err)
	}
}

func TestNotificationHTTPIntentWithoutGrantIsDenied(t *testing.T) {
	t.Parallel()

	execution := &pluginExecution{mode: pluginExecutionModeAction}
	grant, err := execution.credentialBrokerGrantForHTTP(
		"POST",
		mustParseURL(t, "https://api.example.com/v1/incidents"),
		&credentialInjectionIntent{Mode: "bearer_token"},
	)
	if grant != nil || !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("selection = (%#v, %v), want (nil, denied)", grant, err)
	}
}

func TestValidatePluginActionHTTPGrantDeniesMismatchedRequest(t *testing.T) {
	t.Parallel()

	baseGrant := credentialBrokerGrant{
		Schema:              "serviceradar.edge_credential_broker_grant.v1",
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Allow: credentialBrokerACL{
			Methods: []string{"POST"},
			Paths:   []string{"/api/v1/"},
			Hosts:   []string{"api.example.com"},
			Ports:   []int{443},
		},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}

	tests := []struct {
		name   string
		method string
		url    string
	}{
		{name: "method", method: "GET", url: "https://api.example.com/api/v1/devices"},
		{name: "path", method: "POST", url: "https://api.example.com/admin"},
		{name: "host", method: "POST", url: "https://other.example.com/api/v1/devices"},
		{name: "port", method: "POST", url: "https://api.example.com:8443/api/v1/devices"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			_, err := pluginActionGrantForHTTPRequest(
				[]credentialBrokerGrant{baseGrant},
				tc.method,
				mustParseURL(t, tc.url),
				time.Now(),
			)
			if !errors.Is(err, errCredentialBrokerGrantDenied) {
				t.Fatalf("expected grant denied error, got %v", err)
			}
		})
	}
}

func TestValidatePluginActionAWXGrantBindsExactSchemeBeforeCredentialResolution(t *testing.T) {
	t.Parallel()

	grant := credentialBrokerGrant{
		Schema:              "serviceradar.edge_credential_broker_grant.v1",
		GrantID:             "grant-https-origin",
		GrantType:           "awx_oauth2_token",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Allow: credentialBrokerACL{
			Schemes: []string{"https"},
			Methods: []string{http.MethodGet},
			Paths:   []string{"=/api/v2/jobs/7/"},
			Hosts:   []string{"awx.example.test"},
			Ports:   []int{8443},
		},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}

	if _, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{grant},
		http.MethodGet,
		mustParseURL(t, "https://awx.example.test:8443/api/v2/jobs/7/"),
		time.Now(),
	); err != nil {
		t.Fatalf("expected exact HTTPS origin to be allowed, got %v", err)
	}

	_, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{grant},
		http.MethodGet,
		mustParseURL(t, "http://awx.example.test:8443/api/v2/jobs/7/"),
		time.Now(),
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("expected HTTP downgrade to be denied, got %v", err)
	}
}

func TestValidatePluginActionHTTPGrantRejectsExpiredGrant(t *testing.T) {
	t.Parallel()

	_, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "awx_oauth2_token",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
			Allow:               credentialBrokerACL{Methods: []string{"GET"}},
			ExpiresAt:           time.Now().Add(-time.Minute).Format(time.RFC3339),
		}},
		"GET",
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		time.Now(),
	)
	if !errors.Is(err, errCredentialBrokerGrantExpired) {
		t.Fatalf("expected grant expired error, got %v", err)
	}
}

func TestApplyCredentialBrokerHTTPInjectionSetsBearerHeader(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	grant := credentialBrokerGrant{
		Inject: map[string]string{
			"type":   "http_header",
			"name":   "Authorization",
			"scheme": "Bearer",
		},
	}

	err := applyCredentialBrokerHTTPInjection(req, grant, CredentialBrokerMaterial{Value: resolvedToken})
	if err != nil {
		t.Fatalf("applyCredentialBrokerHTTPInjection returned error: %v", err)
	}
	if got := req.Header.Get("Authorization"); got != "Bearer "+resolvedToken {
		t.Fatalf("Authorization header = %q, want bearer token", got)
	}
}

func TestApplyCredentialBrokerFormInjectionTargetsExactEndpoint(t *testing.T) {
	t.Parallel()

	req, err := http.NewRequestWithContext(
		t.Context(),
		http.MethodPost,
		"https://identity.example.com/oauth/token",
		strings.NewReader("scope=inventory"),
	)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	grant := credentialBrokerGrant{Inject: map[string]string{
		"type":             "form_urlencoded",
		"method":           http.MethodPost,
		"host":             "identity.example.com",
		"path":             "/oauth/token",
		"field_username":   "username",
		"field_password":   "password",
		"fixed_grant_type": "password",
	}}
	material := CredentialBrokerMaterial{Fields: map[string]string{
		"username": "svc-nco",
		"password": " secret-value ",
	}}

	if err := applyCredentialBrokerHTTPInjection(req, grant, material); err != nil {
		t.Fatalf("applyCredentialBrokerHTTPInjection returned error: %v", err)
	}
	body, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatalf("read request body: %v", err)
	}
	form, err := url.ParseQuery(string(body))
	if err != nil {
		t.Fatalf("parse injected form: %v", err)
	}
	if got := form.Get("username"); got != "svc-nco" {
		t.Fatalf("username = %q, want svc-nco", got)
	}
	if got := form.Get("password"); got != " secret-value " {
		t.Fatalf("password = %q, want injected secret", got)
	}
	if got := form.Get("grant_type"); got != "password" {
		t.Fatalf("grant_type = %q, want password", got)
	}
	if got := form.Get("scope"); got != "inventory" {
		t.Fatalf("scope = %q, want preserved caller field", got)
	}
}

func TestApplyCredentialBrokerFormInjectionRejectsCallerSecretField(t *testing.T) {
	t.Parallel()

	req, err := http.NewRequestWithContext(
		t.Context(),
		http.MethodPost,
		"https://identity.example.com/oauth/token",
		strings.NewReader("username=caller-supplied"),
	)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	grant := credentialBrokerGrant{Inject: map[string]string{
		"type":           "form_urlencoded",
		"method":         http.MethodPost,
		"host":           "identity.example.com",
		"path":           "/oauth/token",
		"field_username": "username",
	}}

	err = applyCredentialBrokerHTTPInjection(req, grant, CredentialBrokerMaterial{
		Fields: map[string]string{"username": "svc-nco"},
	})
	if !errors.Is(err, errCredentialBrokerSecretFieldPresent) {
		t.Fatalf("expected caller secret field rejection, got %v", err)
	}
}

func TestApplyCredentialBrokerFormInjectionIgnoresOtherEndpoint(t *testing.T) {
	t.Parallel()

	req, err := http.NewRequestWithContext(
		t.Context(),
		http.MethodPost,
		"https://identity.example.com/api/devices",
		strings.NewReader(`{"command":"list device"}`),
	)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	grant := credentialBrokerGrant{Inject: map[string]string{
		"type":           "form_urlencoded",
		"method":         http.MethodPost,
		"host":           "identity.example.com",
		"path":           "/oauth/token",
		"field_username": "username",
	}}

	if err := applyCredentialBrokerHTTPInjection(req, grant, CredentialBrokerMaterial{
		Fields: map[string]string{"username": "svc-nco"},
	}); err != nil {
		t.Fatalf("non-target injection returned error: %v", err)
	}
	body, err := io.ReadAll(req.Body)
	if err != nil {
		t.Fatalf("read request body: %v", err)
	}
	if got := string(body); got != `{"command":"list device"}` {
		t.Fatalf("request body changed for non-target endpoint: %s", got)
	}
}

func TestApplyCredentialBrokerFormInjectionRequiresHTTPSAndMaterial(t *testing.T) {
	t.Parallel()

	grant := credentialBrokerGrant{Inject: map[string]string{
		"type":           "form_urlencoded",
		"method":         http.MethodPost,
		"host":           "identity.example.com",
		"path":           "/oauth/token",
		"field_username": "username",
	}}

	httpReq, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "http://identity.example.com/oauth/token", nil,
	)
	if err != nil {
		t.Fatalf("create HTTP request: %v", err)
	}
	if err := applyCredentialBrokerHTTPInjection(httpReq, grant, CredentialBrokerMaterial{
		Fields: map[string]string{"username": "svc-nco"},
	}); !errors.Is(err, errCredentialBrokerFormInvalid) {
		t.Fatalf("expected non-HTTPS form rejection, got %v", err)
	}

	httpsReq, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://identity.example.com/oauth/token", nil,
	)
	if err != nil {
		t.Fatalf("create HTTPS request: %v", err)
	}
	if err := applyCredentialBrokerHTTPInjection(httpsReq, grant, CredentialBrokerMaterial{}); !errors.Is(err, errCredentialBrokerMaterialUnavailable) {
		t.Fatalf("expected missing material rejection, got %v", err)
	}
}

func TestCredentialBrokerOAuth2PasswordBearerKeepsTokenExchangeHostSide(t *testing.T) {
	t.Parallel()

	var tokenForm url.Values
	tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read token body: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		tokenForm, err = url.ParseQuery(string(body))
		if err != nil {
			t.Errorf("parse token form: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"derived-host-only-token","token_type":"Bearer","expires_in":300}`)
	}))
	defer tokenServer.Close()

	tokenURL := mustParseURL(t, tokenServer.URL+"/oauth/token")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{HTTPClient: tokenServer.Client()})
	defer manager.Stop()
	exec := newPluginExecution(manager, &pluginAssignment{})

	upstreamReq, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://inventory.example.test/api/devices", strings.NewReader(`{}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	grant := credentialBrokerGrant{Inject: oauth2PasswordBearerTestInject(tokenURL)}
	material := CredentialBrokerMaterial{Fields: map[string]string{
		"username": "inventory-user",
		"password": "long-lived-password",
	}}

	if err := exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(), upstreamReq, grant, material, oauth2GrantShapes[injectTypeOAuth2PasswordBearer], false,
	); err != nil {
		t.Fatalf("applyCredentialBrokerOAuth2Bearer returned error: %v", err)
	}
	if got := upstreamReq.Header.Get("Authorization"); got != "Bearer derived-host-only-token" {
		t.Fatalf("Authorization = %q", got)
	}
	if tokenForm.Get("username") != "inventory-user" ||
		tokenForm.Get("password") != "long-lived-password" ||
		tokenForm.Get("grant_type") != "password" {
		t.Fatalf("unexpected token form fields: %#v", tokenForm)
	}
	if strings.Contains(upstreamReq.Header.Get("Authorization"), "long-lived-password") {
		t.Fatal("upstream authorization exposed the source credential")
	}
}

func TestCredentialBrokerOAuth2PasswordBearerDeniesBeforeTokenExchangeOnTargetMismatch(t *testing.T) {
	t.Parallel()

	requests := 0
	tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		requests++
		_, _ = io.WriteString(w, `{"access_token":"must-not-be-issued"}`)
	}))
	defer tokenServer.Close()

	tokenURL := mustParseURL(t, tokenServer.URL+"/oauth/token")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{HTTPClient: tokenServer.Client()})
	defer manager.Stop()
	exec := newPluginExecution(manager, &pluginAssignment{})
	req, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://other.example.test/api/devices", nil,
	)
	if err != nil {
		t.Fatal(err)
	}

	err = exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(),
		req,
		credentialBrokerGrant{Inject: oauth2PasswordBearerTestInject(tokenURL)},
		CredentialBrokerMaterial{Fields: map[string]string{
			"username": "inventory-user",
			"password": "long-lived-password",
		}},
		oauth2GrantShapes[injectTypeOAuth2PasswordBearer],
		false,
	)
	if !errors.Is(err, errCredentialBrokerTokenExchangeInvalid) {
		t.Fatalf("expected target mismatch rejection, got %v", err)
	}
	if requests != 0 {
		t.Fatalf("token endpoint received %d request(s) after target rejection", requests)
	}
}

func TestCredentialBrokerOAuth2PasswordBearerDoesNotFollowTokenRedirects(t *testing.T) {
	t.Parallel()

	redirectTargetRequests := 0
	redirectTarget := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTargetRequests++
		_, _ = io.WriteString(w, `{"access_token":"redirect-token"}`)
	}))
	defer redirectTarget.Close()

	tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, redirectTarget.URL+"/token", http.StatusTemporaryRedirect)
	}))
	defer tokenServer.Close()

	tokenURL := mustParseURL(t, tokenServer.URL+"/oauth/token")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{HTTPClient: tokenServer.Client()})
	defer manager.Stop()
	exec := newPluginExecution(manager, &pluginAssignment{})
	req, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://inventory.example.test/api/devices", nil,
	)
	if err != nil {
		t.Fatal(err)
	}

	err = exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(),
		req,
		credentialBrokerGrant{Inject: oauth2PasswordBearerTestInject(tokenURL)},
		CredentialBrokerMaterial{Fields: map[string]string{
			"username": "inventory-user",
			"password": "long-lived-password",
		}},
		oauth2GrantShapes[injectTypeOAuth2PasswordBearer],
		false,
	)
	if !errors.Is(err, errCredentialBrokerTokenExchangeFailed) {
		t.Fatalf("expected redirect rejection, got %v", err)
	}
	if redirectTargetRequests != 0 {
		t.Fatalf("redirect target received %d credential-bearing request(s)", redirectTargetRequests)
	}
	if got := req.Header.Get("Authorization"); got != "" {
		t.Fatalf("upstream request received authorization after failed exchange: %q", got)
	}
}

func oauth2PasswordBearerTestInject(tokenURL *url.URL) map[string]string {
	return map[string]string{
		"type":             "oauth2_password_bearer",
		"method":           http.MethodPost,
		"host":             "inventory.example.test",
		"path":             "/api/devices",
		"token_method":     http.MethodPost,
		"token_host":       tokenURL.Hostname(),
		"token_port":       tokenURL.Port(),
		"token_path":       tokenURL.Path,
		"field_username":   "username",
		"field_password":   "password",
		"fixed_grant_type": "password",
	}
}

func TestPluginManagerEnqueueActionResultQueuesFullPayloadAndReturnsBoundedAck(t *testing.T) {
	t.Parallel()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer manager.Stop()
	assignment := &pluginAssignment{
		AssignmentID: "inventory-assignment-1",
		PluginID:     "example-inventory",
		Name:         "Example Inventory",
		Capabilities: map[string]bool{pluginCapabilityActionResultIngest: true},
	}
	payload := []byte(`{
		"status":"OK",
		"summary":"Collected example inventory",
		"device_discovery":[{
			"schema":"serviceradar.device_discovery.v1",
			"collection_id":"example-collection-1",
			"reference_hash":"sha256:abc123",
			"devices":[
				{"source_id":"example-inventory:v1:prod:device:1","metadata":{"private":"do-not-return"}},
				{"source_id":"example-inventory:v1:prod:device:2"}
			],
			"metadata":{
				"page_count":2,
				"received_rows":2,
				"invalid_rows":0,
				"duplicate_rows":0,
				"snapshot_complete":true
			}
		}]
	}`)

	ackPayload, err := manager.enqueueActionResult(t.Context(), assignment, payload)
	if err != nil {
		t.Fatalf("enqueueActionResult returned error: %v", err)
	}
	if strings.Contains(string(ackPayload), "do-not-return") ||
		strings.Contains(string(ackPayload), "source_id") {
		t.Fatalf("ack exposes raw inventory: %s", ackPayload)
	}

	var ack map[string]any
	if err := json.Unmarshal(ackPayload, &ack); err != nil {
		t.Fatalf("decode action result ack: %v", err)
	}
	if got := ack["schema"]; got != actionResultAckSchema {
		t.Fatalf("ack schema = %v, want %s", got, actionResultAckSchema)
	}
	if got := ack["status"]; got != commandStatusSucceeded {
		t.Fatalf("ack status = %v, want succeeded", got)
	}
	if got := ack["device_count"]; got != float64(2) {
		t.Fatalf("ack device_count = %v, want 2", got)
	}

	queued := manager.DrainResults(1)
	if len(queued) != 1 {
		t.Fatalf("queued results = %d, want 1", len(queued))
	}
	if got := string(queued[0].Payload); got != string(payload) {
		t.Fatalf("queued payload changed\ngot:  %s\nwant: %s", got, payload)
	}
}

func TestPluginManagerEnqueueActionResultRejectsInvalidAndBackpressure(t *testing.T) {
	t.Parallel()

	assignment := &pluginAssignment{
		AssignmentID: "inventory-assignment-1",
		PluginID:     "example-inventory",
		Name:         "Example Inventory",
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer manager.Stop()

	invalidPayloads := [][]byte{
		[]byte(`{"status":"OK","summary":"ok"}{"extra":true}`),
		[]byte(`{"status":"OK","summary":""}`),
		[]byte(`{"status":"not-a-status","summary":"bad"}`),
	}
	for _, payload := range invalidPayloads {
		if _, err := manager.enqueueActionResult(t.Context(), assignment, payload); !errors.Is(err, errPluginActionResultInvalid) {
			t.Fatalf("expected invalid action result for %q, got %v", payload, err)
		}
	}

	manager.results = make(chan PluginResult)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := manager.enqueueActionResult(
		ctx,
		assignment,
		[]byte(`{"status":"OK","summary":"valid"}`),
	); !errors.Is(err, errPluginActionResultBackpressure) {
		t.Fatalf("expected action result backpressure, got %v", err)
	}
}

func TestPluginExecutionCredentialInjectionRequiresResolver(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	exec := &pluginExecution{
		manager: NewPluginManager(t.Context(), PluginManagerConfig{}),
	}

	err := exec.applyCredentialBrokerInjection(t.Context(), req, &credentialBrokerGrant{
		Inject: map[string]string{"type": "bearer_token"},
	}, false)
	if !errors.Is(err, errCredentialBrokerResolverUnavailable) {
		t.Fatalf("expected resolver unavailable error, got %v", err)
	}
}

func TestPluginExecutionCredentialInjectionUsesResolverWithoutPluginSecret(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Fields: map[string]string{"value": resolvedToken}},
	}
	exec := &pluginExecution{
		manager: NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver}),
	}
	grant := &credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Inject: map[string]string{
			"type": "bearer_token",
		},
	}

	err := exec.applyCredentialBrokerInjection(t.Context(), req, grant, false)
	if err != nil {
		t.Fatalf("applyCredentialBrokerInjection returned error: %v", err)
	}
	if resolver.grantID != "grant-1" {
		t.Fatalf("resolver grant id = %q, want grant-1", resolver.grantID)
	}
	if got := req.Header.Get("Authorization"); got != "Bearer "+resolvedToken {
		t.Fatalf("Authorization header = %q, want resolved token", got)
	}
}

func TestValidatePluginActionHTTPGrantDeniesEmptyHostACL(t *testing.T) {
	t.Parallel()

	_, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "awx_oauth2_token",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
			Allow: credentialBrokerACL{
				Methods: []string{"GET"},
				Paths:   []string{"/api/v1/"},
			},
			ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
		}},
		"GET",
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		time.Now(),
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("expected grant denied error, got %v", err)
	}
}

func TestValidatePluginActionHTTPGrantDeniesEmptyPathACL(t *testing.T) {
	t.Parallel()

	_, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "awx_oauth2_token",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
			Allow: credentialBrokerACL{
				Methods: []string{"GET"},
				Hosts:   []string{"api.example.com"},
			},
			ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
		}},
		"GET",
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		time.Now(),
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("expected grant denied error, got %v", err)
	}
}

func TestValidatePluginActionHTTPGrantDeniesEmptyMethodACL(t *testing.T) {
	t.Parallel()

	_, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{{
			Schema:              "serviceradar.edge_credential_broker_grant.v1",
			GrantID:             "grant-1",
			GrantType:           "awx_oauth2_token",
			CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
			Allow: credentialBrokerACL{
				Paths: []string{"=/api/v1/devices"},
				Hosts: []string{"api.example.com"},
			},
			ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
		}},
		"GET",
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		time.Now(),
	)
	if !errors.Is(err, errCredentialBrokerGrantDenied) {
		t.Fatalf("expected grant denied error, got %v", err)
	}
}

func TestConfigurePluginHTTPRedirectsDeniesAWXCredentialBackedRedirect(t *testing.T) {
	t.Parallel()

	client := &http.Client{}
	requestURL := mustParseURL(t, "https://api.example.com/api/v1/devices")
	configurePluginHTTPRedirects(
		client,
		&credentialBrokerGrant{GrantID: "grant-1", GrantType: "awx_oauth2_token"},
		requestURL,
		&pluginPermissions{},
	)

	if client.CheckRedirect == nil {
		t.Fatal("expected credential-backed redirect policy")
	}
	if err := client.CheckRedirect(
		&http.Request{URL: mustParseURL(t, "https://api.example.com/admin")},
		nil,
	); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("expected redirect denial, got %v", err)
	}
}

func TestConfigurePluginHTTPRedirectsDeniesGenericCredentialInjectionRedirect(t *testing.T) {
	t.Parallel()

	client := &http.Client{}
	configurePluginHTTPRedirects(
		client,
		&credentialBrokerGrant{
			GrantID: "grant-1",
			Inject:  map[string]string{"type": "oauth2_password_bearer"},
		},
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		&pluginPermissions{},
	)

	if client.CheckRedirect == nil {
		t.Fatal("expected credential-backed redirect policy")
	}
	if err := client.CheckRedirect(
		&http.Request{URL: mustParseURL(t, "https://api.example.com/api/v1/next")},
		nil,
	); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("expected generic credential redirect denial, got %v", err)
	}
}

func TestConfigurePluginHTTPRedirectsEnforcesManifestOnOrdinaryRequest(t *testing.T) {
	t.Parallel()

	permissions := pluginPermissions{
		AllowedDomains: []string{"api.example.com"},
		AllowedPorts:   []int{443},
	}
	permissions.normalize()

	client := &http.Client{}
	configurePluginHTTPRedirects(
		client,
		nil,
		mustParseURL(t, "https://api.example.com/api/v1/devices"),
		&permissions,
	)

	if client.CheckRedirect == nil {
		t.Fatal("expected manifest-aware redirect policy")
	}
	if err := client.CheckRedirect(
		&http.Request{URL: mustParseURL(t, "https://api.example.com/api/v1/next")},
		nil,
	); err != nil {
		t.Fatalf("expected manifest-authorized redirect, got %v", err)
	}
	if err := client.CheckRedirect(
		&http.Request{URL: mustParseURL(t, "https://api.example.com:8443/api/v1/next")},
		nil,
	); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("expected manifest port denial, got %v", err)
	}
}

func TestLegacyNonAWXHTTPGrantKeepsOptionalMethodAndPathACLs(t *testing.T) {
	t.Parallel()

	grant := credentialBrokerGrant{
		Schema:              "serviceradar.edge_credential_broker_grant.v1",
		GrantID:             "grant-1",
		GrantType:           "unifi_protect_api",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Allow: credentialBrokerACL{
			Hosts: []string{"camera.example.com"},
		},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}

	if _, err := pluginActionGrantForHTTPRequest(
		[]credentialBrokerGrant{grant},
		"GET",
		mustParseURL(t, "https://camera.example.com/api/bootstrap"),
		time.Now(),
	); err != nil {
		t.Fatalf("legacy non-AWX host-only grant was rejected: %v", err)
	}

	client := &http.Client{}
	permissions := &pluginPermissions{
		AllowedDomains: []string{"camera.example.com"},
		AllowedPorts:   []int{443},
	}
	permissions.normalize()
	configurePluginHTTPRedirects(
		client,
		&grant,
		mustParseURL(t, "https://camera.example.com/api/bootstrap"),
		permissions,
	)
	if client.CheckRedirect == nil {
		t.Fatal("expected manifest-aware redirect policy")
	}
	if err := client.CheckRedirect(
		&http.Request{URL: mustParseURL(t, "https://camera.example.com/api/next")},
		nil,
	); err != nil {
		t.Fatalf("legacy non-AWX manifest-authorized redirect was rejected: %v", err)
	}
}

func TestCredentialBrokerOAuth2PasswordBearerSkipsTLSWhenRequested(t *testing.T) {
	t.Parallel()

	tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"insecure-token","token_type":"Bearer"}`)
	}))
	defer tokenServer.Close()

	tokenURL := mustParseURL(t, tokenServer.URL+"/oauth/token")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{})
	defer manager.Stop()
	exec := newPluginExecution(manager, &pluginAssignment{})
	req, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://inventory.example.test/api/devices", strings.NewReader(`{}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	grant := credentialBrokerGrant{Inject: oauth2PasswordBearerTestInject(tokenURL)}
	material := CredentialBrokerMaterial{Fields: map[string]string{
		"username": "inventory-user",
		"password": "long-lived-password",
	}}

	if err := exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(), req, grant, material, oauth2GrantShapes[injectTypeOAuth2PasswordBearer], false,
	); err == nil {
		t.Fatal("expected verified TLS against the untrusted test certificate to fail")
	}

	if err := exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(), req, grant, material, oauth2GrantShapes[injectTypeOAuth2PasswordBearer], true,
	); err != nil {
		t.Fatalf("insecure skip-verify token exchange failed: %v", err)
	}
	if got := req.Header.Get("Authorization"); got != "Bearer insecure-token" {
		t.Fatalf("Authorization = %q", got)
	}
}

func TestPluginExecutionCredentialInjectionDeniesInsecureTLSByDefault(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Fields: map[string]string{"value": resolvedToken}},
	}
	exec := &pluginExecution{
		manager: NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver}),
	}
	grant := &credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Inject:              map[string]string{"type": "bearer_token"},
	}

	err := exec.applyCredentialBrokerInjection(t.Context(), req, grant, true)
	if !errors.Is(err, errCredentialBrokerInsecureTLSDenied) {
		t.Fatalf("expected insecure TLS denial, got %v", err)
	}
	if resolver.calls != 0 {
		t.Fatalf("resolver calls = %d, want 0", resolver.calls)
	}
}

func TestCredentialBrokerBasicAuthRequiresExplicitFields(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	grant := credentialBrokerGrant{
		Inject: map[string]string{"type": "basic_auth"},
	}
	material := CredentialBrokerMaterial{Value: "shared-secret"}

	if err := applyCredentialBrokerHTTPInjection(req, grant, material); !errors.Is(err, errCredentialBrokerMaterialUnavailable) {
		t.Fatalf("expected material unavailable error, got %v", err)
	}
	if got := req.Header.Get("Authorization"); got != "" {
		t.Fatalf("Authorization header = %q, want empty", got)
	}
}

func TestCredentialBrokerBasicAuthUsesUsernamePasswordFields(t *testing.T) {
	t.Parallel()

	req := httptestRequest(t)
	grant := credentialBrokerGrant{
		Inject: map[string]string{"type": "basic_auth"},
	}
	material := CredentialBrokerMaterial{
		Fields: map[string]string{"username": "svc-user", "password": "svc-password"},
	}

	if err := applyCredentialBrokerHTTPInjection(req, grant, material); err != nil {
		t.Fatalf("applyCredentialBrokerHTTPInjection returned error: %v", err)
	}
	username, password, ok := req.BasicAuth()
	if !ok || username != "svc-user" || password != "svc-password" {
		t.Fatalf("basic auth = %q/%q ok=%v, want svc-user/svc-password true", username, password, ok)
	}
}

func TestCredentialBrokerResolutionRejectsExpiredProviderLease(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC)
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{
			Value:          "expired-token",
			LeaseExpiresAt: now.Add(-time.Second),
		},
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	manager.credentialNow = func() time.Time { return now }

	grant := credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Cache: credentialBrokerCachePolicy{
			Mode:       "memory_ttl",
			TTLSeconds: 60,
		},
		ExpiresAt: now.Add(time.Minute).Format(time.RFC3339),
	}

	if _, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant); !errors.Is(err, errCredentialBrokerGrantExpired) {
		t.Fatalf("expected expired grant error, got %v", err)
	}
}

func TestCredentialBrokerResolutionDefaultsNoCache(t *testing.T) {
	t.Parallel()

	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	grant := credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
	}

	if _, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant); err != nil {
		t.Fatalf("first resolve returned error: %v", err)
	}
	if _, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant); err != nil {
		t.Fatalf("second resolve returned error: %v", err)
	}
	if resolver.calls != 2 {
		t.Fatalf("resolver calls = %d, want 2 for default no_cache", resolver.calls)
	}
}

func TestCredentialBrokerResolutionMemoryCacheExpires(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC)
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	manager.credentialNow = func() time.Time { return now }

	grant := credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Cache: credentialBrokerCachePolicy{
			Mode:       "memory",
			TTLSeconds: 30,
		},
		ExpiresAt: now.Add(time.Minute).Format(time.RFC3339),
	}

	first, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant)
	if err != nil {
		t.Fatalf("first resolve returned error: %v", err)
	}
	if first.Value != resolvedToken {
		t.Fatalf("first material = %q, want resolved-token", first.Value)
	}

	resolver.material = CredentialBrokerMaterial{Value: "rotated-token"}
	second, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant)
	if err != nil {
		t.Fatalf("second resolve returned error: %v", err)
	}
	if second.Value != resolvedToken {
		t.Fatalf("second material = %q, want cached resolved-token", second.Value)
	}
	if resolver.calls != 1 {
		t.Fatalf("resolver calls = %d, want 1 while cache is valid", resolver.calls)
	}

	now = now.Add(31 * time.Second)
	third, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant)
	if err != nil {
		t.Fatalf("third resolve returned error: %v", err)
	}
	if third.Value != "rotated-token" {
		t.Fatalf("third material = %q, want rotated-token after expiry", third.Value)
	}
	if resolver.calls != 2 {
		t.Fatalf("resolver calls = %d, want 2 after cache expiry", resolver.calls)
	}
}

func TestCredentialBrokerResolutionMemoryCacheCappedByProviderLease(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC)
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{
			Value:          resolvedToken,
			LeaseExpiresAt: now.Add(10 * time.Second),
		},
	}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	manager.credentialNow = func() time.Time { return now }

	grant := credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Cache: credentialBrokerCachePolicy{
			Mode:       "memory",
			TTLSeconds: 60,
		},
		ExpiresAt: now.Add(time.Minute).Format(time.RFC3339),
	}

	first, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant)
	if err != nil {
		t.Fatalf("first resolve returned error: %v", err)
	}
	if first.Value != resolvedToken {
		t.Fatalf("first material = %q, want resolved-token", first.Value)
	}

	resolver.material = CredentialBrokerMaterial{
		Value:          "rotated-token",
		LeaseExpiresAt: now.Add(time.Minute),
	}
	now = now.Add(11 * time.Second)

	second, err := manager.resolveCredentialBrokerMaterial(t.Context(), grant)
	if err != nil {
		t.Fatalf("second resolve returned error: %v", err)
	}
	if second.Value != "rotated-token" {
		t.Fatalf("second material = %q, want rotated-token after provider lease expiry", second.Value)
	}
	if resolver.calls != 2 {
		t.Fatalf("resolver calls = %d, want 2 after provider lease expiry", resolver.calls)
	}
}

func newActionFixtureManager(t *testing.T, objectKey string, cfg *proto.PluginAssignmentConfig) *PluginManager {
	t.Helper()

	wasmPath := locateActionFixtureWasm(t, objectKey)
	if wasmPath == "" {
		t.Skipf("%s fixture not found; run with Bazel target //go/pkg/agent:plugin_runtime_action_test", objectKey)
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}

	localStore := t.TempDir()
	if err := os.WriteFile(filepath.Join(localStore, objectKey), wasm, 0o600); err != nil {
		t.Fatalf("stage wasm fixture: %v", err)
	}

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: localStore,
	})

	assignment := newPluginAssignment(cfg, logger.NewTestLogger())
	runner := newPluginRunner(manager, assignment)
	close(runner.done)

	manager.mu.Lock()
	manager.runners[cfg.AssignmentId] = runner
	manager.mu.Unlock()

	return manager
}

func runFixtureAction(t *testing.T, manager *PluginManager, payload json.RawMessage) map[string]interface{} {
	t.Helper()

	result, err := manager.RunAction(t.Context(), sampleNorthboundFixtureAssignmentID, payload, 10*time.Second)
	if err != nil {
		t.Fatalf("RunAction returned error: %v", err)
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode action result: %v\npayload: %s", err, result)
	}

	return decoded
}

func mustParseURL(t *testing.T, raw string) *url.URL {
	t.Helper()

	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse url %q: %v", raw, err)
	}

	return parsed
}

func httptestRequest(t *testing.T) *http.Request {
	t.Helper()

	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, testCredentialAPIURL, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	return req
}

type fakeCredentialBrokerResolver struct {
	grantID  string
	material CredentialBrokerMaterial
	err      error
	calls    int
}

func (f *fakeCredentialBrokerResolver) ResolveCredentialGrant(
	_ context.Context,
	grant credentialBrokerGrant,
) (CredentialBrokerMaterial, error) {
	f.calls++
	f.grantID = grant.GrantID
	if f.err != nil {
		return CredentialBrokerMaterial{}, f.err
	}

	return f.material, nil
}

func firstTargetResult(t *testing.T, decoded map[string]interface{}) map[string]interface{} {
	t.Helper()

	targets, ok := decoded["targets"].([]interface{})
	if !ok || len(targets) != 1 {
		t.Fatalf("targets = %#v, want one target result", decoded["targets"])
	}

	target, ok := targets[0].(map[string]interface{})
	if !ok {
		t.Fatalf("target result = %#v, want map", targets[0])
	}

	return target
}

func targetResultMap(t *testing.T, target map[string]interface{}) map[string]interface{} {
	t.Helper()

	result, ok := target["result"].(map[string]interface{})
	if !ok {
		t.Fatalf("target result payload = %#v, want map", target["result"])
	}

	return result
}

func locateActionFixtureWasm(t *testing.T, objectKey string) string {
	t.Helper()

	if override := strings.TrimSpace(os.Getenv("SERVICERADAR_ACTION_WASM_PATH")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
		t.Fatalf("SERVICERADAR_ACTION_WASM_PATH points to missing file %q", override)
	}

	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		if found := findActionFixtureInManifest(t, manifest, objectKey); found != "" {
			return found
		}
	}

	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{
			strings.TrimSpace(os.Getenv("TEST_WORKSPACE")),
			"_main",
		} {
			if workspace == "" {
				continue
			}
			candidate := filepath.Join(testSrcDir, workspace, "build", "wasm_plugins", objectKey)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}

	return ""
}

func findActionFixtureInManifest(t *testing.T, manifestPath, objectKey string) string {
	t.Helper()

	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read Bazel runfiles manifest: %v", err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		runfile, target, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		if strings.HasSuffix(runfile, "build/wasm_plugins/"+objectKey) {
			if _, err := os.Stat(target); err == nil {
				return target
			}
		}
	}

	return ""
}

func oauth2ClientCredentialsTestInject(tokenURL *url.URL) map[string]string {
	return map[string]string{
		"type":                "oauth2_client_credentials",
		"method":              http.MethodGet,
		"host":                "clearpass.example.test",
		"path":                "/api/session",
		"token_method":        http.MethodPost,
		"token_host":          tokenURL.Hostname(),
		"token_port":          tokenURL.Port(),
		"token_path":          tokenURL.Path,
		"field_client_id":     "client_id",
		"field_client_secret": "client_secret",
		"fixed_grant_type":    "client_credentials",
	}
}

// The client-credentials exchange is the whole point of the mode: the guest
// never learns the client secret, only the upstream request carries a
// short-lived derived bearer token.
func TestCredentialBrokerOAuth2ClientCredentialsExchangesSecretForBearer(t *testing.T) {
	t.Parallel()

	var tokenForm url.Values
	tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 8192))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		tokenForm, err = url.ParseQuery(string(body))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"access_token":"derived-cc-token","token_type":"Bearer","expires_in":28800}`)
	}))
	defer tokenServer.Close()

	tokenURL := mustParseURL(t, tokenServer.URL+"/api/oauth")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{HTTPClient: tokenServer.Client()})
	defer manager.Stop()
	exec := newPluginExecution(manager, &pluginAssignment{})

	upstreamReq, err := http.NewRequestWithContext(
		t.Context(), http.MethodGet, "https://clearpass.example.test/api/session", nil,
	)
	if err != nil {
		t.Fatal(err)
	}

	if err := exec.applyCredentialBrokerOAuth2Bearer(
		t.Context(),
		upstreamReq,
		credentialBrokerGrant{Inject: oauth2ClientCredentialsTestInject(tokenURL)},
		CredentialBrokerMaterial{Fields: map[string]string{
			"client_id":     "clearpass-monitor",
			"client_secret": "long-lived-client-secret",
		}},
		oauth2GrantShapes[injectTypeOAuth2ClientCredentials],
		false,
	); err != nil {
		t.Fatalf("applyCredentialBrokerOAuth2Bearer returned error: %v", err)
	}

	if got := upstreamReq.Header.Get("Authorization"); got != "Bearer derived-cc-token" {
		t.Fatalf("Authorization = %q", got)
	}
	if tokenForm.Get("client_id") != "clearpass-monitor" ||
		tokenForm.Get("client_secret") != "long-lived-client-secret" ||
		tokenForm.Get("grant_type") != "client_credentials" {
		t.Fatalf("unexpected token form fields: %#v", tokenForm)
	}
	if strings.Contains(upstreamReq.Header.Get("Authorization"), "long-lived-client-secret") {
		t.Fatal("upstream authorization exposed the source credential")
	}
	if tokenForm.Has("username") || tokenForm.Has("password") {
		t.Fatalf("client-credentials exchange sent password-grant fields: %#v", tokenForm)
	}
}

// A grant declaring one OAuth2 mode must not be satisfiable by the OTHER
// mode's credential fields.
//
// The dangerous shape is a manifest that names `oauth2_client_credentials` and
// sets `fixed_grant_type` to match, but maps the password grant's fields. The
// per-field mapping loop cannot catch it - the material genuinely holds a
// username and a password, so every mapping resolves - and the grant_type check
// cannot catch it either, because the manifest set grant_type consistently.
// Only the per-shape required-field check refuses it, which is why removing
// that check must break this test.
func TestCredentialBrokerOAuth2GrantShapesRequireTheirOwnCredentialFields(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		shape    oauth2GrantShape
		base     func(*url.URL) map[string]string
		mappings map[string]string
		fields   map[string]string
	}{
		{
			name:     "client credentials grant refuses to run on password fields",
			shape:    oauth2GrantShapes[injectTypeOAuth2ClientCredentials],
			base:     oauth2ClientCredentialsTestInject,
			mappings: map[string]string{"field_username": "username", "field_password": "password"},
			fields:   map[string]string{"username": "u", "password": "p"},
		},
		{
			name:     "password grant refuses to run on client credential fields",
			shape:    oauth2GrantShapes[injectTypeOAuth2PasswordBearer],
			base:     oauth2PasswordBearerTestInject,
			mappings: map[string]string{"field_client_id": "client_id", "field_client_secret": "client_secret"},
			fields:   map[string]string{"client_id": "c", "client_secret": "s"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			requests := 0
			tokenServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				requests++
				_, _ = io.WriteString(w, `{"access_token":"must-not-be-issued"}`)
			}))
			defer tokenServer.Close()

			tokenURL := mustParseURL(t, tokenServer.URL+"/api/oauth")
			manager := NewPluginManager(t.Context(), PluginManagerConfig{HTTPClient: tokenServer.Client()})
			defer manager.Stop()
			exec := newPluginExecution(manager, &pluginAssignment{})

			// Keep the declared grant_type, swap only which credential fields
			// the manifest maps into the token form.
			inject := test.base(tokenURL)
			for key := range inject {
				if strings.HasPrefix(key, "field_") {
					delete(inject, key)
				}
			}
			for key, value := range test.mappings {
				inject[key] = value
			}

			req, err := http.NewRequestWithContext(
				t.Context(), inject["method"], "https://"+inject["host"]+inject["path"], nil,
			)
			if err != nil {
				t.Fatal(err)
			}

			err = exec.applyCredentialBrokerOAuth2Bearer(
				t.Context(),
				req,
				credentialBrokerGrant{Inject: inject},
				CredentialBrokerMaterial{Fields: test.fields},
				test.shape,
				false,
			)
			if !errors.Is(err, errCredentialBrokerTokenExchangeInvalid) {
				t.Fatalf("expected shape rejection, got %v", err)
			}
			if requests != 0 {
				t.Fatalf("token endpoint received %d request(s) for a mismatched grant shape", requests)
			}
			if got := req.Header.Get("Authorization"); got != "" {
				t.Fatalf("upstream request received authorization: %q", got)
			}
		})
	}
}

// oauth2GrantShapeFor is the routing decision in plugin_runtime_http.go: it
// alone decides whether a grant takes the token-exchange path or the direct
// injection switch. A non-OAuth2 type reaching the exchange would perform a
// token POST for a grant that never asked for one.
func TestOAuth2GrantShapeForRoutesOnlyOAuth2Types(t *testing.T) {
	t.Parallel()

	for _, injectType := range []string{
		"oauth2_password_bearer",
		"  OAuth2_Client_Credentials  ",
	} {
		if _, ok := oauth2GrantShapeFor(injectType); !ok {
			t.Errorf("oauth2GrantShapeFor(%q) did not route to the token exchange", injectType)
		}
	}

	for _, injectType := range []string{
		"", "http_header", "bearer_token", "basic_auth", "query", "form_urlencoded", "oauth2", "url_path",
	} {
		if _, ok := oauth2GrantShapeFor(injectType); ok {
			t.Errorf("oauth2GrantShapeFor(%q) wrongly routed to the token exchange", injectType)
		}
	}
}
