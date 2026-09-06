/*
 * Copyright 2026 Carver Automation Corporation.
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
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/gorilla/websocket"
)

const (
	testProxmoxCredentialRuleID    = "proxmox-rule-1"
	testProxmoxIntegrationID       = "018f2fd1-0000-7000-8000-000000000001"
	testProxmoxControllerID        = "018f2fd1-0000-7000-8000-000000000002"
	testProxmoxProviderInstanceRef = "proxmox:v3:" + testProxmoxIntegrationID + ":" + testProxmoxControllerID + ":farm%3A01"
	testProxmoxNativeClusterID     = "farm:01"
	testProxmoxControllerDeviceUID = "controller-device-1"
	testProxmoxGuestDeviceUID      = "guest-device-101"
	testProxmoxControllerRef       = testProxmoxProviderInstanceRef + ":node:pve01"
	testProxmoxGuestRef            = testProxmoxProviderInstanceRef + ":qemu:101"
	testProxmoxOrigin              = "https://192.0.2.10:8006"
)

var (
	errUnexpectedProxmoxWebSocketDial = errors.New("unexpected websocket dial")
	errUnexpectedProxmoxSSHDial       = errors.New("unexpected SSH dial")
)

type testProxmoxHostAuthorityOptions struct {
	assignmentID          string
	pluginID              string
	entrypoint            string
	policyVersion         uint64
	paramsJSON            string
	origin                string
	insecureSkipVerify    bool
	sshHostKeyPolicy      string
	targetIDs             map[string]string
	grantID               string
	secretRef             string
	expiresAt             string
	ttlSeconds            int
	methods               []string
	paths                 []string
	hosts                 []string
	ports                 []int
	caBundlePEM           string
	serverCertFingerprint string
}

func TestProxmoxAssignmentPolicyFingerprintGoldenVector(t *testing.T) {
	t.Parallel()

	got := proxmoxAssignmentPolicyFingerprint(
		"assignment-policy",
		proxmoxConsolePluginID,
		proxmoxConsoleEntrypoint,
		"network-credential-rule:rule-console:console_access",
		7,
		"rule-console",
	)
	want := "470356f22e46c9fcb1a5ddfcb9d8597ec520941418459b6211a75ea5a4ac0167"
	if got != want {
		t.Fatalf("assignment policy fingerprint = %q, want %q", got, want)
	}
}

func TestProxmoxHostAuthorityStaysOutsideWasmAndRejectsSmuggling(t *testing.T) {
	t.Parallel()

	valid := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	bindings, _ := valid.pluginHostAuthoritySnapshot()
	if len(bindings) != 1 {
		t.Fatalf("host bindings = %d, want 1", len(bindings))
	}
	if strings.Contains(string(valid.ParamsJSON), bindings[0].credentialBroker.CredentialSecretRef) ||
		strings.Contains(string(valid.ParamsJSON), bindings[0].credentialBroker.GrantID) {
		t.Fatalf("Wasm-visible params retained host-only grant data: %s", valid.ParamsJSON)
	}
	if !strings.Contains(string(valid.ParamsJSON), pluginHostCredentialSentinel) {
		t.Fatalf("Wasm-visible params do not contain the host sentinel: %s", valid.ParamsJSON)
	}

	for name, params := range map[string]string{
		"inline api token":    `{"credential_rule_id":"proxmox-rule-1","api_token":"PVEAPIToken=user@pve!id=secret"}`,
		"inline ssh password": `{"credential_rule_id":"proxmox-rule-1","credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__","ssh":{"password":"secret"}}`,
		"broker grant":        `{"credential_rule_id":"proxmox-rule-1","credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__","credential_broker":{"grant_id":"grant-smuggled"}}`,
		"secret reference":    `{"credential_rule_id":"proxmox-rule-1","credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__","credential_secret_ref":"credential://smuggled"}`,
	} {
		t.Run(name, func(t *testing.T) {
			options := testConsoleAuthorityOptions()
			options.paramsJSON = params
			assignment := newTestProxmoxHostAuthorityAssignment(t, options)
			assertProxmoxAssignmentFailedClosed(t, assignment)
		})
	}
}

func TestProxmoxHostAuthorityRejectsMalformedOrAmbiguousEnvelope(t *testing.T) {
	t.Parallel()

	options := testConsoleAuthorityOptions()
	validHostJSON := testProxmoxHostAuthorityJSON(t, options)
	validParams := options.paramsJSON

	mutated := func(change func(map[string]any)) []byte {
		t.Helper()
		var envelope map[string]any
		if err := json.Unmarshal(validHostJSON, &envelope); err != nil {
			t.Fatalf("decode valid host authority: %v", err)
		}
		change(envelope)
		encoded, err := json.Marshal(envelope)
		if err != nil {
			t.Fatalf("marshal mutated host authority: %v", err)
		}
		return encoded
	}
	bindingMap := func(envelope map[string]any) map[string]any {
		t.Helper()
		return envelope["bindings"].([]any)[0].(map[string]any)
	}

	tests := map[string][]byte{
		"unknown envelope field": mutated(func(envelope map[string]any) {
			envelope["future_authority"] = true
		}),
		"non canonical origin": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["origin"] = "https://192.0.2.10"
		}),
		"cleartext origin": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["origin"] = "http://192.0.2.10:8006"
		}),
		"unpinned hostname origin": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["origin"] = "https://pve01.example.test:8006"
		}),
		"insecure TLS": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["insecure_skip_verify"] = true
		}),
		"rule mismatch": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["credential_rule_id"] = "different-rule"
		}),
		"missing assignment policy version": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope), "assignment_policy_version")
		}),
		"assignment policy version mismatch": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["assignment_policy_version"] = float64(2)
		}),
		"missing assignment policy fingerprint": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope), "assignment_policy_fingerprint")
		}),
		"assignment policy fingerprint mismatch": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["assignment_policy_fingerprint"] = strings.Repeat("0", 64)
		}),
		"missing v3 controller id": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope)["target_ids"].(map[string]any), "controller_id")
		}),
		"missing integration id": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope)["target_ids"].(map[string]any), "integration_id")
		}),
		"missing controller device uid": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope)["target_ids"].(map[string]any), "device_uid")
		}),
		"missing controller provider ref": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope)["target_ids"].(map[string]any), "provider_ref")
		}),
		"missing controller node": mutated(func(envelope map[string]any) {
			delete(bindingMap(envelope)["target_ids"].(map[string]any), "node")
		}),
		"provider instance mismatch": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["target_ids"].(map[string]any)["provider_instance_ref"] =
				"proxmox:v3:018f2fd1-0000-7000-8000-000000000003:" + testProxmoxControllerID + ":farm%3A01"
		}),
		"source integration mismatch": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["target_ids"].(map[string]any)["integration_id"] =
				"018f2fd1-0000-7000-8000-000000000003"
		}),
		"noncanonical cluster encoding": mutated(func(envelope map[string]any) {
			ids := bindingMap(envelope)["target_ids"].(map[string]any)
			ids["provider_instance_ref"] = strings.Replace(testProxmoxProviderInstanceRef, "%3A", "%3a", 1)
			ids["provider_ref"] = strings.Replace(testProxmoxControllerRef, "%3A", "%3a", 1)
		}),
		"unknown target id": mutated(func(envelope map[string]any) {
			bindingMap(envelope)["target_ids"].(map[string]any)["future_identity"] = "unreviewed"
		}),
		"wildcard console grant path": mutated(func(envelope map[string]any) {
			grant := bindingMap(envelope)["credential_broker"].(map[string]any)
			grant["allow"].(map[string]any)["paths"] = []any{"/api2/json/nodes/*"}
		}),
		"duplicate exact scope": mutated(func(envelope map[string]any) {
			binding := bindingMap(envelope)
			encoded, _ := json.Marshal(binding)
			var duplicate map[string]any
			_ = json.Unmarshal(encoded, &duplicate)
			duplicate["binding_id"] = "binding-duplicate"
			envelope["bindings"] = append(envelope["bindings"].([]any), duplicate)
		}),
		"trailing object": append(append([]byte(nil), validHostJSON...), []byte(` {}`)...),
		"duplicate schema field": []byte(strings.Replace(
			string(validHostJSON),
			`"schema":"serviceradar.plugin_host_authority.v1"`,
			`"schema":"serviceradar.plugin_host_authority.v1","schema":"serviceradar.plugin_host_authority.v1"`,
			1,
		)),
	}

	for name, hostJSON := range tests {
		t.Run(name, func(t *testing.T) {
			assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
				AssignmentId:   "invalid-proxmox-host-authority",
				PluginId:       proxmoxConsolePluginID,
				Entrypoint:     proxmoxConsoleEntrypoint,
				ParamsJson:     []byte(validParams),
				HostParamsJson: hostJSON,
			}, logger.NewTestLogger())
			assertProxmoxAssignmentFailedClosed(t, assignment)
		})
	}
}

func TestParseAgentProxmoxV3ProviderRefIsCanonicalAndSourceScoped(t *testing.T) {
	t.Parallel()

	identity, ok := parseAgentProxmoxProviderRef(testProxmoxGuestRef)
	if !ok {
		t.Fatal("canonical v3 provider ref was rejected")
	}
	if identity.integrationID != testProxmoxIntegrationID ||
		identity.controllerID != testProxmoxControllerID ||
		identity.providerInstanceRef != testProxmoxProviderInstanceRef ||
		identity.nativeClusterID != testProxmoxNativeClusterID || identity.objectKind != "qemu" ||
		identity.nativeObjectID != "101" {
		t.Fatalf("parsed v3 identity = %#v", identity)
	}

	for name, providerRef := range map[string]string{
		"noncanonical lowercase escape": strings.Replace(testProxmoxGuestRef, "%3A", "%3a", 1),
		"escaped unreserved byte":       strings.Replace(testProxmoxGuestRef, "qemu:101", "qemu:%31%30%31", 1),
		"uppercase object kind":         strings.Replace(testProxmoxGuestRef, ":qemu:", ":QEMU:", 1),
		"non UUID integration":          strings.Replace(testProxmoxGuestRef, testProxmoxIntegrationID, "integration-1", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, ok := parseAgentProxmoxProviderRef(providerRef); ok {
				t.Fatalf("noncanonical v3 ref %q was accepted", providerRef)
			}
		})
	}
}

func TestProxmoxHostAuthorityLeaseRefreshUsesStableScopeFingerprint(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	firstOptions := testConsoleAuthorityOptions()
	firstOptions.assignmentID = "lease-refresh"
	firstOptions.grantID = "grant-old"
	firstOptions.expiresAt = now.Add(10 * time.Minute).Format(time.RFC3339)
	firstOptions.ttlSeconds = 60
	secondOptions := firstOptions
	secondOptions.grantID = "grant-new"
	secondOptions.expiresAt = now.Add(20 * time.Minute).Format(time.RFC3339)
	secondOptions.ttlSeconds = 120

	current := newTestProxmoxHostAuthorityAssignment(t, firstOptions)
	fresh := newTestProxmoxHostAuthorityAssignment(t, secondOptions)
	_, currentFingerprint := current.pluginHostAuthoritySnapshot()
	_, freshFingerprint := fresh.pluginHostAuthoritySnapshot()
	if currentFingerprint == "" || currentFingerprint != freshFingerprint {
		t.Fatalf("volatile lease fields changed stable fingerprint: %q != %q", currentFingerprint, freshFingerprint)
	}
	if buildPluginConfigHash(pluginEngineLimits{}, []*pluginAssignment{current}) !=
		buildPluginConfigHash(pluginEngineLimits{}, []*pluginAssignment{fresh}) {
		t.Fatal("volatile lease refresh changed plugin config hash")
	}

	current.refreshPluginHostAuthority(fresh)
	bindings, _ := current.pluginHostAuthoritySnapshot()
	if got := bindings[0].credentialBroker.GrantID; got != "grant-new" {
		t.Fatalf("refreshed grant id = %q, want grant-new", got)
	}
	if got := bindings[0].credentialBroker.ExpiresAt; got != secondOptions.expiresAt {
		t.Fatalf("refreshed expiry = %q, want %q", got, secondOptions.expiresAt)
	}

	changedOptions := secondOptions
	changedOptions.secretRef = "credential://different-stable-secret"
	changed := newTestProxmoxHostAuthorityAssignment(t, changedOptions)
	_, changedFingerprint := changed.pluginHostAuthoritySnapshot()
	if changedFingerprint == freshFingerprint {
		t.Fatal("stable secret scope change did not change host authority fingerprint")
	}
	current.refreshPluginHostAuthority(changed)
	bindings, _ = current.pluginHostAuthoritySnapshot()
	if got := bindings[0].credentialBroker.CredentialSecretRef; got != secondOptions.secretRef {
		t.Fatalf("mismatched stable scope replaced current authority: %q", got)
	}
}

func TestProxmoxInventoryHostAuthorityInjectsOnlyForExactIPOriginAndRequest(t *testing.T) {
	t.Parallel()

	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: "user@pve!inventory=super-secret"},
	}
	var sentAuthorization string
	transport := &countingPluginHTTPTransport{
		respond: func(req *http.Request) *http.Response {
			sentAuthorization = req.Header.Get("Authorization")
			return pluginHTTPTestResponse(req, http.StatusOK, nil, `{"ok":true}`)
		},
	}
	permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006}}
	exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, resolver)
	assignment := newTestProxmoxHostAuthorityAssignment(t, testInventoryAuthorityOptions())
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	exec.assignment = assignment
	exec.configJSON = assignment.ParamsJSON
	exec.mode = pluginExecutionModeScheduled

	got := callPluginHostHTTPRequestPayload(t, exec, module, httpRequestPayload{
		Method: http.MethodGet,
		URL:    testProxmoxOrigin + "/api2/json/version",
		Headers: map[string]string{
			"Authorization": pluginHostCredentialSentinel,
		},
	})
	if got <= 0 || transport.calls != 1 {
		t.Fatalf("exact Proxmox request returned %d with %d transport calls", got, transport.calls)
	}
	if sentAuthorization != "PVEAPIToken=user@pve!inventory=super-secret" {
		t.Fatalf("outbound Authorization = %q, want normalized host token", sentAuthorization)
	}
	if resolver.calls != 1 {
		t.Fatalf("credential resolver calls = %d, want 1", resolver.calls)
	}
}

func TestProxmoxInventoryHostAuthorityDeniesBeforeCredentialResolution(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name               string
		method             string
		requestURL         string
		authorization      string
		body               string
		insecureSkipVerify bool
	}{
		{name: "wrong host", method: http.MethodGet, requestURL: "https://192.0.2.11:8006/api2/json/version", authorization: pluginHostCredentialSentinel},
		{name: "wrong port", method: http.MethodGet, requestURL: "https://192.0.2.10:8443/api2/json/version", authorization: pluginHostCredentialSentinel},
		{name: "wrong method", method: http.MethodPost, requestURL: testProxmoxOrigin + "/api2/json/version", authorization: pluginHostCredentialSentinel},
		{name: "wrong path", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/access/users", authorization: pluginHostCredentialSentinel},
		{name: "cleartext HTTP", method: http.MethodGet, requestURL: "http://192.0.2.10:8006/api2/json/version", authorization: pluginHostCredentialSentinel},
		{name: "arbitrary node suffix", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/nodes/pve01/access/users", authorization: pluginHostCredentialSentinel},
		{name: "sensitive node endpoint", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/nodes/pve01/execute", authorization: pluginHostCredentialSentinel},
		{name: "query parameters", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/version?full=1", authorization: pluginHostCredentialSentinel},
		{name: "GET body", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/version", authorization: pluginHostCredentialSentinel, body: `{"smuggled":true}`},
		{name: "raw token", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/version", authorization: "PVEAPIToken=module-controlled"},
		{name: "TLS policy mismatch", method: http.MethodGet, requestURL: testProxmoxOrigin + "/api2/json/version", authorization: pluginHostCredentialSentinel, insecureSkipVerify: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Value: "secret"}}
			transport := &countingPluginHTTPTransport{}
			permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006, 8443}}
			exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, resolver)
			assignment := newTestProxmoxHostAuthorityAssignment(t, testInventoryAuthorityOptions())
			assignment.Permissions = permissions
			assignment.Permissions.normalize()
			exec.assignment = assignment
			exec.configJSON = assignment.ParamsJSON
			exec.mode = pluginExecutionModeScheduled

			got := callPluginHostHTTPRequestPayload(t, exec, module, httpRequestPayload{
				Method:             test.method,
				URL:                test.requestURL,
				Headers:            map[string]string{"Authorization": test.authorization},
				Body:               test.body,
				InsecureSkipVerify: test.insecureSkipVerify,
			})
			if got != pluginErrDenied || transport.calls != 0 || resolver.calls != 0 {
				t.Fatalf("got=%d transport=%d resolver=%d, want denial before resolution", got, transport.calls, resolver.calls)
			}
		})
	}
}

func TestProxmoxInventorySemanticRequestRegistry(t *testing.T) {
	t.Parallel()

	for _, path := range []string{
		"/api2/json/version",
		"/api2/json/cluster/status",
		"/api2/json/cluster/resources",
		"/api2/json/nodes",
		"/api2/json/nodes/pve01/status",
		"/api2/json/nodes/pve01/storage",
		"/api2/json/nodes/pve01/network",
		"/api2/json/nodes/pve01/disks/list",
		"/api2/json/nodes/pve01/ceph/status",
		"/api2/json/nodes/pve01/qemu",
		"/api2/json/nodes/pve01/lxc",
		"/api2/json/nodes/pve01/qemu/101/config",
		"/api2/json/nodes/pve01/lxc/102/config",
		"/api2/json/nodes/pve01/qemu/101/agent/network-get-interfaces",
		"/api2/json/nodes/pve01/qemu/101/agent/get-fsinfo",
		"/api2/json/nodes/pve01/lxc/102/interfaces",
	} {
		t.Run("allow "+path, func(t *testing.T) {
			requestURL, err := url.Parse(testProxmoxOrigin + path)
			if err != nil || !proxmoxInventoryHostAuthorityRequestAllowed(http.MethodGet, requestURL, nil) {
				t.Fatalf("first-party inventory path %q denied: %v", path, err)
			}
		})
	}

	for _, path := range []string{
		"/api2/json/nodes/pve01/access/users",
		"/api2/json/nodes/pve01/status/current",
		"/api2/json/nodes/pve01/ceph/osd",
		"/api2/json/nodes/pve01/qemu/0/config",
		"/api2/json/nodes/pve01/qemu/not-a-vmid/config",
		"/api2/json/nodes/pve01/qemu/101/config/extra",
		"/api2/json/nodes/pve01/qemu/101/agent/exec",
		"/api2/json/nodes/pve01/lxc/102/status/current",
		"/api2/json/version?full=1",
		"/api2/json/version?",
	} {
		t.Run("deny "+path, func(t *testing.T) {
			requestURL, err := url.Parse(testProxmoxOrigin + path)
			if err != nil {
				t.Fatalf("parse path %q: %v", path, err)
			}
			if proxmoxInventoryHostAuthorityRequestAllowed(http.MethodGet, requestURL, nil) {
				t.Fatalf("unregistered inventory path %q was accepted", path)
			}
		})
	}
}

func TestProxmoxHostCredentialNeverFollowsRedirect(t *testing.T) {
	t.Parallel()

	resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Value: "redirect-secret"}}
	transport := &countingPluginHTTPTransport{
		respond: func(req *http.Request) *http.Response {
			return pluginHTTPTestResponse(
				req,
				http.StatusFound,
				map[string]string{"Location": testProxmoxOrigin + "/api2/json/nodes"},
				"redirect",
			)
		},
	}
	permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006}}
	exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, resolver)
	assignment := newTestProxmoxHostAuthorityAssignment(t, testInventoryAuthorityOptions())
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	exec.assignment = assignment
	exec.configJSON = assignment.ParamsJSON
	exec.mode = pluginExecutionModeScheduled

	got := callPluginHostHTTPRequestPayload(t, exec, module, httpRequestPayload{
		Method:  http.MethodGet,
		URL:     testProxmoxOrigin + "/api2/json/version",
		Headers: map[string]string{"Authorization": pluginHostCredentialSentinel},
	})
	if got <= 0 || transport.calls != 1 {
		t.Fatalf("redirect result=%d transport calls=%d, want original response only", got, transport.calls)
	}
}

func TestProxmoxConsoleBindingSeparatesControllerAndGuestIdentity(t *testing.T) {
	t.Parallel()

	spec := testProxmoxGuestConsoleSessionSpec()
	controllerBinding := pluginHostAuthorityBinding{
		credentialRuleID: testProxmoxCredentialRuleID,
		origin:           testProxmoxOrigin,
		targetIDs:        testProxmoxControllerTargetIDs(),
	}
	if !pluginHostAuthorityBindingMatchesConsole(controllerBinding, spec) {
		t.Fatal("controller-scoped binding did not match authoritative controller identity")
	}
	proxyPath, websocketPath, err := expectedProxmoxConsolePaths(spec, controllerBinding)
	if err != nil {
		t.Fatalf("expectedProxmoxConsolePaths returned error: %v", err)
	}
	if proxyPath != "/api2/json/nodes/pve01/qemu/101/vncproxy" ||
		websocketPath != "/api2/json/nodes/pve01/qemu/101/vncwebsocket" {
		t.Fatalf("unexpected guest console paths: %q %q", proxyPath, websocketPath)
	}

	subjectTargetIDs := testProxmoxGuestTargetIDs()
	subjectBinding := controllerBinding
	subjectBinding.targetIDs = subjectTargetIDs
	if !pluginHostAuthorityBindingMatchesConsole(subjectBinding, spec) {
		t.Fatal("subject-scoped binding did not match authoritative guest identity")
	}

	missingController := spec
	missingController.Target.ControllerID = ""
	missingController.Target.ProviderRef = "proxmox:guest:pve01:qemu:101"
	missingController.Target.ControllerRef = "proxmox:node:pve01"
	if pluginHostAuthorityBindingMatchesConsole(controllerBinding, missingController) {
		t.Fatal("binding matched after a declared v3 controller identity became unavailable")
	}

	wrongVMID := spec
	wrongVMID.Target.VMID = 102
	if pluginHostAuthorityBindingMatchesConsole(subjectBinding, wrongVMID) {
		t.Fatal("subject binding matched a different guest vmid")
	}

	pveKindBinding := controllerBinding
	pveKindBinding.targetIDs = cloneHostAuthorityStringMap(controllerBinding.targetIDs)
	pveKindBinding.targetIDs["target_kind"] = "pve_host"
	if pluginHostAuthorityBindingMatchesConsole(pveKindBinding, spec) {
		t.Fatal("PVE target_kind binding matched a guest console subject")
	}
}

func TestProxmoxConsoleSubjectBindingRequiresExactGuestAndControllerIdentity(t *testing.T) {
	t.Parallel()

	validOptions := testConsoleAuthorityOptions()
	validOptions.targetIDs = testProxmoxGuestTargetIDs()
	valid := newTestProxmoxHostAuthorityAssignment(t, validOptions)
	bindings, _ := valid.pluginHostAuthoritySnapshot()
	if len(bindings) != 1 || !pluginHostAuthorityBindingMatchesConsole(bindings[0], testProxmoxGuestConsoleSessionSpec()) {
		t.Fatal("exact guest-scoped binding was not retained or did not match")
	}

	for _, key := range []string{
		"device_uid",
		"provider_ref",
		"vmid",
		"target_kind",
		"object_kind",
		"native_object_id",
		"controller_device_uid",
		"controller_provider_ref",
	} {
		t.Run("missing "+key, func(t *testing.T) {
			options := validOptions
			options.targetIDs = cloneHostAuthorityStringMap(validOptions.targetIDs)
			delete(options.targetIDs, key)
			assertProxmoxAssignmentFailedClosed(t, newTestProxmoxHostAuthorityAssignment(t, options))
		})
	}

	for name, mutate := range map[string]func(map[string]string){
		"guest kind mismatch": func(ids map[string]string) { ids["target_kind"] = "lxc_guest" },
		"guest vmid mismatch": func(ids map[string]string) { ids["native_object_id"] = "102" },
		"controller node mismatch": func(ids map[string]string) {
			ids["controller_provider_ref"] = testProxmoxProviderInstanceRef + ":node:pve02"
		},
	} {
		t.Run(name, func(t *testing.T) {
			options := validOptions
			options.targetIDs = cloneHostAuthorityStringMap(validOptions.targetIDs)
			mutate(options.targetIDs)
			assertProxmoxAssignmentFailedClosed(t, newTestProxmoxHostAuthorityAssignment(t, options))
		})
	}
}

func TestLookupProxmoxConsoleAssignmentRequiresExactAssignmentAndRule(t *testing.T) {
	t.Parallel()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	t.Cleanup(manager.Stop)
	firstOptions := testConsoleAuthorityOptions()
	firstOptions.assignmentID = "console-1"
	first := newTestProxmoxHostAuthorityAssignment(t, firstOptions)
	secondOptions := firstOptions
	secondOptions.assignmentID = "console-2"
	second := newTestProxmoxHostAuthorityAssignment(t, secondOptions)
	manager.mu.Lock()
	manager.streams[first.AssignmentID] = first
	manager.streams[second.AssignmentID] = second
	manager.mu.Unlock()

	exact := testProxmoxGuestConsoleSessionSpec()
	exact.PluginAssignmentID = first.AssignmentID
	bindTestProxmoxSessionPolicy(t, &exact, first)
	assignment, err := manager.lookupProxmoxConsoleAssignment(exact)
	if err != nil || assignment != first {
		t.Fatalf("exact assignment lookup = %#v, %v", assignment, err)
	}

	for name, mutate := range map[string]func(*proxmoxConsoleSessionSpec){
		"missing assignment": func(spec *proxmoxConsoleSessionSpec) { spec.PluginAssignmentID = "" },
		"missing rule":       func(spec *proxmoxConsoleSessionSpec) { spec.CredentialRuleID = "" },
		"substituted rule":   func(spec *proxmoxConsoleSessionSpec) { spec.CredentialRuleID = "different-rule" },
		"unknown assignment": func(spec *proxmoxConsoleSessionSpec) { spec.PluginAssignmentID = "console-missing" },
		"missing policy version": func(spec *proxmoxConsoleSessionSpec) {
			spec.AssignmentPolicyVersion = 0
		},
		"policy version mismatch": func(spec *proxmoxConsoleSessionSpec) {
			spec.AssignmentPolicyVersion++
		},
		"missing policy fingerprint": func(spec *proxmoxConsoleSessionSpec) {
			spec.AssignmentPolicyFingerprint = ""
		},
		"policy fingerprint mismatch": func(spec *proxmoxConsoleSessionSpec) {
			spec.AssignmentPolicyFingerprint = strings.Repeat("0", 64)
		},
	} {
		t.Run(name, func(t *testing.T) {
			spec := exact
			mutate(&spec)
			if assignment, err := manager.lookupProxmoxConsoleAssignment(spec); err == nil || assignment != nil {
				t.Fatalf("substituted lookup = %#v, %v; want denial", assignment, err)
			}
		})
	}
}

func TestProxmoxConsoleNativeHTTPAndWebSocketUseExactSessionPath(t *testing.T) {
	t.Parallel()

	options := testConsoleAuthorityOptions()
	options.methods = []string{http.MethodGet, http.MethodPost}
	options.paths = []string{
		"/api2/json/nodes/pve01/qemu/101/vncproxy",
		"/api2/json/nodes/pve01/qemu/101/vncwebsocket",
	}
	options.ports = []int{8006}
	assignment := newTestProxmoxHostAuthorityAssignment(t, options)
	resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Value: "user@pve!console=secret"}}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:           logger.NewTestLogger(),
		CredentialBroker: resolver,
	})
	t.Cleanup(manager.Stop)
	exec := newPluginExecution(manager, assignment)
	exec.mode = pluginExecutionModeStreaming
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	proxyURL, _ := url.Parse(testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy")
	binding, err := exec.proxmoxHostAuthorityForHTTPRequest(http.MethodPost, proxyURL, nil, false)
	if err != nil || binding == nil {
		t.Fatalf("exact proxy request was denied: binding=%v err=%v", binding, err)
	}

	const providerTicket = "PVEVNC:provider-secret-ticket"
	protected, err := exec.protectProxmoxConsoleProxyResponse(
		binding,
		proxyURL,
		http.StatusOK,
		[]byte(`{"data":{"port":5900,"ticket":"`+providerTicket+`","user":"root@pam"}}`),
	)
	if err != nil {
		t.Fatalf("protect proxy response: %v", err)
	}
	if strings.Contains(string(protected), providerTicket) ||
		!strings.Contains(string(protected), proxmoxConsoleTicketSentinel) {
		t.Fatalf("Wasm-visible proxy response = %s", protected)
	}

	for name, rawURL := range map[string]string{
		"wrong path": "wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/102/vncwebsocket?port=5900&vncticket=" +
			proxmoxConsoleTicketSentinel,
		"wrong port": "wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5901&vncticket=" +
			proxmoxConsoleTicketSentinel,
		"raw ticket": "wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
			url.QueryEscape(providerTicket),
		"extra query": "wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
			proxmoxConsoleTicketSentinel + "&extra=true",
		"missing ticket": "wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900",
	} {
		t.Run(name, func(t *testing.T) {
			requestURL, _ := url.Parse(rawURL)
			if _, err := exec.proxmoxHostAuthorityForWebSocket(
				requestURL,
				http.Header{"Authorization": []string{pluginHostCredentialSentinel}},
				false,
			); err == nil {
				t.Fatalf("websocket request %q was accepted", rawURL)
			}
		})
	}

	wsURL, _ := url.Parse("wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
		proxmoxConsoleTicketSentinel)
	headers := http.Header{"Authorization": []string{pluginHostCredentialSentinel}}
	binding, err = exec.proxmoxHostAuthorityForWebSocket(wsURL, headers, false)
	if err != nil || binding == nil {
		t.Fatalf("exact websocket request was denied: binding=%v err=%v", binding, err)
	}
	if err := exec.applyProxmoxHostAuthorityWebSocketCredential(t.Context(), headers, binding); err != nil {
		t.Fatalf("apply websocket credential: %v", err)
	}
	if got := headers.Get("Authorization"); got != "PVEAPIToken=user@pve!console=secret" {
		t.Fatalf("websocket Authorization = %q", got)
	}
	dialURL, err := exec.consumeProxmoxConsoleTicket(wsURL, binding)
	if err != nil || dialURL.Query().Get("vncticket") != providerTicket {
		t.Fatalf("trusted ticket substitution = %v, %v", dialURL, err)
	}
	if _, err := exec.proxmoxHostAuthorityForWebSocket(
		wsURL,
		http.Header{"Authorization": []string{pluginHostCredentialSentinel}},
		false,
	); err == nil {
		t.Fatal("consumed provider ticket was replayable")
	}
}

func TestProxmoxConsoleTicketExpiresBeforeCredentialResolution(t *testing.T) {
	t.Parallel()

	assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Value: "must-not-resolve"}}
	now := time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:           logger.NewTestLogger(),
		CredentialBroker: resolver,
	})
	manager.credentialNow = func() time.Time { return now }
	t.Cleanup(manager.Stop)
	exec := newPluginExecution(manager, assignment)
	exec.mode = pluginExecutionModeStreaming
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	proxyURL, _ := url.Parse(testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy")
	binding, err := exec.proxmoxHostAuthorityForHTTPRequest(http.MethodPost, proxyURL, nil, false)
	if err != nil || binding == nil {
		t.Fatalf("proxy authority: %v", err)
	}
	if _, err := exec.protectProxmoxConsoleProxyResponse(
		binding,
		proxyURL,
		http.StatusOK,
		[]byte(`{"data":{"port":5900,"ticket":"expires-secret"}}`),
	); err != nil {
		t.Fatalf("protect proxy response: %v", err)
	}
	now = now.Add(proxmoxConsoleTicketTTL + time.Second)
	wsURL, _ := url.Parse("wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
		proxmoxConsoleTicketSentinel)
	if _, err := exec.proxmoxHostAuthorityForWebSocket(
		wsURL,
		http.Header{"Authorization": []string{pluginHostCredentialSentinel}},
		false,
	); err == nil {
		t.Fatal("expired provider ticket was accepted")
	}
	if resolver.calls != 0 {
		t.Fatalf("expired ticket caused %d credential resolutions", resolver.calls)
	}
}

func TestProxmoxConsoleMalformedReplacementClearsPriorTicket(t *testing.T) {
	t.Parallel()

	assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	t.Cleanup(manager.Stop)
	exec := newPluginExecution(manager, assignment)
	exec.mode = pluginExecutionModeStreaming
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	proxyURL, _ := url.Parse(testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy")
	binding, err := exec.proxmoxHostAuthorityForHTTPRequest(http.MethodPost, proxyURL, nil, false)
	if err != nil || binding == nil {
		t.Fatalf("proxy authority: %v", err)
	}
	if _, err := exec.protectProxmoxConsoleProxyResponse(
		binding,
		proxyURL,
		http.StatusOK,
		[]byte(`{"data":{"port":5900,"ticket":"must-be-cleared"}}`),
	); err != nil {
		t.Fatalf("protect initial proxy response: %v", err)
	}
	if _, err := exec.protectProxmoxConsoleProxyResponse(
		binding,
		proxyURL,
		http.StatusOK,
		[]byte(`{"data":{"port":5900,"ticket":`),
	); err == nil {
		t.Fatal("malformed replacement response was accepted")
	}

	wsURL, _ := url.Parse("wss://192.0.2.10:8006/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
		proxmoxConsoleTicketSentinel)
	if _, err := exec.proxmoxHostAuthorityForWebSocket(
		wsURL,
		http.Header{"Authorization": []string{pluginHostCredentialSentinel}},
		false,
	); err == nil {
		t.Fatal("prior provider ticket survived a malformed replacement response")
	}
}

func TestProxmoxConsoleProxyHostResponseNeverExposesProviderTicket(t *testing.T) {
	t.Parallel()

	const providerTicket = "PVEVNC:never-cross-the-wasm-boundary"
	transport := &countingPluginHTTPTransport{
		respond: func(req *http.Request) *http.Response {
			return pluginHTTPTestResponse(
				req,
				http.StatusOK,
				nil,
				`{"data":{"port":5900,"ticket":"`+providerTicket+`","user":"root@pam"}}`,
			)
		},
	}
	resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Value: "user@pve!console=api-secret"}}
	permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006}}
	exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, resolver)
	assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	exec.assignment = assignment
	exec.configJSON = assignment.ParamsJSON
	exec.mode = pluginExecutionModeStreaming
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	requestBytes, err := json.Marshal(httpRequestPayload{
		Method: http.MethodPost,
		URL:    testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy",
		Headers: map[string]string{
			"Authorization": pluginHostCredentialSentinel,
		},
	})
	if err != nil {
		t.Fatalf("marshal proxy request: %v", err)
	}
	const requestPtr = uint32(0)
	const responsePtr = uint32(32 * 1024)
	const responseLen = uint32(16 * 1024)
	if !module.Memory().Write(requestPtr, requestBytes) {
		t.Fatal("write proxy request")
	}
	written := exec.hostHTTPRequest(
		t.Context(), module, requestPtr, uint32(len(requestBytes)), responsePtr, responseLen,
	)
	if written <= 0 {
		t.Fatalf("proxy host request returned %d", written)
	}
	responseBytes, ok := module.Memory().Read(responsePtr, uint32(written))
	if !ok {
		t.Fatal("read proxy response")
	}
	var response httpResponsePayload
	if err := json.Unmarshal(responseBytes, &response); err != nil {
		t.Fatalf("decode proxy host response: %v", err)
	}
	body, err := base64.StdEncoding.DecodeString(response.BodyBase64)
	if err != nil {
		t.Fatalf("decode proxy body: %v", err)
	}
	if strings.Contains(string(body), providerTicket) || !strings.Contains(string(body), proxmoxConsoleTicketSentinel) {
		t.Fatalf("Wasm-visible proxy body = %s", body)
	}
}

func TestProxmoxHTTPRevocationBarrierStopsDialAfterCredentialResolution(t *testing.T) {
	resolver := newBlockingProxmoxCredentialResolver(CredentialBrokerMaterial{
		Value: "user@pve!console=api-secret",
	})
	transport := &countingPluginHTTPTransport{}
	permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006}}
	exec, module := newPluginHTTPHostTestExecution(t, permissions, transport, resolver)
	assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	bindTestProxmoxExecutionGeneration(exec, assignment)
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	payload, err := json.Marshal(httpRequestPayload{
		Method: http.MethodPost,
		URL:    testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy",
		Headers: map[string]string{
			"Authorization": pluginHostCredentialSentinel,
		},
	})
	if err != nil {
		t.Fatalf("marshal proxy request: %v", err)
	}
	if !module.Memory().Write(0, payload) {
		t.Fatal("write proxy request")
	}

	done := make(chan int32, 1)
	go func() {
		done <- exec.hostHTTPRequest(
			t.Context(),
			module,
			0,
			uint32(len(payload)),
			32*1024,
			16*1024,
		)
	}()

	resolver.waitStarted(t)
	exec.manager.ApplyConfig(nil)
	close(resolver.release)

	select {
	case result := <-done:
		if result != pluginErrDenied {
			t.Fatalf("revoked HTTP request returned %d, want %d", result, pluginErrDenied)
		}
	case <-time.After(time.Second):
		t.Fatal("revoked HTTP request did not complete")
	}
	if transport.calls != 0 {
		t.Fatalf("revoked HTTP request reached transport %d times", transport.calls)
	}
}

func TestProxmoxWebSocketRevocationBarrierStopsDialAfterCredentialResolution(t *testing.T) {
	resolver := newBlockingProxmoxCredentialResolver(CredentialBrokerMaterial{
		Value: "user@pve!console=api-secret",
	})
	permissions := pluginPermissions{AllowedDomains: []string{"*"}, AllowedPorts: []int{8006}}
	exec, module := newPluginHTTPHostTestExecution(
		t,
		permissions,
		&countingPluginHTTPTransport{},
		resolver,
	)
	assignment := newTestProxmoxHostAuthorityAssignment(t, testConsoleAuthorityOptions())
	assignment.Permissions = permissions
	assignment.Permissions.normalize()
	bindTestProxmoxExecutionGeneration(exec, assignment)
	exec.consoleSessionSpec = testProxmoxGuestConsoleSessionSpec()

	proxyURL, _ := url.Parse(testProxmoxOrigin + "/api2/json/nodes/pve01/qemu/101/vncproxy")
	binding, err := exec.proxmoxHostAuthorityForHTTPRequest(http.MethodPost, proxyURL, nil, false)
	if err != nil || binding == nil {
		t.Fatalf("proxy authority: binding=%v err=%v", binding, err)
	}
	if _, err := exec.protectProxmoxConsoleProxyResponse(
		binding,
		proxyURL,
		http.StatusOK,
		[]byte(`{"data":{"port":5900,"ticket":"provider-ticket"}}`),
	); err != nil {
		t.Fatalf("protect proxy response: %v", err)
	}

	request, err := json.Marshal(websocketConnectPayload{
		URL: testProxmoxOrigin +
			"/api2/json/nodes/pve01/qemu/101/vncwebsocket?port=5900&vncticket=" +
			proxmoxConsoleTicketSentinel,
		Headers: map[string]string{"Authorization": pluginHostCredentialSentinel},
	})
	if err != nil {
		t.Fatalf("marshal websocket request: %v", err)
	}
	request = []byte(strings.Replace(string(request), `"https://`, `"wss://`, 1))
	if !module.Memory().Write(0, request) {
		t.Fatal("write websocket request")
	}

	dialCalls := 0
	exec.webSocketDialer = func(
		context.Context,
		string,
		http.Header,
		time.Duration,
		bool,
	) (*websocket.Conn, *http.Response, error) {
		dialCalls++
		return nil, nil, errUnexpectedProxmoxWebSocketDial
	}

	done := make(chan int32, 1)
	go func() {
		done <- exec.hostWebSocketConnect(t.Context(), module, 0, uint32(len(request)), 500)
	}()

	resolver.waitStarted(t)
	exec.manager.ApplyConfig(nil)
	close(resolver.release)

	select {
	case result := <-done:
		if result != pluginErrDenied {
			t.Fatalf("revoked WebSocket request returned %d, want %d", result, pluginErrDenied)
		}
	case <-time.After(time.Second):
		t.Fatal("revoked WebSocket request did not complete")
	}
	if dialCalls != 0 {
		t.Fatalf("revoked WebSocket request dialed %d times", dialCalls)
	}
}

func TestProxmoxSSHRevocationBarrierStopsDialAfterCredentialResolution(t *testing.T) {
	options := testConsoleAuthorityOptions()
	options.paramsJSON = `{
		"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
		"policy_version":1,
		"credential_rule_id":"proxmox-rule-1",
		"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__"
	}`
	options.sshHostKeyPolicy = proxmoxSSHHostKeyPolicyTrustFirstUse
	options.methods = nil
	options.paths = nil
	options.ports = []int{22}
	assignment := newTestProxmoxHostAuthorityAssignment(t, options)
	resolver := newBlockingProxmoxCredentialResolver(CredentialBrokerMaterial{Fields: map[string]string{
		"username": "root",
		"password": "host-resolved-password",
	}})
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	t.Cleanup(manager.Stop)
	exec := newPluginExecution(manager, assignment)
	bindTestProxmoxExecutionGeneration(exec, assignment)
	exec.consoleSessionSpec = testProxmoxPVEConsoleSessionSpec()

	type configResult struct {
		config proxmoxConsoleSSHConfig
		err    error
	}
	done := make(chan configResult, 1)
	go func() {
		cfg, err := exec.trustedProxmoxConsoleSSHConfig(
			t.Context(),
			exec.consoleSessionSpec.SessionID,
		)
		done <- configResult{config: cfg, err: err}
	}()

	resolver.waitStarted(t)
	manager.ApplyConfig(nil)
	close(resolver.release)
	result := <-done
	if result.err != nil {
		t.Fatalf("build trusted SSH config: %v", result.err)
	}
	result.config.revalidate = exec.ensureActiveProxmoxAssignment

	bridge := newPluginProxmoxConsoleBridge(nil)
	if _, err := bridge.Open(t.Context(), pluginProxmoxConsoleOpenRequest{}); err != nil {
		t.Fatalf("open bridge: %v", err)
	}
	dialCalled := false
	err := runProxmoxConsoleSSH(
		t.Context(),
		result.config,
		bridge,
		func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
			dialCalled = true
			return nil, errUnexpectedProxmoxSSHDial
		},
	)
	if !errors.Is(err, errPluginHostAuthorityDenied) {
		t.Fatalf("revoked SSH dial returned %v, want host-authority denial", err)
	}
	if dialCalled {
		t.Fatal("revoked SSH assignment reached the dialer")
	}
}

func TestProxmoxSSHConfigUsesOnlyImmutableSessionAndBrokerMaterial(t *testing.T) {
	t.Parallel()

	options := testConsoleAuthorityOptions()
	options.paramsJSON = `{
		"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
		"policy_version":1,
		"credential_rule_id":"proxmox-rule-1",
		"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__",
		"timeout_ms":15000
	}`
	options.sshHostKeyPolicy = proxmoxSSHHostKeyPolicyTrustFirstUse
	options.methods = nil
	options.paths = nil
	options.ports = []int{22}
	assignment := newTestProxmoxHostAuthorityAssignment(t, options)
	resolver := &fakeCredentialBrokerResolver{material: CredentialBrokerMaterial{Fields: map[string]string{
		"username": "root",
		"password": "host-resolved-password",
	}}}
	manager := NewPluginManager(t.Context(), PluginManagerConfig{CredentialBroker: resolver})
	t.Cleanup(manager.Stop)
	exec := newPluginExecution(manager, assignment)
	exec.mode = pluginExecutionModeStreaming
	exec.consoleSessionSpec = testProxmoxPVEConsoleSessionSpec()

	cfg, err := exec.trustedProxmoxConsoleSSHConfig(t.Context(), exec.consoleSessionSpec.SessionID)
	if err != nil {
		t.Fatalf("trustedProxmoxConsoleSSHConfig returned error: %v", err)
	}
	if cfg.Target.Hostname != "192.0.2.10" || cfg.Target.SSHPort != 22 {
		t.Fatalf("SSH destination = %s:%d, want immutable controller origin on port 22", cfg.Target.Hostname, cfg.Target.SSHPort)
	}
	if cfg.SSH.Username != "root" || cfg.SSH.Password != "host-resolved-password" {
		t.Fatalf("SSH material was not rebuilt from broker: %#v", cfg.SSH)
	}
	if cfg.SSHHostKeyPolicy != proxmoxSSHHostKeyPolicyTrustFirstUse || cfg.TimeoutMS != 15000 {
		t.Fatalf("trusted SSH settings = policy %q timeout %d", cfg.SSHHostKeyPolicy, cfg.TimeoutMS)
	}
	if _, err := validateProxmoxPublicParams([]byte(`{
		"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
		"policy_version":1,
		"credential_rule_id":"proxmox-rule-1",
		"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__",
		"ssh_host_key_policy":"skip_verify"
	}`), "proxmox-console-test", proxmoxConsolePluginID, proxmoxConsoleEntrypoint); !errors.Is(err, errPluginHostAuthorityMalformed) {
		t.Fatalf("SSH host-key bypass returned %v, want malformed authority denial", err)
	}
	if _, err := exec.trustedProxmoxConsoleSSHConfig(t.Context(), "different-session"); !errors.Is(err, errPluginHostAuthorityDenied) {
		t.Fatalf("different session id returned %v, want host-authority denial", err)
	}

	var request proxmoxConsoleSSHHostRequest
	if err := decodeStrictJSON(
		[]byte(`{"session_id":"console-session-1","target":{"hostname":"attacker.example"}}`),
		&request,
	); err == nil {
		t.Fatal("minimal SSH Wasm ABI accepted a module-controlled target")
	}
}

func TestProxmoxSSHHostKeyPolicyIsClosedAndRequiredForSSHBindings(t *testing.T) {
	t.Parallel()

	for _, policy := range []string{
		proxmoxSSHHostKeyPolicyKnownHosts,
		proxmoxSSHHostKeyPolicyTrustFirstUse,
	} {
		options := testConsoleAuthorityOptions()
		options.paramsJSON = `{
			"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
			"policy_version":1,
			"credential_rule_id":"proxmox-rule-1",
			"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__"
		}`
		options.methods = nil
		options.paths = nil
		options.ports = []int{22}
		options.sshHostKeyPolicy = policy

		assignment := newTestProxmoxHostAuthorityAssignment(t, options)
		bindings, _ := assignment.pluginHostAuthoritySnapshot()
		if len(bindings) != 1 || bindings[0].sshHostKeyPolicy != policy {
			t.Fatalf("SSH host-key policy %q was not retained in trusted binding: %#v", policy, bindings)
		}
	}

	for _, policy := range []string{"", "skip_verify", "accept_any", "TRUST_ON_FIRST_USE"} {
		options := testConsoleAuthorityOptions()
		options.paramsJSON = `{
			"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
			"policy_version":1,
			"credential_rule_id":"proxmox-rule-1",
			"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__"
		}`
		options.methods = nil
		options.paths = nil
		options.ports = []int{22}
		options.sshHostKeyPolicy = policy

		assertProxmoxAssignmentFailedClosed(t, newTestProxmoxHostAuthorityAssignment(t, options))
	}
}

func testConsoleAuthorityOptions() testProxmoxHostAuthorityOptions {
	return testProxmoxHostAuthorityOptions{
		assignmentID:  "proxmox-console-test",
		pluginID:      proxmoxConsolePluginID,
		entrypoint:    proxmoxConsoleEntrypoint,
		policyVersion: 1,
		paramsJSON: `{
			"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
			"policy_version":1,
			"credential_rule_id":"proxmox-rule-1",
			"api_token":"__SERVICERADAR_HOST_CREDENTIAL__"
		}`,
		origin:    testProxmoxOrigin,
		targetIDs: testProxmoxControllerTargetIDs(),
		grantID:   "proxmox-console-grant-1",
		secretRef: "credential://proxmox-console-1",
		methods:   []string{http.MethodGet, http.MethodPost},
		paths: []string{
			"/api2/json/nodes/pve01/qemu/101/vncproxy",
			"/api2/json/nodes/pve01/qemu/101/vncwebsocket",
		},
		hosts: []string{"192.0.2.10"},
		ports: []int{8006},
	}
}

func testInventoryAuthorityOptions() testProxmoxHostAuthorityOptions {
	return testProxmoxHostAuthorityOptions{
		assignmentID:  "proxmox-inventory-test",
		pluginID:      proxmoxInventoryPluginID,
		entrypoint:    proxmoxInventoryEntrypoint,
		policyVersion: 1,
		paramsJSON: `{
			"policy_id":"network-credential-rule:proxmox-rule-1:inventory_enrichment",
			"policy_version":1,
			"credential_rule_id":"proxmox-rule-1",
			"api_token":"__SERVICERADAR_HOST_CREDENTIAL__",
			"targets":[{"base_url":"https://192.0.2.10:8006","api_token":"__SERVICERADAR_HOST_CREDENTIAL__"}]
		}`,
		origin: testProxmoxOrigin,
		targetIDs: map[string]string{
			"device_uid": testProxmoxControllerDeviceUID,
		},
		grantID:   "proxmox-inventory-grant-1",
		secretRef: "credential://proxmox-inventory-1",
		methods:   []string{http.MethodGet},
		paths:     []string{"/api2/json/version", "/api2/json/nodes"},
		hosts:     []string{"192.0.2.10"},
		ports:     []int{8006},
	}
}

func testProxmoxControllerTargetIDs() map[string]string {
	return map[string]string{
		"device_uid":            testProxmoxControllerDeviceUID,
		"integration_id":        testProxmoxIntegrationID,
		"provider_ref":          testProxmoxControllerRef,
		"node":                  "pve01",
		"cluster":               testProxmoxNativeClusterID,
		"controller_id":         testProxmoxControllerID,
		"provider_instance_ref": testProxmoxProviderInstanceRef,
		"native_cluster_id":     testProxmoxNativeClusterID,
		"object_kind":           "node",
		"native_object_id":      "pve01",
	}
}

func testProxmoxGuestTargetIDs() map[string]string {
	return map[string]string{
		"device_uid":              testProxmoxGuestDeviceUID,
		"integration_id":          testProxmoxIntegrationID,
		"provider_ref":            testProxmoxGuestRef,
		"node":                    "pve01",
		"cluster":                 testProxmoxNativeClusterID,
		"vmid":                    "101",
		"target_kind":             "qemu_guest",
		"controller_id":           testProxmoxControllerID,
		"provider_instance_ref":   testProxmoxProviderInstanceRef,
		"native_cluster_id":       testProxmoxNativeClusterID,
		"object_kind":             "qemu",
		"native_object_id":        "101",
		"controller_device_uid":   testProxmoxControllerDeviceUID,
		"controller_provider_ref": testProxmoxControllerRef,
	}
}

func testProxmoxGuestConsoleSessionSpec() proxmoxConsoleSessionSpec {
	return proxmoxConsoleSessionSpec{
		SessionID:        "console-session-1",
		DeviceUID:        testProxmoxGuestDeviceUID,
		TargetKind:       "qemu_guest",
		ConsoleMode:      "proxmox_vncwebsocket",
		CredentialRuleID: testProxmoxCredentialRuleID,
		Target: proxmoxConsoleSSHTarget{
			DeviceUID:               testProxmoxGuestDeviceUID,
			BaseURL:                 testProxmoxOrigin,
			ProviderRef:             testProxmoxGuestRef,
			TargetRef:               testProxmoxGuestRef,
			TargetKind:              "qemu_guest",
			IntegrationID:           testProxmoxIntegrationID,
			Cluster:                 testProxmoxNativeClusterID,
			Node:                    "pve01",
			VMID:                    101,
			ControllerDeviceUID:     testProxmoxControllerDeviceUID,
			ControllerRef:           testProxmoxControllerRef,
			ControllerIntegrationID: testProxmoxIntegrationID,
			ControllerID:            testProxmoxControllerID,
			ProviderInstanceRef:     testProxmoxProviderInstanceRef,
			NativeClusterID:         testProxmoxNativeClusterID,
			ObjectKind:              "qemu",
			NativeObjectID:          "101",
		},
	}
}

func testProxmoxPVEConsoleSessionSpec() proxmoxConsoleSessionSpec {
	return proxmoxConsoleSessionSpec{
		SessionID:        "console-session-1",
		DeviceUID:        testProxmoxControllerDeviceUID,
		TargetKind:       "pve_host",
		ConsoleMode:      "ssh",
		CredentialRuleID: testProxmoxCredentialRuleID,
		Target: proxmoxConsoleSSHTarget{
			DeviceUID:               testProxmoxControllerDeviceUID,
			BaseURL:                 testProxmoxOrigin,
			ProviderRef:             testProxmoxControllerRef,
			TargetRef:               testProxmoxControllerRef,
			TargetKind:              "pve_host",
			IntegrationID:           testProxmoxIntegrationID,
			Cluster:                 testProxmoxNativeClusterID,
			Node:                    "pve01",
			ControllerDeviceUID:     testProxmoxControllerDeviceUID,
			ControllerRef:           testProxmoxControllerRef,
			ControllerIntegrationID: testProxmoxIntegrationID,
			ControllerID:            testProxmoxControllerID,
			ProviderInstanceRef:     testProxmoxProviderInstanceRef,
			NativeClusterID:         testProxmoxNativeClusterID,
			ObjectKind:              "node",
			NativeObjectID:          "pve01",
		},
	}
}

func bindTestProxmoxSessionPolicy(
	t *testing.T,
	spec *proxmoxConsoleSessionSpec,
	assignment *pluginAssignment,
) {
	t.Helper()
	policy, ok := assignment.proxmoxAssignmentPolicyBinding()
	if !ok {
		t.Fatal("test assignment has no Proxmox assignment policy binding")
	}
	spec.AssignmentPolicyVersion = policy.PolicyVersion
	spec.AssignmentPolicyFingerprint = policy.Fingerprint
}

func bindTestProxmoxExecutionGeneration(exec *pluginExecution, assignment *pluginAssignment) {
	exec.assignment = assignment
	exec.configJSON = assignment.ParamsJSON
	exec.mode = pluginExecutionModeStreaming
	exec.assignmentGenerationBound = true
	exec.manager.mu.Lock()
	exec.manager.streams[assignment.AssignmentID] = assignment
	exec.manager.mu.Unlock()
}

type blockingProxmoxCredentialResolver struct {
	material CredentialBrokerMaterial
	started  chan struct{}
	release  chan struct{}
}

func newBlockingProxmoxCredentialResolver(
	material CredentialBrokerMaterial,
) *blockingProxmoxCredentialResolver {
	return &blockingProxmoxCredentialResolver{
		material: material,
		started:  make(chan struct{}, 1),
		release:  make(chan struct{}),
	}
}

func (r *blockingProxmoxCredentialResolver) ResolveCredentialGrant(
	ctx context.Context,
	_ credentialBrokerGrant,
) (CredentialBrokerMaterial, error) {
	select {
	case r.started <- struct{}{}:
	default:
	}
	select {
	case <-ctx.Done():
		return CredentialBrokerMaterial{}, ctx.Err()
	case <-r.release:
		return r.material, nil
	}
}

func (r *blockingProxmoxCredentialResolver) waitStarted(t *testing.T) {
	t.Helper()
	select {
	case <-r.started:
	case <-time.After(time.Second):
		t.Fatal("credential resolution did not reach the revocation barrier")
	}
}

func newTestProxmoxHostAuthorityAssignment(
	t *testing.T,
	options testProxmoxHostAuthorityOptions,
) *pluginAssignment {
	t.Helper()
	hostJSON := testProxmoxHostAuthorityJSON(t, options)
	capabilities := []string{"get_config", "http_request"}
	if options.pluginID == proxmoxConsolePluginID {
		capabilities = append(capabilities, pluginCapabilityProxmoxConsole, "websocket_connect")
	}
	return newPluginAssignment(&proto.PluginAssignmentConfig{
		AssignmentId:   options.assignmentID,
		PluginId:       options.pluginID,
		Entrypoint:     options.entrypoint,
		Enabled:        true,
		Capabilities:   capabilities,
		ParamsJson:     []byte(options.paramsJSON),
		HostParamsJson: hostJSON,
		PermissionsJson: []byte(`{
			"allowed_domains":["*"],
			"allowed_ports":[8006]
		}`),
	}, logger.NewTestLogger())
}

func testProxmoxHostAuthorityJSON(t *testing.T, options testProxmoxHostAuthorityOptions) []byte {
	t.Helper()
	purpose := "inventory_enrichment"
	grantType := "proxmox_inventory"
	if options.pluginID == proxmoxConsolePluginID {
		purpose = "console_access"
		grantType = "proxmox_console"
	}
	policyVersion := options.policyVersion
	if policyVersion == 0 {
		policyVersion = 1
	}
	policyID := "network-credential-rule:" + testProxmoxCredentialRuleID + ":" + purpose
	policyFingerprint := proxmoxAssignmentPolicyFingerprint(
		options.assignmentID,
		options.pluginID,
		options.entrypoint,
		policyID,
		policyVersion,
		testProxmoxCredentialRuleID,
	)
	grantID := options.grantID
	if grantID == "" {
		grantID = "proxmox-test-grant"
	}
	secretRef := options.secretRef
	if secretRef == "" {
		secretRef = "credential://proxmox-test"
	}
	envelope := pluginHostAuthorityEnvelope{
		Schema: pluginHostAuthoritySchema,
		Bindings: []pluginHostAuthorityEnvelopeBinding{{
			BindingID:                   "proxmox-test-binding",
			Provider:                    "proxmox",
			CredentialRuleID:            testProxmoxCredentialRuleID,
			Origin:                      options.origin,
			InsecureSkipVerify:          options.insecureSkipVerify,
			AssignmentPolicyVersion:     policyVersion,
			AssignmentPolicyFingerprint: policyFingerprint,
			SSHHostKeyPolicy:            options.sshHostKeyPolicy,
			CABundlePEM:                 options.caBundlePEM,
			ServerCertFingerprint:       options.serverCertFingerprint,
			CredentialBroker: credentialBrokerGrant{
				Schema:              "serviceradar.edge_credential_broker_grant.v1",
				GrantID:             grantID,
				GrantType:           grantType,
				CredentialRuleID:    testProxmoxCredentialRuleID,
				CredentialSecretRef: secretRef,
				Consumer: map[string]string{
					"kind":    "plugin",
					"id":      options.pluginID,
					"purpose": purpose,
				},
				ResolutionLocation: "agent",
				Allow: credentialBrokerACL{
					Methods: append([]string(nil), options.methods...),
					Paths:   append([]string(nil), options.paths...),
					Hosts:   append([]string(nil), options.hosts...),
					Ports:   append([]int(nil), options.ports...),
				},
				TTLSeconds: options.ttlSeconds,
				ExpiresAt:  options.expiresAt,
			},
			TargetIDs: cloneHostAuthorityStringMap(options.targetIDs),
		}},
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal Proxmox host authority: %v", err)
	}
	return encoded
}

func assertProxmoxAssignmentFailedClosed(t *testing.T, assignment *pluginAssignment) {
	t.Helper()
	if got := string(assignment.ParamsJSON); got != "{}" {
		t.Fatalf("invalid assignment exposed params %s, want {}", got)
	}
	bindings, _ := assignment.pluginHostAuthoritySnapshot()
	if len(bindings) != 0 {
		t.Fatalf("invalid assignment retained %d host bindings", len(bindings))
	}
}
