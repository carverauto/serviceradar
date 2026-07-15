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
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/tetratelabs/wazero/api"
)

func TestPluginHostHTTPRequestUsesAuthorizedAWXLaunchBytesExactlyOnce(t *testing.T) {
	t.Parallel()

	authorizedBody := []byte(`{"extra_vars":{"sr_target_host":"192.0.2.10"},"limit":"192.0.2.10","inventory":17,"credentials":[41]}`)
	maliciousPluginBody := `{"limit":"all","inventory":999,"credentials":[999],"extra_vars":{"admin_password":"steal-me"}}`

	var (
		gotBody        []byte
		gotContentType string
		gotAuth        string
		gotLength      string
		gotTransfer    string
	)
	transport := &countingPluginHTTPTransport{
		respond: func(req *http.Request) *http.Response {
			body, err := io.ReadAll(req.Body)
			if err != nil {
				t.Fatalf("read request body: %v", err)
			}
			gotBody = append([]byte(nil), body...)
			gotContentType = req.Header.Get("Content-Type")
			gotAuth = req.Header.Get("Authorization")
			gotLength = req.Header.Get("Content-Length")
			gotTransfer = req.Header.Get("Transfer-Encoding")

			return pluginHTTPTestResponse(req, http.StatusCreated, nil, `{"id":7}`)
		},
	}
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	exec, mod := newPluginHTTPHostTestExecution(
		t,
		pluginPermissions{
			AllowedDomains: []string{"awx.example.test"},
			AllowedPorts:   []int{443},
		},
		transport,
		resolver,
	)
	exec.mode = pluginExecutionModeAction
	exec.credentialGrants = []credentialBrokerGrant{newBoundAWXTestGrant(authorizedBody)}
	exec.authorizedRequestBody = append([]byte(nil), authorizedBody...)
	firstAuthorizedBuffer := exec.authorizedRequestBody

	got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
		Method: http.MethodPost,
		URL:    "https://awx.example.test/api/v2/job_templates/42/launch/",
		Headers: map[string]string{
			"Content-Type":      "text/plain",
			"Content-Length":    "999",
			"Transfer-Encoding": "chunked",
		},
		Body: maliciousPluginBody,
	})
	if got <= 0 {
		t.Fatalf("hostHTTPRequest() = %d, want successful response", got)
	}
	if !bytes.Equal(gotBody, authorizedBody) {
		t.Fatalf("transport body = %s, want exact authorized bytes %s", gotBody, authorizedBody)
	}
	if bytes.Equal(gotBody, []byte(maliciousPluginBody)) {
		t.Fatal("transport received plugin-controlled launch body")
	}
	if gotContentType != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", gotContentType)
	}
	if gotAuth != "Bearer "+resolvedToken {
		t.Fatalf("Authorization = %q, want brokered bearer token", gotAuth)
	}
	if gotLength != "" || gotTransfer != "" {
		t.Fatalf("framing headers survived policy: Content-Length=%q Transfer-Encoding=%q", gotLength, gotTransfer)
	}
	if resolver.calls != 1 || transport.calls != 1 {
		t.Fatalf("resolver/transport calls = %d/%d, want 1/1", resolver.calls, transport.calls)
	}
	assertAllZero(t, firstAuthorizedBuffer, "authorized launch body after request")

	// Replenishing the exact trusted bytes must not turn a one-use grant into a
	// replayable mutation grant. The reservation gate runs before resolution.
	exec.authorizedRequestBody = append([]byte(nil), authorizedBody...)
	secondAuthorizedBuffer := exec.authorizedRequestBody
	got = callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
		Method: http.MethodPost,
		URL:    "https://awx.example.test/api/v2/job_templates/42/launch/",
		Body:   maliciousPluginBody,
	})
	if got != pluginErrDenied {
		t.Fatalf("second hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
	}
	if resolver.calls != 1 || transport.calls != 1 {
		t.Fatalf("replay reached resolver/transport: calls = %d/%d, want 1/1", resolver.calls, transport.calls)
	}
	assertAllZero(t, secondAuthorizedBuffer, "replayed authorized launch body")
}

func TestPluginHostHTTPRequestDeniesAWXSchemeDowngradeBeforeCredentialResolution(t *testing.T) {
	t.Parallel()

	authorizedBody := []byte(`{"limit":"linux-01","inventory":17,"credentials":[41]}`)
	transport := &countingPluginHTTPTransport{}
	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	exec, mod := newPluginHTTPHostTestExecution(
		t,
		pluginPermissions{
			AllowedDomains: []string{"awx.example.test"},
			AllowedPorts:   []int{443},
		},
		transport,
		resolver,
	)
	exec.mode = pluginExecutionModeAction
	exec.credentialGrants = []credentialBrokerGrant{newBoundAWXTestGrant(authorizedBody)}
	exec.authorizedRequestBody = append([]byte(nil), authorizedBody...)

	got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
		Method: http.MethodPost,
		URL:    "http://awx.example.test:443/api/v2/job_templates/42/launch/",
		Body:   `{}`,
	})
	if got >= 0 {
		t.Fatalf("hostHTTPRequest() = %d, want denied HTTP downgrade", got)
	}
	if resolver.calls != 0 || transport.calls != 0 {
		t.Fatalf("resolver/transport calls = %d/%d, want 0/0", resolver.calls, transport.calls)
	}
}

func TestPluginHostHTTPRequestRejectsInvalidAuthorizedAWXLaunchBodyBeforeResolution(t *testing.T) {
	t.Parallel()

	authorizedBody := []byte(`{"limit":"192.0.2.10"}`)
	tests := []struct {
		name        string
		trustedBody []byte
	}{
		{name: "missing trusted bytes"},
		{name: "digest mismatch", trustedBody: []byte(`{"limit":"all"}`)},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			resolver := &fakeCredentialBrokerResolver{
				material: CredentialBrokerMaterial{Value: resolvedToken},
			}
			transport := &countingPluginHTTPTransport{}
			exec, mod := newPluginHTTPHostTestExecution(
				t,
				pluginPermissions{
					AllowedDomains: []string{"awx.example.test"},
					AllowedPorts:   []int{443},
				},
				transport,
				resolver,
			)
			exec.mode = pluginExecutionModeAction
			exec.credentialGrants = []credentialBrokerGrant{newBoundAWXTestGrant(authorizedBody)}
			exec.authorizedRequestBody = append([]byte(nil), tc.trustedBody...)

			got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
				Method: http.MethodPost,
				URL:    "https://awx.example.test/api/v2/job_templates/42/launch/",
				Body:   `{"limit":"all"}`,
			})
			if got != pluginErrDenied {
				t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
			}
			if resolver.calls != 0 || transport.calls != 0 {
				t.Fatalf("invalid body reached resolver/transport: calls = %d/%d, want 0/0", resolver.calls, transport.calls)
			}
		})
	}
}

func TestPluginHostHTTPRequestRejectsLegacyAWXMutationBeforeResolution(t *testing.T) {
	t.Parallel()

	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	transport := &countingPluginHTTPTransport{}
	exec, mod := newPluginHTTPHostTestExecution(
		t,
		pluginPermissions{
			AllowedDomains: []string{"awx.example.test"},
			AllowedPorts:   []int{443},
		},
		transport,
		resolver,
	)
	exec.mode = pluginExecutionModeAction
	exec.credentialGrants = []credentialBrokerGrant{{
		Schema:              coreaddon.CredentialBrokerGrantSchemaV1,
		GrantID:             "legacy-grant",
		GrantType:           "awx_oauth2_token",
		CredentialSecretRef: "credentialref:network-credential-secret:awx-1",
		Allow: credentialBrokerACL{
			Methods: []string{http.MethodPost},
			Paths:   []string{"=/api/v2/job_templates/42/launch/"},
			Hosts:   []string{"awx.example.test"},
			Ports:   []int{443},
		},
		Inject:    map[string]string{"type": "bearer_token"},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}}

	got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
		Method: http.MethodPost,
		URL:    "https://awx.example.test/api/v2/job_templates/42/launch/",
		Body:   `{"limit":"all"}`,
	})
	if got != pluginErrDenied {
		t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
	}
	if resolver.calls != 0 || transport.calls != 0 {
		t.Fatalf("legacy mutation reached resolver/transport: calls = %d/%d, want 0/0", resolver.calls, transport.calls)
	}
}

func TestPluginHostHTTPRequestEmptyBodyPolicy(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		pluginBody  string
		wantAllowed bool
	}{
		{name: "accepts empty body", wantAllowed: true},
		{name: "rejects plugin body", pluginBody: `{}`, wantAllowed: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			resolver := &fakeCredentialBrokerResolver{
				material: CredentialBrokerMaterial{Value: resolvedToken},
			}
			transport := &countingPluginHTTPTransport{}
			exec, mod := newPluginHTTPHostTestExecution(
				t,
				pluginPermissions{
					AllowedDomains: []string{"awx.example.test"},
					AllowedPorts:   []int{443},
				},
				transport,
				resolver,
			)
			exec.mode = pluginExecutionModeAction
			exec.credentialGrants = []credentialBrokerGrant{newEmptyAWXTestGrant()}

			got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
				Method: http.MethodPost,
				URL:    "https://awx.example.test/api/v2/jobs/7/cancel/",
				Body:   tc.pluginBody,
			})
			if tc.wantAllowed {
				if got <= 0 {
					t.Fatalf("hostHTTPRequest() = %d, want successful response", got)
				}
				if resolver.calls != 1 || transport.calls != 1 {
					t.Fatalf("resolver/transport calls = %d/%d, want 1/1", resolver.calls, transport.calls)
				}
				return
			}

			if got != pluginErrDenied {
				t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
			}
			if resolver.calls != 0 || transport.calls != 0 {
				t.Fatalf("nonempty body reached resolver/transport: calls = %d/%d, want 0/0", resolver.calls, transport.calls)
			}
		})
	}
}

func TestPluginHostHTTPRequestRejectsBodyOnSafeAWXRequest(t *testing.T) {
	t.Parallel()

	resolver := &fakeCredentialBrokerResolver{
		material: CredentialBrokerMaterial{Value: resolvedToken},
	}
	transport := &countingPluginHTTPTransport{}
	exec, mod := newPluginHTTPHostTestExecution(
		t,
		pluginPermissions{
			AllowedDomains: []string{"awx.example.test"},
			AllowedPorts:   []int{443},
		},
		transport,
		resolver,
	)
	exec.mode = pluginExecutionModeAction
	exec.credentialGrants = []credentialBrokerGrant{{
		Schema:              coreaddon.CredentialBrokerGrantSchemaV1,
		GrantID:             "read-grant",
		GrantType:           "awx_oauth2_token",
		CredentialSecretRef: "credentialref:network-credential-secret:awx-1",
		Allow: credentialBrokerACL{
			Schemes: []string{"https"},
			Methods: []string{http.MethodGet},
			Paths:   []string{"=/api/v2/jobs/7/"},
			Hosts:   []string{"awx.example.test"},
			Ports:   []int{443},
		},
		Inject:    map[string]string{"type": "bearer_token"},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}}

	got := callPluginHostHTTPRequestWithBodyPolicy(t, exec, mod, httpRequestPayload{
		Method: http.MethodGet,
		URL:    "https://awx.example.test/api/v2/jobs/7/",
		Body:   `{"smuggled":true}`,
	})
	if got != pluginErrDenied {
		t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
	}
	if resolver.calls != 0 || transport.calls != 0 {
		t.Fatalf("safe request body reached resolver/transport: calls = %d/%d, want 0/0", resolver.calls, transport.calls)
	}
}

func newBoundAWXTestGrant(authorizedBody []byte) credentialBrokerGrant {
	digest := sha256.Sum256(authorizedBody)
	return credentialBrokerGrant{
		Schema:              coreaddon.CredentialBrokerGrantSchemaV2,
		GrantID:             "bound-awx-launch",
		GrantType:           "awx_oauth2_token",
		CredentialSecretRef: "credentialref:network-credential-secret:awx-1",
		Allow: credentialBrokerACL{
			Schemes: []string{"https"},
			Methods: []string{http.MethodPost},
			Paths:   []string{"=/api/v2/job_templates/42/launch/"},
			Hosts:   []string{"awx.example.test"},
			Ports:   []int{443},
			RequestBody: coreaddon.CredentialBrokerRequestBodyPolicy{
				Mode:         coreaddon.CredentialBrokerRequestBodyModeBoundBytes,
				SHA256:       hex.EncodeToString(digest[:]),
				Source:       coreaddon.CredentialBrokerBoundBodySource,
				ContentType:  "application/json",
				MaxBytes:     256 * 1024,
				MaxMutations: 1,
			},
		},
		Inject:    map[string]string{"type": "bearer_token"},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}
}

func newEmptyAWXTestGrant() credentialBrokerGrant {
	return credentialBrokerGrant{
		Schema:              coreaddon.CredentialBrokerGrantSchemaV2,
		GrantID:             "empty-awx-cancel",
		GrantType:           "awx_oauth2_token",
		CredentialSecretRef: "credentialref:network-credential-secret:awx-1",
		Allow: credentialBrokerACL{
			Schemes: []string{"https"},
			Methods: []string{http.MethodPost},
			Paths:   []string{"=/api/v2/jobs/7/cancel/"},
			Hosts:   []string{"awx.example.test"},
			Ports:   []int{443},
			RequestBody: coreaddon.CredentialBrokerRequestBodyPolicy{
				Mode:         coreaddon.CredentialBrokerRequestBodyModeEmpty,
				ContentType:  "application/json",
				MaxMutations: 1,
			},
		},
		Inject:    map[string]string{"type": "bearer_token"},
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339),
	}
}

func callPluginHostHTTPRequestWithBodyPolicy(
	t *testing.T,
	exec *pluginExecution,
	mod api.Module,
	payload httpRequestPayload,
) int32 {
	t.Helper()

	request, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal HTTP request payload: %v", err)
	}

	const (
		requestPtr  = uint32(0)
		responsePtr = uint32(32 * 1024)
		responseLen = uint32(16 * 1024)
	)
	if !mod.Memory().Write(requestPtr, request) {
		t.Fatal("write HTTP request payload to Wasm memory")
	}

	return exec.hostHTTPRequest(
		t.Context(),
		mod,
		requestPtr,
		uint32(len(request)),
		responsePtr,
		responseLen,
	)
}

func assertAllZero(t *testing.T, value []byte, label string) {
	t.Helper()
	for index, element := range value {
		if element != 0 {
			t.Fatalf("%s byte %d = %d, want zeroed buffer", label, index, element)
		}
	}
}
