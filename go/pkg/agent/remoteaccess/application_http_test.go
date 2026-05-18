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

package remoteaccess

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestApplicationHTTPAdapterEnforcesRegisteredTargetPolicy(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "private-app.internal" {
			t.Fatalf("Host = %q, want private-app.internal", r.Host)
		}
		if r.URL.Path != "/allowed/report" {
			t.Fatalf("Path = %q, want /allowed/report", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "" {
			t.Fatal("authorization header should be stripped")
		}
		if r.Header.Get("X-Forwarded-For") != "" {
			t.Fatal("forwarded-for header should be stripped")
		}
		if r.Header.Get("X-Trace") != "trace-1" {
			t.Fatalf("X-Trace = %q, want trace-1", r.Header.Get("X-Trace"))
		}

		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	adapter := newTestApplicationAdapter(t, server, ApplicationSchemeHTTP, nil)

	result, err := adapter.Execute(context.Background(), ApplicationRequestPayload{
		RequestID: "req-1",
		SessionID: "session-1",
		Method:    "GET",
		Path:      "/allowed/report",
		Headers: map[string][]string{
			"Authorization":   {"secret"},
			"X-Forwarded-For": {"203.0.113.10"},
			"X-Trace":         {"trace-1"},
		},
	}, nil)
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	if result.Metadata.StatusCode != http.StatusOK {
		t.Fatalf("StatusCode = %d, want 200", result.Metadata.StatusCode)
	}
	if string(result.Data.Data) != "ok" {
		t.Fatalf("body = %q, want ok", string(result.Data.Data))
	}
	if result.Outcome.TargetID != "app-target-1" || result.Outcome.ResponseBytes != 2 {
		t.Fatalf("Outcome = %#v", result.Outcome)
	}
}

func TestApplicationHTTPAdapterRejectsMethodPathAndQuotaViolations(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("upstream should not be called for policy violations")
	}))
	defer server.Close()

	adapter := newTestApplicationAdapter(t, server, ApplicationSchemeHTTP, map[string]any{
		"max_request_bytes": 4,
	})

	tests := []struct {
		name    string
		request ApplicationRequestPayload
		body    []byte
		want    error
	}{
		{
			name: "method",
			request: ApplicationRequestPayload{
				RequestID: "req-1",
				SessionID: "session-1",
				Method:    "POST",
				Path:      "/allowed",
			},
			want: ErrApplicationMethodNotAllowed,
		},
		{
			name: "path",
			request: ApplicationRequestPayload{
				RequestID: "req-1",
				SessionID: "session-1",
				Method:    "GET",
				Path:      "/denied",
			},
			want: ErrApplicationPathNotAllowed,
		},
		{
			name: "request quota",
			request: ApplicationRequestPayload{
				RequestID: "req-1",
				SessionID: "session-1",
				Method:    "GET",
				Path:      "/allowed",
			},
			body: []byte("too-large"),
			want: ErrApplicationRequestTooLarge,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			_, err := adapter.Execute(context.Background(), tt.request, tt.body)
			if !errors.Is(err, tt.want) {
				t.Fatalf("Execute error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestApplicationHTTPAdapterUsesTLSVerificationAndQuota(t *testing.T) {
	t.Parallel()

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("response-too-large"))
	}))
	defer server.Close()

	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())

	adapter := newTestApplicationAdapter(t, server, ApplicationSchemeHTTPS, map[string]any{
		"max_response_bytes": 4,
	})
	adapter.client.Transport.(*http.Transport).TLSClientConfig.RootCAs = pool

	_, err := adapter.Execute(context.Background(), ApplicationRequestPayload{
		RequestID: "req-1",
		SessionID: "session-1",
		Method:    "GET",
		Path:      "/allowed",
	}, nil)
	if !errors.Is(err, ErrApplicationResponseTooLarge) {
		t.Fatalf("Execute error = %v, want %v", err, ErrApplicationResponseTooLarge)
	}
}

func newTestApplicationAdapter(
	t *testing.T,
	server *httptest.Server,
	scheme ApplicationScheme,
	quota map[string]any,
) *ApplicationHTTPAdapter {
	t.Helper()

	hostPort := strings.TrimPrefix(server.URL, string(scheme)+"://")
	host, portText, found := strings.Cut(hostPort, ":")
	if !found {
		t.Fatalf("server URL missing port: %s", server.URL)
	}

	open := ApplicationOpenPayload{
		TargetID:            "app-target-1",
		SessionID:           "session-1",
		Scheme:              scheme,
		UpstreamHost:        host,
		UpstreamPort:        mustAtoi(t, portText),
		HostHeader:          "private-app.internal",
		AllowedMethods:      []string{"GET"},
		AllowedPathPrefixes: []string{"/allowed"},
		QuotaPolicy:         quota,
	}

	adapter, err := NewApplicationHTTPAdapter(open, ApplicationHTTPAdapterOptions{})
	if err != nil {
		t.Fatalf("NewApplicationHTTPAdapter returned error: %v", err)
	}

	return adapter
}

func mustAtoi(t *testing.T, value string) int {
	t.Helper()

	var result int
	if _, err := fmt.Sscanf(value, "%d", &result); err != nil {
		t.Fatalf("invalid port %q: %v", value, err)
	}

	return result
}
