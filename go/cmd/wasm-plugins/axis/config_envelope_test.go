package main

import "testing"

func TestDecodeConfigFlatConfig(t *testing.T) {
	raw := []byte(`{
		"host": "10.0.0.5",
		"scheme": "http",
		"username": "root",
		"timeout_ms": 15000
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "10.0.0.5" {
		t.Fatalf("expected host 10.0.0.5, got %q", cfg.Host)
	}
	if cfg.Scheme != "http" {
		t.Fatalf("expected scheme http (explicit override), got %q", cfg.Scheme)
	}
	if cfg.Timeout != "15000ms" {
		t.Fatalf("expected timeout 15000ms, got %q", cfg.Timeout)
	}
	if !cfg.DiscoverStreams {
		t.Fatalf("expected discover_streams default true")
	}
	if cfg.RTSPPort != defaultAxisRTSPPort {
		t.Fatalf("expected default rtsp_port %d, got %d", defaultAxisRTSPPort, cfg.RTSPPort)
	}
}

func TestDecodeConfigDefaultSchemeHTTPS(t *testing.T) {
	cfg, err := decodeConfig([]byte(`{"host": "10.0.0.5"}`))
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Scheme != "https" {
		t.Fatalf("expected default scheme https, got %q", cfg.Scheme)
	}
	if cfg.Timeout != "10s" {
		t.Fatalf("expected fallback timeout 10s, got %q", cfg.Timeout)
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
			"username": "root",
			"password": "secret",
			"password_secret_ref": "network-credential:abc",
			"rtsp_port": 8554
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
					{"uid": "cam-1", "ip": "10.0.0.7", "hostname": "axis-1"}
				]
			}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "10.0.0.7" {
		t.Fatalf("expected host injected from item ip, got %q", cfg.Host)
	}
	if cfg.Scheme != "https" {
		t.Fatalf("expected scheme https from template, got %q", cfg.Scheme)
	}
	if cfg.Timeout != "30000ms" {
		t.Fatalf("expected timeout 30000ms from template timeout_ms, got %q", cfg.Timeout)
	}
	if cfg.Username != "root" || cfg.Password != "secret" {
		t.Fatalf("expected credentials applied from template, got user=%q pass=%q", cfg.Username, cfg.Password)
	}
	if cfg.PasswordSecretRef != "network-credential:abc" {
		t.Fatalf("expected password_secret_ref applied, got %q", cfg.PasswordSecretRef)
	}
	if cfg.RTSPPort != 8554 {
		t.Fatalf("expected rtsp_port 8554 from template, got %d", cfg.RTSPPort)
	}
	if !cfg.DiscoverStreams {
		t.Fatalf("expected discover_streams default preserved")
	}
	if cfg.EventSources != "events" {
		t.Fatalf("expected default event_sources 'events' preserved, got %q", cfg.EventSources)
	}
}

func TestDecodeConfigPluginInputsFallsBackToHostname(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"inputs": [
			{"entity": "devices", "items": [{"uid": "cam-2", "hostname": "axis.local"}]}
		]
	}`)

	cfg, err := decodeConfig(raw)
	if err != nil {
		t.Fatalf("decodeConfig error: %v", err)
	}
	if cfg.Host != "axis.local" {
		t.Fatalf("expected host from hostname, got %q", cfg.Host)
	}
}

func TestDecodeStreamConfigDerivesHostFromRelaySourceURL(t *testing.T) {
	raw := []byte(`{
		"scheme": "https",
		"relay": {"source_url": "rtsp://10.0.0.9:554/axis-media/media.amp"}
	}`)

	stream, err := decodeStreamConfig(raw)
	if err != nil {
		t.Fatalf("decodeStreamConfig error: %v", err)
	}
	if stream.Host != "10.0.0.9" {
		t.Fatalf("expected host derived from relay source_url, got %q", stream.Host)
	}
	if stream.Relay.SourceURL != "rtsp://10.0.0.9:554/axis-media/media.amp" {
		t.Fatalf("expected relay source_url preserved, got %q", stream.Relay.SourceURL)
	}
}

func TestDecodeStreamConfigEnvelopeHostBeatsRelay(t *testing.T) {
	raw := []byte(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"inputs": [
			{"entity": "devices", "items": [{"ip": "10.0.0.7"}]}
		],
		"relay": {"source_url": "rtsp://10.0.0.9:554/axis-media/media.amp"}
	}`)

	stream, err := decodeStreamConfig(raw)
	if err != nil {
		t.Fatalf("decodeStreamConfig error: %v", err)
	}
	if stream.Host != "10.0.0.7" {
		t.Fatalf("expected per-target envelope host to win, got %q", stream.Host)
	}
}

func TestAxisRTSPHost(t *testing.T) {
	cases := []struct {
		host string
		port int
		want string
	}{
		{"10.0.0.5", 0, "10.0.0.5"},
		{"10.0.0.5", defaultAxisRTSPPort, "10.0.0.5"},
		{"10.0.0.5", 8554, "10.0.0.5:8554"},
		{"", 8554, ""},
	}
	for _, tc := range cases {
		cfg := Config{RTSPPort: tc.port}
		cfg.Host = tc.host
		if got := axisRTSPHost(cfg); got != tc.want {
			t.Errorf("axisRTSPHost(host=%q port=%d) = %q, want %q", tc.host, tc.port, got, tc.want)
		}
	}
}

func TestBuildAxisStreamSourceURLAppendsNonStandardRTSPPort(t *testing.T) {
	cfg := StreamConfig{Config: Config{RTSPPort: 8554}}
	cfg.Host = "10.0.0.5"

	got := buildAxisStreamSourceURL(cfg)
	want := "rtsp://10.0.0.5:8554/axis-media/media.amp"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestHostFromRelaySourceURL(t *testing.T) {
	cases := map[string]string{
		"rtsp://10.0.0.9:554/axis-media/media.amp": "10.0.0.9",
		"rtsp://axis.local/axis-media/media.amp":   "axis.local",
		"":                                         "",
	}
	for input, want := range cases {
		if got := hostFromRelaySourceURL(input); got != want {
			t.Errorf("hostFromRelaySourceURL(%q) = %q, want %q", input, got, want)
		}
	}
}
