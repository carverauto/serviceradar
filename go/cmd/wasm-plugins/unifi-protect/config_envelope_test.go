package main

import "testing"

func TestDecodeConfigFlatConfig(t *testing.T) {
	raw := []byte(`{
		"host": "10.0.0.5",
		"scheme": "http",
		"username": "admin",
		"password": "secret",
		"timeout_ms": 15000,
		"rtsp_port": 7447
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "10.0.0.5" {
		t.Fatalf("expected host 10.0.0.5, got %q", cfg.Host)
	}
	if cfg.Scheme != "http" {
		t.Fatalf("expected scheme http, got %q", cfg.Scheme)
	}
	if cfg.Timeout != "15000ms" {
		t.Fatalf("expected timeout 15000ms, got %q", cfg.Timeout)
	}
	if !cfg.DiscoverStreams {
		t.Fatalf("expected discover_streams default true")
	}
}

func TestDecodeConfigPluginInputsInjectsHostFromItemIP(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"policy_id": "pol-1",
		"policy_version": 1,
		"agent_id": "agent-1",
		"generated_at": "2026-06-30T00:00:00Z",
		"template": {
			"scheme": "https",
			"timeout_ms": 30000,
			"username": "admin",
			"password": "secret",
			"insecure_skip_verify": true
		},
		"inputs": [
			{
				"name": "targets",
				"entity": "devices",
				"query": "show devices",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash": "hash",
				"items": [
					{"uid": "dev-1", "ip": "10.0.0.5", "hostname": "nvr-1"}
				]
			}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "10.0.0.5" {
		t.Fatalf("expected host injected from item ip, got %q", cfg.Host)
	}
	if cfg.Scheme != "https" {
		t.Fatalf("expected scheme https from template, got %q", cfg.Scheme)
	}
	if cfg.Timeout != "30000ms" {
		t.Fatalf("expected timeout 30000ms from template timeout_ms, got %q", cfg.Timeout)
	}
	if cfg.Username != "admin" || cfg.Password != "secret" {
		t.Fatalf("expected credentials applied from template, got user=%q pass=%q", cfg.Username, cfg.Password)
	}
	if !cfg.InsecureSkipVerify {
		t.Fatalf("expected insecure_skip_verify true from template")
	}
	// Defaults not present in the template must be preserved.
	if !cfg.DiscoverStreams {
		t.Fatalf("expected discover_streams default preserved")
	}
	if cfg.BootstrapPath != "/proxy/protect/api/bootstrap" {
		t.Fatalf("expected default bootstrap_path preserved, got %q", cfg.BootstrapPath)
	}
	if cfg.RTSPPort != 7447 {
		t.Fatalf("expected default rtsp_port 7447 preserved, got %d", cfg.RTSPPort)
	}
}

func TestDecodeConfigPluginInputsTemplateHostWinsOverItemHost(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"template": {
			"host": "protect-controller.local",
			"scheme": "https",
			"timeout_ms": 30000,
			"api_key": "secret"
		},
		"inputs": [
			{
				"entity": "devices",
				"items": [
					{"uid": "camera-1", "ip": "10.40.1.25", "hostname": "front-door"}
				]
			}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "protect-controller.local" {
		t.Fatalf("expected static controller host to win, got %q", cfg.Host)
	}
}

func TestDecodeConfigPluginInputsFallsBackToHostname(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"inputs": [
			{
				"entity": "devices",
				"items": [
					{"uid": "dev-2", "hostname": "protect.local"}
				]
			}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "protect.local" {
		t.Fatalf("expected host from hostname, got %q", cfg.Host)
	}
	// No template -> default scheme + fallback timeout applied.
	if cfg.Scheme != "https" {
		t.Fatalf("expected default scheme https, got %q", cfg.Scheme)
	}
	if cfg.Timeout != "10s" {
		t.Fatalf("expected fallback timeout 10s, got %q", cfg.Timeout)
	}
}

func TestDecodeConfigPluginInputsNoItemsLeavesHostEmpty(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"inputs": [
			{"entity": "devices", "items": [{"uid": "dev-3"}]}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "" {
		t.Fatalf("expected empty host when no item carries a host, got %q", cfg.Host)
	}
}

func TestDecodeStreamConfigDerivesHostFromRelaySourceURL(t *testing.T) {
	raw := []byte(`{
		"scheme": "https",
		"relay": {"source_url": "rtsp://10.0.0.9:7447/abcd"}
	}`)

	stream, err := decodeStreamConfig(raw)
	if err != nil {
		t.Fatalf("decodeStreamConfig error: %v", err)
	}
	if stream.Host != "10.0.0.9" {
		t.Fatalf("expected host derived from relay source_url, got %q", stream.Host)
	}
	if stream.Relay.SourceURL != "rtsp://10.0.0.9:7447/abcd" {
		t.Fatalf("expected relay source_url preserved, got %q", stream.Relay.SourceURL)
	}
}

func TestDecodeStreamConfigEnvelopeHostBeatsRelay(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"inputs": [
			{"entity": "devices", "items": [{"ip": "10.0.0.5"}]}
		],
		"relay": {"source_url": "rtsp://10.0.0.9:7447/abcd"}
	}`)

	stream, err := decodeStreamConfig(raw)
	if err != nil {
		t.Fatalf("decodeStreamConfig error: %v", err)
	}
	if stream.Host != "10.0.0.5" {
		t.Fatalf("expected per-target envelope host to win, got %q", stream.Host)
	}
	if stream.Relay.SourceURL != "rtsp://10.0.0.9:7447/abcd" {
		t.Fatalf("expected relay preserved, got %q", stream.Relay.SourceURL)
	}
}

func TestDecodeStreamConfigInlineHostKept(t *testing.T) {
	raw := []byte(`{
		"host": "controller.example",
		"relay": {"source_url": "rtsp://10.0.0.9:7447/abcd"}
	}`)

	stream, err := decodeStreamConfig(raw)
	if err != nil {
		t.Fatalf("decodeStreamConfig error: %v", err)
	}
	if stream.Host != "controller.example" {
		t.Fatalf("expected inline host kept, got %q", stream.Host)
	}
}

func TestHostFromRelaySourceURL(t *testing.T) {
	cases := map[string]string{
		"rtsp://10.0.0.9:7447/abcd":     "10.0.0.9",
		"rtsps://protect.local:7441/xy": "protect.local",
		"rtsp://[2001:db8::1]:7447/z":   "2001:db8::1",
		"":                              "",
		"not a url with spaces":         "",
	}
	for input, want := range cases {
		if got := hostFromRelaySourceURL(input); got != want {
			t.Errorf("hostFromRelaySourceURL(%q) = %q, want %q", input, got, want)
		}
	}
}
