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

package armis

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const testDeviceQuery = "in:devices"

func TestAccessTokenUsesFormEncodedSecretKey(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != accessTokenPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, accessTokenPath)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/x-www-form-urlencoded" {
			t.Fatalf("content-type = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if got := string(body); got != "secret_key=secret-value" {
			t.Fatalf("body = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	token, err := apiClient.accessToken(context.Background(), map[string]string{
		"api_key":    "ignored-key",
		"api_secret": "secret-value",
	})
	if err != nil {
		t.Fatalf("accessToken returned error: %v", err)
	}
	if token != "token-123" {
		t.Fatalf("token = %q", token)
	}
}

func TestAccessTokenUsesSecretKeyCredential(t *testing.T) {
	const expectedToken = "token-1"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != accessTokenPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, accessTokenPath)
		}

		if got := r.Header.Get("Content-Type"); got != "application/x-www-form-urlencoded" {
			t.Fatalf("content-type = %q, want application/x-www-form-urlencoded", got)
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read token request: %v", err)
		}
		if got := strings.TrimSpace(string(body)); got != "secret_key=secret-1" {
			t.Fatalf("body = %q, want secret_key=secret-1", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"data":{"access_token":"` + expectedToken + `"}}`))
	}))
	defer server.Close()

	apiClient := newClient(models.SourceConfig{Endpoint: server.URL})
	token, err := apiClient.accessToken(context.Background(), map[string]string{
		"api_key":    " key-1 ",
		"api_secret": " secret-1 ",
	})
	if err != nil {
		t.Fatalf("accessToken returned error: %v", err)
	}
	if token != expectedToken {
		t.Fatalf("token = %q, want %s", token, expectedToken)
	}
}

func TestAccessTokenIncludesErrorBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "Invalid secret key", http.StatusBadRequest)
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	_, err := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "bad"})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "Invalid secret key") {
		t.Fatalf("error = %q", err)
	}
}

func TestSecretKeyPreference(t *testing.T) {
	got := secretKey(map[string]string{
		"secret_key": "  preferred ",
		"api_secret": "secondary",
		"api_key":    "last",
	})
	if got != "preferred" {
		t.Fatalf("secret key = %q", got)
	}
}

func TestSearchUsesRawAccessToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != searchPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, searchPath)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "token-123" {
			t.Fatalf("authorization = %q, want raw access token", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		if got := r.URL.Query().Get("aql"); got != testDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("from"); got != "10" {
			t.Fatalf("from = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "25" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	resp, err := apiClient.search(context.Background(), "token-123", testDeviceQuery, 10, 25)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestSearchAcceptsScalarDeviceNames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != searchPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, searchPath)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"data": {
				"count": 2,
				"next": 0,
				"prev": null,
				"total": 2,
				"results": [
					{"id": 101, "ipAddress": "192.0.2.10", "names": "scalar-name"},
					{"id": 102, "ipAddress": "192.0.2.11", "names": ["array-name"]}
				]
			},
			"success": true
		}`))
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	resp, err := apiClient.search(context.Background(), "token-123", testDeviceQuery, 0, 100)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if len(resp.Data.Results) != 2 {
		t.Fatalf("result count = %d, want 2", len(resp.Data.Results))
	}
	if got := resp.Data.Results[0].primaryName(); got != "scalar-name" {
		t.Fatalf("scalar primaryName = %q, want scalar-name", got)
	}
	if got := resp.Data.Results[1].primaryName(); got != "array-name" {
		t.Fatalf("array primaryName = %q, want array-name", got)
	}
}

func TestSearchOmitsFromOnFirstPage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := r.URL.Query()["from"]; ok {
			t.Fatalf("from query param should be omitted on first page, got %q", r.URL.RawQuery)
		}
		if got := r.URL.Query().Get("aql"); got != testDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "100" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	resp, err := apiClient.search(context.Background(), "token-123", testDeviceQuery, 0, 100)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestSearchErrorIncludesBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "bad aql", http.StatusBadRequest)
	}))
	defer server.Close()

	apiClient := &client{endpoint: server.URL}
	_, err := apiClient.search(context.Background(), "token-123", testDeviceQuery, 0, 100)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "bad aql") {
		t.Fatalf("error = %q", err)
	}
	if isUnauthorized(err) {
		// 400 is not unauthorized; isUnauthorized must only match 401.
		t.Fatal("isUnauthorized(400 error) = true, want false")
	}
}

func TestSearchTotalDecodesNumericAndMarkerValues(t *testing.T) {
	tests := []struct {
		name      string
		raw       string
		wantCount int
		wantExact bool
		wantText  string
	}{
		{name: "number", raw: `42`, wantCount: 42, wantExact: true, wantText: "42"},
		{name: "numeric string", raw: `"17"`, wantCount: 17, wantExact: true, wantText: "17"},
		{name: "marker string", raw: `"Many"`, wantText: "Many"},
		{name: "null", raw: `null`},
		{name: "non-integer number", raw: `1.5`, wantText: "1.5"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var total searchTotal
			if err := json.Unmarshal([]byte(tt.raw), &total); err != nil {
				t.Fatalf("Unmarshal(%s) returned error: %v", tt.raw, err)
			}

			count, exact := total.Exact()
			if count != tt.wantCount || exact != tt.wantExact {
				t.Fatalf("Exact() = (%d, %v), want (%d, %v)", count, exact, tt.wantCount, tt.wantExact)
			}
			if got := total.String(); got != tt.wantText {
				t.Fatalf("String() = %q, want %q", got, tt.wantText)
			}
		})
	}
}

func TestSearchTotalRejectsMalformedJSON(t *testing.T) {
	var total searchTotal
	if err := json.Unmarshal([]byte(`{"total":`), &total); err == nil {
		t.Fatal("Unmarshal of malformed JSON returned nil error")
	}
	if err := total.UnmarshalJSON([]byte(`[1]`)); err == nil {
		t.Fatal("UnmarshalJSON of an array returned nil error")
	}
}
