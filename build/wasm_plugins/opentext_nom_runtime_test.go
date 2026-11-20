package main

import (
	"encoding/json"
	"net/http"
	"testing"
)

// The TinyGo build uses -scheduler=none, where timers do not exist: a retry
// backoff built on time.NewTimer traps the module the first time an upstream
// answers with a retryable status. Native `go test` cannot see this.
const opentextNOMRuntimeConfig = `{
	"instance_id": "network-automation-lab",
	"token_url": "https://nnm.example.com/idp/oauth2/token",
	"api_url": "https://na.example.com/nom/api/automation/v1/wrapper",
	"max_retries": 2
}`

func opentextNOMDeviceRows(t *testing.T) []byte {
	t.Helper()
	body, err := json.Marshal([]map[string]any{{
		"deviceID":         1,
		"hostName":         "lab-sw01",
		"primaryIPAddress": "192.0.2.10",
		"vendor":           "Example",
		"model":            "Example Switch",
		"deviceType":       "Switch",
		"managementStatus": "Managed",
		"excludeFromPoll":  false,
	}})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestOpenTextNOMRetriesRetryableUpstreamStatusUnderWasm(t *testing.T) {
	rows := opentextNOMDeviceRows(t)
	calls := 0
	host := &wasmHost{config: []byte(opentextNOMRuntimeConfig), httpEnvelope: func(t *testing.T, request wasmHTTPRequest) wasmHTTPEnvelopeResponse {
		t.Helper()
		calls++
		if calls == 1 {
			return wasmHTTPEnvelopeResponse{Status: http.StatusServiceUnavailable, Body: []byte(`{}`)}
		}
		return wasmHTTPEnvelopeResponse{Status: http.StatusOK, Body: rows}
	}}
	host.run(t, loadBuiltWasm(t, "opentext_nom_inventory.wasm"), "run_check")

	if calls < 2 {
		t.Fatalf("upstream calls = %d, want the 503 retried", calls)
	}
	final := host.results[len(host.results)-1]
	if final["status"] != "OK" {
		t.Fatalf("result status = %v, summary = %v", final["status"], final["summary"])
	}
}

func TestOpenTextNOMReportsUnavailableUpstreamUnderWasm(t *testing.T) {
	host := &wasmHost{config: []byte(opentextNOMRuntimeConfig), httpEnvelope: func(t *testing.T, request wasmHTTPRequest) wasmHTTPEnvelopeResponse {
		t.Helper()
		return wasmHTTPEnvelopeResponse{Status: http.StatusBadGateway, Body: []byte(`{}`)}
	}}
	host.run(t, loadBuiltWasm(t, "opentext_nom_inventory.wasm"), "run_check")

	if host.httpCalls != 3 {
		t.Fatalf("upstream calls = %d, want 1 attempt + 2 retries", host.httpCalls)
	}
	final := host.results[len(host.results)-1]
	if final["status"] != "CRITICAL" || final["summary"] != "opentext_nom_upstream_unavailable" {
		t.Fatalf("result status = %v, summary = %v", final["status"], final["summary"])
	}
}
