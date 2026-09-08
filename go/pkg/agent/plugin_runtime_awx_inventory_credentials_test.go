/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/tetratelabs/wazero/api"
	"google.golang.org/protobuf/encoding/protowire"
	gproto "google.golang.org/protobuf/proto"
)

const (
	testAWXInventoryTokenA = "awx-inventory-host-token-a-018f2fd1"
	testAWXInventoryTokenB = "awx-inventory-host-token-b-018f2fd1"
)

func TestAWXInventoryAssignmentKeepsCredentialsHostOnly(t *testing.T) {
	t.Parallel()

	assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId: "awx-inventory-host-only",
		PluginId:     awxInventorySyncPluginID,
		Entrypoint:   awxInventorySyncEntrypoint,
		Capabilities: []string{"get_config", "http_request"},
		ParamsJson: []byte(`{
			"controllers":[{
				"controller_id":"controller-a",
				"controller_name":"AWX A",
				"base_url":"https://AWX-A.example.test/",
				"api_token":"` + testAWXInventoryTokenA + `",
				"api_token_secret_ref":"credentialref:must-not-reach-wasm",
				"credential_broker":{"grant_id":"grant-must-not-reach-wasm"},
				"insecure_skip_verify":false
			}]
		}`),
	}, logger.NewTestLogger())

	if !assignment.scheduledAWXInventorySync {
		t.Fatal("scheduled AWX inventory assignment was not recognized")
	}
	if len(assignment.awxInventoryHostCredentials) != 1 {
		t.Fatalf("host credential bindings = %d, want 1", len(assignment.awxInventoryHostCredentials))
	}
	if strings.Contains(string(assignment.ParamsJSON), testAWXInventoryTokenA) ||
		strings.Contains(string(assignment.ParamsJSON), "credentialref:must-not-reach-wasm") ||
		strings.Contains(string(assignment.ParamsJSON), "grant-must-not-reach-wasm") {
		t.Fatalf("Wasm-visible params contain host credential material: %s", assignment.ParamsJSON)
	}

	var visible map[string]any
	if err := json.Unmarshal(assignment.ParamsJSON, &visible); err != nil {
		t.Fatalf("decode Wasm-visible params: %v", err)
	}
	controllers := visible["controllers"].([]any)
	controller := controllers[0].(map[string]any)
	if got := controller["api_token"]; got != awxInventoryHostCredentialSentinel {
		t.Fatalf("Wasm-visible api_token = %v, want host sentinel", got)
	}
	if got := controller["base_url"]; got != "https://awx-a.example.test" {
		t.Fatalf("normalized base_url = %v", got)
	}
	for _, key := range []string{"api_token_secret_ref", "credential_broker", "_secret_material"} {
		if _, present := controller[key]; present {
			t.Fatalf("Wasm-visible controller retained %q", key)
		}
	}

	execution := newPluginExecution(nil, assignment)
	if strings.Contains(string(execution.configJSON), testAWXInventoryTokenA) {
		t.Fatal("newPluginExecution exposed the retained bearer through get_config backing JSON")
	}
}

func TestAWXInventoryAssignmentExtractsDedicatedHostParams(t *testing.T) {
	t.Parallel()

	params := map[string]any{
		"controllers": []any{map[string]any{
			"controller_id":        "controller-a",
			"base_url":             "https://awx-a.example.test",
			"api_token":            awxInventoryHostCredentialSentinel,
			"insecure_skip_verify": true,
		}},
	}
	hostParams := map[string]any{
		"schema": awxInventoryHostCredentialsSchema,
		"controllers": []any{map[string]any{
			"controller_id":        "controller-a",
			"base_url":             "https://awx-a.example.test:443/",
			"api_token":            testAWXInventoryTokenA,
			"insecure_skip_verify": true,
		}},
	}
	paramsJSON, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	hostParamsJSON, err := json.Marshal(hostParams)
	if err != nil {
		t.Fatalf("marshal host params: %v", err)
	}

	assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId:   "awx-inventory-host-envelope",
		PluginId:       awxInventorySyncPluginID,
		Entrypoint:     awxInventorySyncEntrypoint,
		ParamsJson:     paramsJSON,
		HostParamsJson: hostParamsJSON,
	}, logger.NewTestLogger())

	if len(assignment.awxInventoryHostCredentials) != 1 {
		t.Fatalf("host credential bindings = %d, want 1", len(assignment.awxInventoryHostCredentials))
	}
	if strings.Contains(string(assignment.ParamsJSON), testAWXInventoryTokenA) ||
		strings.Contains(string(assignment.ParamsJSON), awxInventoryHostCredentialsConfigKey) {
		t.Fatalf("reserved host envelope reached Wasm-visible config: %s", assignment.ParamsJSON)
	}
	binding := assignment.awxInventoryHostCredentials["https://awx-a.example.test:443"]
	if binding.bearerToken != testAWXInventoryTokenA || !binding.insecureSkipVerify {
		t.Fatalf("unexpected retained host binding: %#v", binding)
	}
}

func TestAWXInventoryAssignmentRejectsUnreviewedHostParamsAndEmptyControllerID(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		paramsJSON string
		hostJSON   string
	}{
		{
			name:       "unknown envelope field",
			paramsJSON: `{"controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + awxInventoryHostCredentialSentinel + `"}]}`,
			hostJSON:   `{"schema":"` + awxInventoryHostCredentialsSchema + `","controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + testAWXInventoryTokenA + `"}],"future_policy":"unreviewed"}`,
		},
		{
			name:       "unknown controller field",
			paramsJSON: `{"controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + awxInventoryHostCredentialSentinel + `"}]}`,
			hostJSON:   `{"schema":"` + awxInventoryHostCredentialsSchema + `","controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + testAWXInventoryTokenA + `","credential_scope":"unreviewed"}]}`,
		},
		{
			name:       "empty controller identity",
			paramsJSON: `{"controllers":[{"controller_id":"","base_url":"https://awx-a.example.test","api_token":"` + awxInventoryHostCredentialSentinel + `"}]}`,
			hostJSON:   `{"schema":"` + awxInventoryHostCredentialsSchema + `","controllers":[{"controller_id":"","base_url":"https://awx-a.example.test","api_token":"` + testAWXInventoryTokenA + `"}]}`,
		},
		{
			name:       "non canonical controller identity",
			paramsJSON: `{"controllers":[{"controller_id":" controller-a ","base_url":"https://awx-a.example.test","api_token":"` + awxInventoryHostCredentialSentinel + `"}]}`,
			hostJSON:   `{"schema":"` + awxInventoryHostCredentialsSchema + `","controllers":[{"controller_id":" controller-a ","base_url":"https://awx-a.example.test","api_token":"` + testAWXInventoryTokenA + `"}]}`,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
				AssignmentId:   "awx-inventory-invalid-host-params",
				PluginId:       awxInventorySyncPluginID,
				Entrypoint:     awxInventorySyncEntrypoint,
				ParamsJson:     []byte(test.paramsJSON),
				HostParamsJson: []byte(test.hostJSON),
			}, logger.NewTestLogger())

			if got := string(assignment.ParamsJSON); got != "{}" {
				t.Fatalf("invalid host params were not failed closed: %s", got)
			}
			if len(assignment.awxInventoryHostCredentials) != 0 {
				t.Fatal("invalid host params produced a usable credential binding")
			}
		})
	}
}

func TestAWXInventoryAssignmentRejectsHostEnvelopeInsideParamsJSON(t *testing.T) {
	t.Parallel()

	assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId: "awx-inventory-envelope-in-public-params",
		PluginId:     awxInventorySyncPluginID,
		Entrypoint:   awxInventorySyncEntrypoint,
		ParamsJson: []byte(`{
			"controllers":[{
				"controller_id":"controller-a",
				"base_url":"https://awx-a.example.test",
				"api_token":"` + awxInventoryHostCredentialSentinel + `"
			}],
			"` + awxInventoryHostCredentialsConfigKey + `":{
				"schema":"` + awxInventoryHostCredentialsSchema + `",
				"controllers":[{
					"controller_id":"controller-a",
					"base_url":"https://awx-a.example.test",
					"api_token":"` + testAWXInventoryTokenA + `",
					"insecure_skip_verify":false
				}]
			}
		}`),
	}, logger.NewTestLogger())

	if got := string(assignment.ParamsJSON); got != "{}" {
		t.Fatalf("public host envelope was not failed closed: %s", got)
	}
	if len(assignment.awxInventoryHostCredentials) != 0 {
		t.Fatal("public host envelope produced a usable credential binding")
	}
}

func TestAWXInventoryMixedVersionWireKeepsHostParamsOutsideLegacyVisibleField(t *testing.T) {
	t.Parallel()

	publicParams := []byte(`{"controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + awxInventoryHostCredentialSentinel + `"}]}`)
	hostParams := []byte(`{"schema":"` + awxInventoryHostCredentialsSchema + `","controllers":[{"controller_id":"controller-a","base_url":"https://awx-a.example.test","api_token":"` + testAWXInventoryTokenA + `","insecure_skip_verify":false}]}`)
	wireBytes, err := gproto.Marshal(&proto.PluginAssignmentConfig{
		ParamsJson:     publicParams,
		HostParamsJson: hostParams,
	})
	if err != nil {
		t.Fatalf("marshal mixed-version assignment: %v", err)
	}

	var field10Params, field23HostParams []byte
	for len(wireBytes) > 0 {
		number, wireType, tagBytes := protowire.ConsumeTag(wireBytes)
		if tagBytes < 0 {
			t.Fatalf("consume protobuf tag: %v", protowire.ParseError(tagBytes))
		}
		wireBytes = wireBytes[tagBytes:]
		if wireType != protowire.BytesType {
			t.Fatalf("unexpected wire type %v for field %d", wireType, number)
		}
		value, valueBytes := protowire.ConsumeBytes(wireBytes)
		if valueBytes < 0 {
			t.Fatalf("consume protobuf field %d: %v", number, protowire.ParseError(valueBytes))
		}
		wireBytes = wireBytes[valueBytes:]
		switch number {
		case 10:
			field10Params = append([]byte(nil), value...)
		case 23:
			field23HostParams = append([]byte(nil), value...)
		case protowire.MinValidNumber,
			protowire.FirstReservedNumber,
			protowire.LastReservedNumber,
			protowire.MaxValidNumber:
			continue
		default:
			continue
		}
	}

	// A pre-field-23 agent knows only params_json (field 10) and discards field
	// 23 as unknown. Its get_config input therefore contains only the sentinel.
	if !bytes.Equal(field10Params, publicParams) ||
		strings.Contains(string(field10Params), testAWXInventoryTokenA) {
		t.Fatalf("legacy-visible params contain host material: %s", field10Params)
	}
	if !bytes.Equal(field23HostParams, hostParams) {
		t.Fatalf("dedicated host params field = %s, want %s", field23HostParams, hostParams)
	}
}

func TestAWXInventoryAssignmentFailsClosedOnAmbiguousOrigin(t *testing.T) {
	t.Parallel()

	assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId: "awx-inventory-duplicate-origin",
		PluginId:     awxInventorySyncPluginID,
		Entrypoint:   awxInventorySyncEntrypoint,
		ParamsJson: []byte(`{
			"controllers":[
				{"controller_id":"controller-a","base_url":"https://AWX.example.test","api_token":"` + testAWXInventoryTokenA + `"},
				{"controller_id":"controller-b","base_url":"https://awx.example.test:443/","api_token":"` + testAWXInventoryTokenB + `"}
			]
		}`),
	}, logger.NewTestLogger())

	if !assignment.scheduledAWXInventorySync {
		t.Fatal("scheduled AWX inventory assignment was not recognized")
	}
	if len(assignment.awxInventoryHostCredentials) != 0 {
		t.Fatalf("ambiguous origin retained %d credential bindings", len(assignment.awxInventoryHostCredentials))
	}
	if got := string(assignment.ParamsJSON); got != "{}" {
		t.Fatalf("invalid credential config was not fully scrubbed: %s", got)
	}
}

func TestAWXInventoryHostCredentialFingerprintRotatesWithoutExposingToken(t *testing.T) {
	t.Parallel()

	first := testAWXInventoryAssignmentWithToken(t, testAWXInventoryTokenA)
	second := testAWXInventoryAssignmentWithToken(t, testAWXInventoryTokenB)

	if string(first.ParamsJSON) != string(second.ParamsJSON) {
		t.Fatalf("Wasm-visible params changed with host-only token:\n%s\n%s", first.ParamsJSON, second.ParamsJSON)
	}
	firstHash := buildPluginConfigHash(pluginEngineLimits{}, []*pluginAssignment{first})
	secondHash := buildPluginConfigHash(pluginEngineLimits{}, []*pluginAssignment{second})
	if firstHash == secondHash {
		t.Fatalf("assignment config hash did not rotate when host-only token changed: %s", firstHash)
	}

	fingerprintJSON, err := json.Marshal(buildAssignmentFingerprint(first))
	if err != nil {
		t.Fatalf("marshal assignment fingerprint: %v", err)
	}
	if strings.Contains(string(fingerprintJSON), testAWXInventoryTokenA) {
		t.Fatalf("assignment fingerprint exposed bearer: %s", fingerprintJSON)
	}
}

func testAWXInventoryAssignmentWithToken(t *testing.T, token string) *pluginAssignment {
	t.Helper()
	return newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId: "awx-inventory-fingerprint",
		PluginId:     awxInventorySyncPluginID,
		Entrypoint:   awxInventorySyncEntrypoint,
		Capabilities: []string{"get_config", "http_request"},
		ParamsJson: []byte(`{
			"controllers":[{
				"controller_id":"controller-a",
				"base_url":"https://awx-a.example.test",
				"api_token":"` + token + `"
			}]
		}`),
		PermissionsJson: []byte(`{"allowed_domains":["awx-a.example.test"],"allowed_ports":[443]}`),
	}, logger.NewTestLogger())
}

func TestAWXInventoryCredentialPathPolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		path string
		want bool
	}{
		{path: "/api/v2/inventories/", want: true},
		{path: "/api/v2/inventories/7/hosts/", want: true},
		{path: "/api/v2/inventories", want: false},
		{path: "/api/v2/users/", want: false},
		{path: "/api/v2/inventories/../credentials/", want: false},
		{path: "/api/v2/inventories/%2e%2e/credentials/", want: false},
		{path: "/api/v2/inventories/%252e%252e/credentials/", want: false},
	}
	for _, test := range tests {
		t.Run(test.path, func(t *testing.T) {
			request, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://awx.example.test"+test.path, nil)
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			if got := allowedAWXInventoryCredentialPath(request.URL); got != test.want {
				t.Fatalf("allowedAWXInventoryCredentialPath(%q) = %t, want %t", test.path, got, test.want)
			}
		})
	}
}

func TestScheduledAWXInventoryHTTPRequestInjectsOnlyForExactBinding(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name               string
		method             string
		requestURL         string
		authorization      string
		body               string
		insecureSkipVerify bool
		wantAllowed        bool
	}{
		{
			name:          "exact inventory collection GET",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/?page_size=200",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
			wantAllowed:   true,
		},
		{
			name:          "exact inventory hosts GET",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/7/hosts/?page_size=200",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
			wantAllowed:   true,
		},
		{
			name:          "allowed manifest origin without host binding",
			method:        http.MethodGet,
			requestURL:    "https://awx-b.example.test/api/v2/inventories/",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
		},
		{
			name:          "disallowed endpoint on bound origin",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/users/",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
		},
		{
			name:          "double encoded path traversal",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/%252e%252e/users/",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
		},
		{
			name:          "disallowed method",
			method:        http.MethodPost,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
		},
		{
			name:          "GET body is denied",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/",
			authorization: "Bearer " + awxInventoryHostCredentialSentinel,
			body:          `{"unexpected":true}`,
		},
		{
			name:               "TLS policy mismatch",
			method:             http.MethodGet,
			requestURL:         "https://awx-a.example.test/api/v2/inventories/",
			authorization:      "Bearer " + awxInventoryHostCredentialSentinel,
			insecureSkipVerify: true,
		},
		{
			name:          "plugin supplied plaintext bearer",
			method:        http.MethodGet,
			requestURL:    "https://awx-a.example.test/api/v2/inventories/",
			authorization: "Bearer plugin-controlled-token",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			var sentAuthorization string
			transport := &countingPluginHTTPTransport{
				respond: func(req *http.Request) *http.Response {
					sentAuthorization = req.Header.Get("Authorization")
					return pluginHTTPTestResponse(req, http.StatusOK, nil, `{"ok":true}`)
				},
			}
			exec, module := newScheduledAWXInventoryHTTPTestExecution(t, transport)
			got := callPluginHostHTTPRequestPayload(t, exec, module, httpRequestPayload{
				Method: test.method,
				URL:    test.requestURL,
				Headers: map[string]string{
					"Authorization": test.authorization,
					"Accept":        "application/json",
				},
				Body:               test.body,
				InsecureSkipVerify: test.insecureSkipVerify,
			})

			if test.wantAllowed {
				if got <= 0 || transport.calls != 1 {
					t.Fatalf("hostHTTPRequest() = %d, transport calls = %d, want success", got, transport.calls)
				}
				if sentAuthorization != "Bearer "+testAWXInventoryTokenA {
					t.Fatalf("outbound Authorization = %q, want host-injected bearer", sentAuthorization)
				}
				return
			}

			if got != pluginErrDenied || transport.calls != 0 {
				t.Fatalf(
					"hostHTTPRequest() = %d, transport calls = %d, want denied before transport",
					got,
					transport.calls,
				)
			}
			if sentAuthorization != "" {
				t.Fatalf("denied request reached transport with Authorization %q", sentAuthorization)
			}
		})
	}
}

func TestScheduledAWXInventoryHostCredentialNeverFollowsRedirect(t *testing.T) {
	t.Parallel()

	var sentAuthorizations []string
	transport := &countingPluginHTTPTransport{
		respond: func(req *http.Request) *http.Response {
			sentAuthorizations = append(sentAuthorizations, req.Header.Get("Authorization"))
			if req.URL.Path == "/api/v2/inventories/" {
				return pluginHTTPTestResponse(
					req,
					http.StatusFound,
					map[string]string{"Location": "https://awx-a.example.test/api/v2/inventories/7/hosts/"},
					"redirect",
				)
			}
			return pluginHTTPTestResponse(req, http.StatusOK, nil, `{"ok":true}`)
		},
	}
	exec, module := newScheduledAWXInventoryHTTPTestExecution(t, transport)
	got := callPluginHostHTTPRequestPayload(t, exec, module, httpRequestPayload{
		Method: http.MethodGet,
		URL:    "https://awx-a.example.test/api/v2/inventories/",
		Headers: map[string]string{
			"Authorization": "Bearer " + awxInventoryHostCredentialSentinel,
		},
	})

	if got <= 0 {
		t.Fatalf("hostHTTPRequest() = %d, want original redirect response", got)
	}
	if transport.calls != 1 || len(sentAuthorizations) != 1 {
		t.Fatalf("host-bound redirect made %d transport calls, want 1", transport.calls)
	}
	if sentAuthorizations[0] != "Bearer "+testAWXInventoryTokenA {
		t.Fatalf("first request Authorization = %q", sentAuthorizations[0])
	}
}

func TestScheduledAWXInventoryCredentialRequiresExactInsecureTLSPolicy(t *testing.T) {
	t.Parallel()

	assignment := testAWXInventoryAssignmentWithInsecureTLS(t)
	exec := &pluginExecution{assignment: assignment, mode: pluginExecutionModeScheduled}

	request, err := http.NewRequestWithContext(
		t.Context(),
		http.MethodGet,
		"https://awx-a.example.test/api/v2/inventories/",
		nil,
	)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+awxInventoryHostCredentialSentinel)
	bound, err := exec.applyAWXInventoryHostCredential(request, true)
	if err != nil || !bound {
		t.Fatalf("configured insecure TLS policy was not accepted: bound=%t err=%v", bound, err)
	}
	if got := request.Header.Get("Authorization"); got != "Bearer "+testAWXInventoryTokenA {
		t.Fatalf("Authorization = %q, want injected bearer", got)
	}

	request.Header.Set("Authorization", "Bearer "+awxInventoryHostCredentialSentinel)
	if _, err := exec.applyAWXInventoryHostCredential(request, false); err == nil {
		t.Fatal("request with TLS verification enabled did not fail exact host policy")
	}
}

func newScheduledAWXInventoryHTTPTestExecution(
	t *testing.T,
	transport http.RoundTripper,
) (*pluginExecution, api.Module) {
	t.Helper()

	permissions := pluginPermissions{
		AllowedDomains: []string{"awx-a.example.test", "awx-b.example.test"},
		AllowedPorts:   []int{443},
	}
	exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, nil)
	assignment := testAWXInventoryAssignmentWithToken(t, testAWXInventoryTokenA)
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	exec.assignment = assignment
	exec.configJSON = assignment.ParamsJSON

	return exec, module
}

func testAWXInventoryAssignmentWithInsecureTLS(t *testing.T) *pluginAssignment {
	t.Helper()
	return newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId: "awx-inventory-insecure-tls",
		PluginId:     awxInventorySyncPluginID,
		Entrypoint:   awxInventorySyncEntrypoint,
		ParamsJson: []byte(`{
			"controllers":[{
				"controller_id":"controller-a",
				"base_url":"https://awx-a.example.test",
				"api_token":"` + testAWXInventoryTokenA + `",
				"insecure_skip_verify":true
			}]
		}`),
	}, logger.NewTestLogger())
}

func callPluginHostHTTPRequestPayload(
	t *testing.T,
	exec *pluginExecution,
	module api.Module,
	payload httpRequestPayload,
) int32 {
	t.Helper()

	requestBytes, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal HTTP request payload: %v", err)
	}
	const (
		requestPtr  = uint32(0)
		responsePtr = uint32(32 * 1024)
		responseLen = uint32(16 * 1024)
	)
	if !module.Memory().Write(requestPtr, requestBytes) {
		t.Fatal("write HTTP request payload to Wasm memory")
	}
	return exec.hostHTTPRequest(
		t.Context(),
		module,
		requestPtr,
		uint32(len(requestBytes)),
		responsePtr,
		responseLen,
	)
}
