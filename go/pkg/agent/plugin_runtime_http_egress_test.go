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
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func TestPluginHostHTTPRequestEnforcesManifestEgressDestination(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		requestURL  string
		permissions pluginPermissions
		wantAllowed bool
	}{
		{
			name:       "https hostname with default port",
			requestURL: "https://api.example.test/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{443},
			},
			wantAllowed: true,
		},
		{
			name:       "http hostname with default port",
			requestURL: "http://api.example.test/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{80},
			},
			wantAllowed: true,
		},
		{
			name:       "hostname with explicitly allowed port",
			requestURL: "https://api.example.test:8443/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{8443},
			},
			wantAllowed: true,
		},
		{
			name:       "hostname with disallowed explicit port",
			requestURL: "https://api.example.test:444/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{443},
			},
		},
		{
			name:       "hostname without explicit port permission",
			requestURL: "https://api.example.test/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
			},
		},
		{
			name:       "unsupported scheme",
			requestURL: "ftp://api.example.test/resource",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{21},
			},
		},
		{
			name:       "ipv4 literal in allowed network",
			requestURL: "http://192.0.2.10/health",
			permissions: pluginPermissions{
				AllowedNetworks: []string{"192.0.2.0/24"},
				AllowedPorts:    []int{80},
			},
			wantAllowed: true,
		},
		{
			name:       "ipv4 literal explicitly listed as domain",
			requestURL: "http://192.0.2.10/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"192.0.2.10"},
				AllowedPorts:   []int{80},
			},
			wantAllowed: true,
		},
		{
			name:       "domain wildcard does not authorize ipv4 literal",
			requestURL: "http://192.0.2.10/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{80},
			},
		},
		{
			name:       "domain wildcard does not authorize trailing-dot ipv4 literal",
			requestURL: "http://192.0.2.10./health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{80},
			},
		},
		{
			name:       "ipv6 literal in allowed network",
			requestURL: "https://[2001:db8::10]/health",
			permissions: pluginPermissions{
				AllowedNetworks: []string{"2001:db8::/64"},
				AllowedPorts:    []int{443},
			},
			wantAllowed: true,
		},
		{
			name:       "ipv6 literal explicitly listed as domain",
			requestURL: "https://[2001:db8::10]/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"2001:db8::10"},
				AllowedPorts:   []int{443},
			},
			wantAllowed: true,
		},
		{
			name:       "domain wildcard does not authorize ipv6 literal",
			requestURL: "https://[2001:db8::10]/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{443},
			},
		},
		{
			name:       "domain wildcard alone denies an on-prem appliance literal",
			requestURL: "https://192.168.1.1/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{443},
			},
		},
		{
			name:       "shipped appliance networks authorize an rfc1918 literal",
			requestURL: "https://192.168.1.1/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedDomains:  []string{"*"},
				AllowedNetworks: onPremApplianceAllowedNetworks,
				AllowedPorts:    []int{443},
			},
			wantAllowed: true,
		},
		{
			name:       "shipped appliance networks authorize a carrier-grade nat literal",
			requestURL: "https://100.64.0.7/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedDomains:  []string{"*"},
				AllowedNetworks: onPremApplianceAllowedNetworks,
				AllowedPorts:    []int{443},
			},
			wantAllowed: true,
		},
		{
			name:       "shipped appliance networks still deny a link-local literal",
			requestURL: "https://169.254.0.1/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedDomains:  []string{"*"},
				AllowedNetworks: onPremApplianceAllowedNetworks,
				AllowedPorts:    []int{443},
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			transport := &countingPluginHTTPTransport{}
			exec, mod := newPluginHTTPHostTestExecution(t, tc.permissions, transport, nil)
			got := callPluginHostHTTPRequest(t, exec, mod, tc.requestURL)

			if tc.wantAllowed {
				if got <= 0 {
					t.Fatalf("hostHTTPRequest() = %d, want successful response", got)
				}
				if transport.calls != 1 {
					t.Fatalf("transport calls = %d, want 1", transport.calls)
				}
				return
			}

			if got != pluginErrDenied {
				t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
			}
			if transport.calls != 0 {
				t.Fatalf("transport calls = %d, want 0", transport.calls)
			}
		})
	}
}

func TestPluginHTTPEgressDeniedReasonNamesTheFailedGate(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		requestURL  string
		permissions pluginPermissions
		want        string
	}{
		{
			name:       "literal ip without allowed networks fails the host gate",
			requestURL: "https://192.168.1.1/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedDomains: []string{"*"},
				AllowedPorts:   []int{443},
			},
			want: pluginHTTPDeniedReasonEgressHost,
		},
		{
			name:       "permitted host on an unlisted port fails the port gate",
			requestURL: "https://192.168.1.1:8443/proxy/protect/api/bootstrap",
			permissions: pluginPermissions{
				AllowedNetworks: onPremApplianceAllowedNetworks,
				AllowedPorts:    []int{443},
			},
			want: pluginHTTPDeniedReasonEgressPort,
		},
		{
			name:       "unsupported scheme is not attributed to either gate",
			requestURL: "ftp://192.168.1.1/resource",
			permissions: pluginPermissions{
				AllowedNetworks: onPremApplianceAllowedNetworks,
				AllowedPorts:    []int{443},
			},
			want: pluginHTTPDeniedReasonEgress,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			reqURL, err := url.Parse(tc.requestURL)
			if err != nil {
				t.Fatalf("parse %s: %v", tc.requestURL, err)
			}
			tc.permissions.normalize()

			if got := pluginHTTPEgressDeniedReason(&tc.permissions, reqURL); got != tc.want {
				t.Fatalf("pluginHTTPEgressDeniedReason() = %q, want %q", got, tc.want)
			}
		})
	}

	if got := pluginHTTPEgressDeniedReason(nil, nil); got != pluginHTTPDeniedReasonEgress {
		t.Fatalf("pluginHTTPEgressDeniedReason(nil, nil) = %q, want %q", got, pluginHTTPDeniedReasonEgress)
	}
}

func TestPluginHostHTTPRequestChecksManifestBeforeCredentialResolution(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		requestURL  string
		permissions pluginPermissions
		grantPort   int
	}{
		{
			name:       "disallowed explicit port",
			requestURL: "https://api.example.test:444/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{443},
			},
			grantPort: 444,
		},
		{
			name:       "missing port allowlist",
			requestURL: "https://api.example.test/health",
			permissions: pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
			},
			grantPort: 443,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			resolver := &fakeCredentialBrokerResolver{
				material: CredentialBrokerMaterial{Value: resolvedToken},
			}
			transport := &countingPluginHTTPTransport{}
			exec, mod := newPluginHTTPHostTestExecution(t, tc.permissions, transport, resolver)
			exec.mode = pluginExecutionModeAction
			exec.credentialGrants = []credentialBrokerGrant{{
				Schema:              "serviceradar.edge_credential_broker_grant.v1",
				GrantID:             "grant-1",
				CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
				Allow: credentialBrokerACL{
					Methods: []string{http.MethodGet},
					Paths:   []string{"=/health"},
					Hosts:   []string{"api.example.test"},
					Ports:   []int{tc.grantPort},
				},
				Inject: map[string]string{"type": "bearer_token"},
			}}

			got := callPluginHostHTTPRequest(t, exec, mod, tc.requestURL)
			if got != pluginErrDenied {
				t.Fatalf("hostHTTPRequest() = %d, want %d", got, pluginErrDenied)
			}
			if resolver.calls != 0 {
				t.Fatalf("credential resolver calls = %d, want 0", resolver.calls)
			}
			if transport.calls != 0 {
				t.Fatalf("transport calls = %d, want 0", transport.calls)
			}
		})
	}
}

func TestPluginHostHTTPRequestRechecksManifestOnRedirect(t *testing.T) {
	t.Parallel()

	t.Run("denies redirect outside manifest", func(t *testing.T) {
		t.Parallel()

		transport := &countingPluginHTTPTransport{
			respond: func(req *http.Request) *http.Response {
				return pluginHTTPTestResponse(
					req,
					http.StatusFound,
					map[string]string{"Location": "http://192.0.2.10:8081/secret"},
					"redirect",
				)
			},
		}
		exec, mod := newPluginHTTPHostTestExecution(
			t,
			pluginPermissions{
				AllowedDomains: []string{"api.example.test"},
				AllowedPorts:   []int{443},
			},
			transport,
			nil,
		)

		got := callPluginHostHTTPRequest(t, exec, mod, "https://api.example.test/start")
		if got <= 0 {
			t.Fatalf("hostHTTPRequest() = %d, want original redirect response", got)
		}
		if transport.calls != 1 {
			t.Fatalf("transport calls = %d, want 1", transport.calls)
		}
	})

	t.Run("follows redirect inside manifest", func(t *testing.T) {
		t.Parallel()

		transport := &countingPluginHTTPTransport{
			respond: func(req *http.Request) *http.Response {
				if req.URL.Path == "/start" {
					return pluginHTTPTestResponse(
						req,
						http.StatusFound,
						map[string]string{"Location": "https://next.example.test/health"},
						"redirect",
					)
				}
				return pluginHTTPTestResponse(req, http.StatusOK, nil, `{"ok":true}`)
			},
		}
		exec, mod := newPluginHTTPHostTestExecution(
			t,
			pluginPermissions{
				AllowedDomains: []string{"api.example.test", "next.example.test"},
				AllowedPorts:   []int{443},
			},
			transport,
			nil,
		)

		got := callPluginHostHTTPRequest(t, exec, mod, "https://api.example.test/start")
		if got <= 0 {
			t.Fatalf("hostHTTPRequest() = %d, want successful redirected response", got)
		}
		if transport.calls != 2 {
			t.Fatalf("transport calls = %d, want 2", transport.calls)
		}
	})
}

type countingPluginHTTPTransport struct {
	calls   int
	respond func(*http.Request) *http.Response
}

func (t *countingPluginHTTPTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.calls++
	if t.respond != nil {
		return t.respond(req), nil
	}
	return pluginHTTPTestResponse(req, http.StatusOK, nil, `{"ok":true}`), nil
}

func pluginHTTPTestResponse(
	req *http.Request,
	status int,
	headers map[string]string,
	body string,
) *http.Response {
	header := make(http.Header, len(headers))
	for key, value := range headers {
		header.Set(key, value)
	}
	return &http.Response{
		StatusCode: status,
		Header:     header,
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    req,
	}
}

func newPluginHTTPHostTestExecution(
	t *testing.T,
	permissions pluginPermissions,
	transport http.RoundTripper,
	resolver CredentialBrokerResolver,
) (*pluginExecution, api.Module) {
	t.Helper()

	permissions.normalize()
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:           logger.NewTestLogger(),
		HTTPClient:       &http.Client{Transport: transport},
		CredentialBroker: resolver,
	})
	t.Cleanup(manager.Stop)

	assignment := &pluginAssignment{
		AssignmentID: "http-egress-test",
		PluginID:     "http-egress-test",
		Capabilities: map[string]bool{"http_request": true},
		Permissions:  permissions,
		Timeout:      time.Second,
	}

	runtime := wazero.NewRuntime(t.Context())
	t.Cleanup(func() {
		_ = runtime.Close(t.Context())
	})

	// Minimal Wasm module exporting one memory page. The host function reads
	// its request and writes its response through this real api.Module boundary.
	module, err := runtime.Instantiate(t.Context(), []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x05, 0x03, 0x01, 0x00, 0x01,
		0x07, 0x0a, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
	})
	if err != nil {
		t.Fatalf("instantiate test Wasm module: %v", err)
	}

	return newPluginExecution(manager, assignment), module
}

func callPluginHostHTTPRequest(
	t *testing.T,
	exec *pluginExecution,
	mod api.Module,
	requestURL string,
) int32 {
	t.Helper()

	payload, err := json.Marshal(httpRequestPayload{
		Method: http.MethodGet,
		URL:    requestURL,
	})
	if err != nil {
		t.Fatalf("marshal HTTP request payload: %v", err)
	}

	const (
		requestPtr  = uint32(0)
		responsePtr = uint32(32 * 1024)
		responseLen = uint32(16 * 1024)
	)
	if !mod.Memory().Write(requestPtr, payload) {
		t.Fatal("write HTTP request payload to Wasm memory")
	}

	return exec.hostHTTPRequest(
		t.Context(),
		mod,
		requestPtr,
		uint32(len(payload)),
		responsePtr,
		responseLen,
	)
}
