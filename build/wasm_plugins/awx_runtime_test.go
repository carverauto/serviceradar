package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

// These fixtures are invented independently of any controller. Exercising the
// built Wasm is essential: native Go runs package initializers, whereas the
// agent calls run_check without WASI _start, which would close the module. An
// error sentinel built by a package initializer is therefore nil here, so a
// failed controller request must still surface as an error, not a nil response.
func TestAWXPreflightWithoutWASIStart(t *testing.T) {
	wasm := loadBuiltWasm(t, "awx.wasm")
	for _, tc := range []struct {
		name           string
		extraField     bool
		generation     string
		surveyVariable string
		unavailable    bool
		wantCalls      int
		wantStatus     string
		wantSummary    string
	}{
		{name: "canonical projection", generation: "1800000000000000001", surveyVariable: "release_version", wantCalls: 8, wantStatus: "OK"},
		{name: "unknown selector denied", extraField: true, generation: "1800000000000000001", surveyVariable: "release_version", wantCalls: 0, wantStatus: "CRITICAL"},
		{name: "generation overflow denied", generation: "9223372036854775808", surveyVariable: "release_version", wantCalls: 0, wantStatus: "CRITICAL"},
		{name: "secret survey denied", generation: "1800000000000000001", surveyVariable: "client_secret", wantCalls: 2, wantStatus: "CRITICAL"},
		{name: "reserved survey denied", generation: "1800000000000000001", surveyVariable: "hostvars", wantCalls: 2, wantStatus: "CRITICAL"},
		{name: "controller error fails closed", generation: "1800000000000000001", surveyVariable: "release_version", unavailable: true, wantCalls: 1, wantStatus: "CRITICAL", wantSummary: "awx.fetch_launch_preflight: AWX request failed: HTTP 503"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			config := awxRuntimeConfig(tc.generation)
			if tc.extraField {
				config["args"].(map[string]any)["extra_vars"] = map[string]any{}
			}
			responses := awxRuntimeResponses(tc.surveyVariable)
			if tc.unavailable {
				responses["/api/v2/job_templates/11/"] = awxStatus(http.StatusServiceUnavailable)
			}
			result, calls := runAWXWasm(t, wasm, config, responses)
			if result["status"] != tc.wantStatus || calls != tc.wantCalls {
				t.Fatalf("status=%v calls=%d; want %s/%d; summary=%v", result["status"], calls, tc.wantStatus, tc.wantCalls, result["summary"])
			}
			if tc.wantSummary != "" && result["summary"] != tc.wantSummary {
				t.Fatalf("summary=%v; want %s", result["summary"], tc.wantSummary)
			}
			if tc.wantStatus == "OK" {
				var details map[string]any
				if err := json.Unmarshal([]byte(result["details"].(string)), &details); err != nil {
					t.Fatal(err)
				}
				if details["ok"] != true {
					t.Fatalf("preflight not successful: %v", details)
				}
				fields := details["preflight"].(map[string]any)["survey"].(map[string]any)["spec"].([]any)
				choices, ok := fields[0].(map[string]any)["choices"].([]any)
				if !ok || len(choices) != 0 {
					t.Fatal("empty survey choices must normalize to an empty array")
				}
				hosts := details["preflight"].(map[string]any)["selected_hosts"].([]any)
				if hosts[0].(map[string]any)["membership_generation"] != tc.generation {
					t.Fatal("membership generation lost precision")
				}
				for key, value := range map[string]any{"request_digest": config["args"], "preflight_digest": details["preflight"]} {
					encoded, err := json.Marshal(value)
					if err != nil {
						t.Fatal(err)
					}
					expected := fmt.Sprintf("%x", sha256.Sum256(encoded))
					if details[key] != expected {
						t.Fatalf("noncanonical %s: got %s want %s", key, details[key], expected)
					}
				}
			}
		})
	}
}

// A failed inventory listing must say why it failed: a rejected controller
// token and an unreachable controller need different operator fixes. Only the
// failure class or status code crosses into the result, never upstream text.
func TestAWXInventorySyncReportsRequestFailureClass(t *testing.T) {
	wasm := loadBuiltWasm(t, "awx.wasm")
	config, err := json.Marshal(map[string]any{"controllers": []any{map[string]any{
		"controller_id": "11111111-1111-4111-8111-111111111111",
		"base_url":      "https://controller.example.com",
		"api_token":     "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__",
	}}})
	if err != nil {
		t.Fatal(err)
	}
	const prefix = "AWX inventory_sync failed listing inventories: AWX request failed: "
	for _, tc := range []struct {
		name   string
		status int
		want   string
	}{
		{name: "rejected token", status: http.StatusUnauthorized, want: "HTTP 401"},
		{name: "host policy denial", status: -2, want: "denied by agent egress or credential policy"},
		{name: "oversized response", status: -3, want: "response too large"},
		{name: "transport failure", status: -5, want: "transport error"},
		{name: "timeout", status: -6, want: "timeout"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host := &wasmHost{config: config, http: func(t *testing.T, request wasmHTTPRequest) (int, []byte) {
				if request.URL != "https://controller.example.com/api/v2/inventories/?page_size=200" {
					t.Fatalf("unexpected HTTP request: %+v", request)
				}
				return tc.status, []byte(`{"detail":"upstream text that must not be retained"}`)
			}}
			host.run(t, wasm, "inventory_sync")
			if len(host.results) != 1 || host.httpCalls != 1 {
				t.Fatalf("results=%d calls=%d; want 1/1", len(host.results), host.httpCalls)
			}
			result := host.results[0]
			if result["status"] != "CRITICAL" || result["summary"] != prefix+tc.want {
				t.Fatalf("status=%v summary=%v; want CRITICAL/%s", result["status"], result["summary"], prefix+tc.want)
			}
		})
	}
}

// awx.ping must prove the configured token still authenticates: a controller
// that answers the anonymous ping but rejects the token on /api/v2/me/ is
// auth_failed, while a controller-side 5xx stays an ordinary failure.
func TestAWXPingReportsAuthFailedWhenMeReturnsUnauthorized(t *testing.T) {
	wasm := loadBuiltWasm(t, "awx.wasm")
	config := map[string]any{
		"verb":      "awx.ping",
		"base_url":  "https://controller.example.com",
		"api_token": "synthetic-placeholder",
	}
	ping := map[string]any{"version": "23.5.1", "active_node": "awx-1"}
	for _, tc := range []struct {
		name        string
		pingBody    map[string]any
		pingStatus  awxStatus
		meResponse  any
		wantStatus  string
		wantCalls   int
		wantSummary string
		wantDetails map[string]any
	}{
		{
			name: "token accepted", meResponse: map[string]any{"count": 1, "results": []any{map[string]any{"id": 1}}},
			wantStatus: "OK", wantCalls: 2, wantSummary: "AWX 23.5.1 reachable (active: awx-1)",
			wantDetails: map[string]any{"verb": "awx.ping", "ok": true, "version": "23.5.1", "active_node": "awx-1"},
		},
		{
			name: "token rejected", meResponse: awxStatus(http.StatusUnauthorized),
			wantStatus: "CRITICAL", wantCalls: 2, wantSummary: "awx.ping: AWX request failed: HTTP 401",
			wantDetails: map[string]any{"verb": "awx.ping", "ok": false, "status": "auth_failed", "version": "23.5.1", "active_node": "awx-1", "error": "AWX request failed: HTTP 401"},
		},
		{
			name: "token forbidden", meResponse: awxStatus(http.StatusForbidden),
			wantStatus: "CRITICAL", wantCalls: 2, wantSummary: "awx.ping: AWX request failed: HTTP 403",
			wantDetails: map[string]any{"verb": "awx.ping", "ok": false, "status": "auth_failed", "version": "23.5.1", "active_node": "awx-1", "error": "AWX request failed: HTTP 403"},
		},
		{
			name: "controller error is not an auth failure", meResponse: awxStatus(http.StatusInternalServerError),
			wantStatus: "CRITICAL", wantCalls: 2, wantSummary: "awx.ping: AWX request failed: HTTP 500",
			wantDetails: map[string]any{"verb": "awx.ping", "ok": false, "error": "AWX request failed: HTTP 500"},
		},
		{
			name: "ping unavailable skips me", pingStatus: awxStatus(http.StatusServiceUnavailable),
			wantStatus: "CRITICAL", wantCalls: 1, wantSummary: "awx.ping: AWX request failed: HTTP 503",
			wantDetails: map[string]any{"verb": "awx.ping", "ok": false, "error": "AWX request failed: HTTP 503"},
		},
		{
			// Oracle: the timestamp is the one the controller put on the token
			// object. A plugin that drops it, rewrites it, or invents a 90-day
			// due date fails this comparison.
			name: "records token expiry from the authenticated user",
			meResponse: map[string]any{"count": 1, "results": []any{map[string]any{
				"id": 1, "username": "sr",
				"summary_fields": map[string]any{"token": map[string]any{"expires": "2026-11-01T12:00:00Z"}},
			}}},
			wantStatus: "OK", wantCalls: 2, wantSummary: "AWX 23.5.1 reachable (active: awx-1)",
			wantDetails: map[string]any{
				"verb": "awx.ping", "ok": true, "version": "23.5.1", "active_node": "awx-1",
				"token_expires_at": "2026-11-01T12:00:00Z",
			},
		},
		{
			// Oracle: 2592000 is the controller's configured access-token
			// lifetime in seconds (30 days), not a default chosen here.
			name:       "records configured access-token lifetime when no expiry is exposed",
			meResponse: map[string]any{"count": 1, "results": []any{map[string]any{"id": 1}}, "access_token_expire_seconds": 2592000},
			wantStatus: "OK", wantCalls: 2, wantSummary: "AWX 23.5.1 reachable (active: awx-1)",
			wantDetails: map[string]any{
				"verb": "awx.ping", "ok": true, "version": "23.5.1", "active_node": "awx-1",
				"access_token_expire_seconds": float64(2592000),
			},
		},
		{
			// Ping can expose an expiry and still be anonymous. A 401 from
			// /api/v2/me/ must stay auth_failed and must not keep that expiry.
			name:       "rejected token stays auth_failed even when ping carries an expiry",
			pingBody:   map[string]any{"version": "23.5.1", "active_node": "awx-1", "token_expires_at": "2026-11-01T12:00:00Z"},
			meResponse: awxStatus(http.StatusUnauthorized),
			wantStatus: "CRITICAL", wantCalls: 2, wantSummary: "awx.ping: AWX request failed: HTTP 401",
			wantDetails: map[string]any{
				"verb": "awx.ping", "ok": false, "status": "auth_failed",
				"version": "23.5.1", "active_node": "awx-1",
				"error": "AWX request failed: HTTP 401",
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pingBody := ping
			if tc.pingBody != nil {
				pingBody = tc.pingBody
			}
			responses := map[string]any{"/api/v2/ping/": pingBody}
			if tc.pingStatus != 0 {
				responses["/api/v2/ping/"] = tc.pingStatus
			} else {
				responses["/api/v2/me/"] = tc.meResponse
			}
			result, calls := runAWXWasm(t, wasm, config, responses)
			if result["status"] != tc.wantStatus || calls != tc.wantCalls || result["summary"] != tc.wantSummary {
				t.Fatalf("status=%v calls=%d summary=%v; want %s/%d/%s", result["status"], calls, result["summary"], tc.wantStatus, tc.wantCalls, tc.wantSummary)
			}
			var details map[string]any
			if err := json.Unmarshal([]byte(result["details"].(string)), &details); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(details, tc.wantDetails) {
				t.Fatalf("details=%v; want %v", details, tc.wantDetails)
			}
		})
	}
}

func awxRuntimeConfig(generation string) map[string]any {
	controller := "11111111-1111-4111-8111-111111111111"
	return map[string]any{"verb": "awx.fetch_launch_preflight", "base_url": "https://controller.example.com", "api_token": "synthetic-placeholder", "args": map[string]any{
		"schema": "serviceradar.awx_launch_preflight_request.v1", "controller_id": controller, "template_id": "11", "project_id": "12", "inventory_id": "13", "credential_ids": []string{"14"}, "execution_environment_id": "15",
		"selected_hosts": []any{map[string]any{"membership_id": "22222222-2222-4222-8222-222222222222", "controller_id": controller, "inventory_id": "13", "awx_host_id": "16", "canonical_device_uid": "sr:33333333-3333-4333-8333-333333333333", "host_name": "host01.example.com", "ansible_host": "192.0.2.10", "enabled": true, "membership_generation": generation, "source_fingerprint": "sha256:" + strings.Repeat("a", 64)}},
	}}
}

func awxRuntimeResponses(surveyVariable string) map[string]any {
	modified := "2030-01-02T03:04:05Z"
	template := map[string]any{"id": 11, "name": "Example template", "modified": modified, "project": 12, "inventory": 13, "playbook": "playbooks/example.yml", "job_type": "run", "scm_branch": "main", "timeout": 0, "forks": 0, "job_slice_count": 1, "allow_simultaneous": false, "diff_mode": false, "job_tags": "", "skip_tags": "", "survey_enabled": true, "execution_environment": 15, "summary_fields": map[string]any{"credentials": []any{map[string]any{"id": 14}}}}
	for _, field := range []string{"credential", "diff_mode", "execution_environment", "forks", "instance_groups", "inventory", "job_slice_count", "job_type", "labels", "limit", "scm_branch", "skip_tags", "tags", "timeout", "variables", "verbosity"} {
		template["ask_"+field+"_on_launch"] = field == "limit"
	}
	return map[string]any{
		"/api/v2/job_templates/11/":             template,
		"/api/v2/job_templates/11/survey_spec/": map[string]any{"name": "Example survey", "spec": []any{map[string]any{"variable": surveyVariable, "question_name": "Example input", "question_description": "", "type": "text", "required": true, "min": 1, "max": 20, "default": "", "choices": ""}}},
		"/api/v2/projects/12/":                  map[string]any{"id": 12, "name": "Example project", "modified": modified, "scm_type": "git", "scm_url": "https://git.example.com/ops/example.git", "scm_branch": "main", "scm_revision": strings.Repeat("c", 40), "scm_clean": true, "scm_update_on_launch": false, "status": "successful"},
		"/api/v2/inventories/13/":               map[string]any{"id": 13, "name": "Example inventory", "modified": modified, "kind": ""},
		"/api/v2/credentials/14/":               map[string]any{"id": 14, "name": "Example credential", "modified": modified, "credential_type": 1, "kind": "ssh", "summary_fields": map[string]any{"credential_type": map[string]any{"id": 1, "name": "Machine"}}},
		"/api/v2/execution_environments/15/":    map[string]any{"id": 15, "name": "Example environment", "image": "registry.example.com/automation@sha256:" + strings.Repeat("b", 64)},
		"/api/v2/hosts/16/":                     map[string]any{"id": 16, "inventory": 13, "name": "host01.example.com", "enabled": true, "variables": "ansible_host: 192.0.2.10\n"},
	}
}

// awxStatus answers a fixture path with a bare non-2xx status and no body.
type awxStatus int

func runAWXWasm(t *testing.T, wasm []byte, config map[string]any, responses map[string]any) (map[string]any, int) {
	t.Helper()
	configJSON, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	host := &wasmHost{config: configJSON, http: func(t *testing.T, request wasmHTTPRequest) (int, []byte) {
		path := strings.TrimPrefix(request.URL, "https://controller.example.com")
		body, exists := responses[path]
		if !exists || request.Method != http.MethodGet || request.ResponseMode != "status_body" {
			t.Fatalf("unexpected HTTP request: %+v", request)
		}
		if status, ok := body.(awxStatus); ok {
			return int(status), nil
		}
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		return http.StatusOK, encoded
	}}
	host.run(t, wasm, "run_check")
	if len(host.results) != 1 {
		t.Fatalf("expected one result, got %d", len(host.results))
	}
	return host.results[0], host.httpCalls
}
