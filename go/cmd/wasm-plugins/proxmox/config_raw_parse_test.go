package main

import (
	"reflect"
	"testing"
)

// rawPluginInputsPayload is a serviceradar.plugin_inputs.v1 payload as the
// agent exposes it to Wasm: only the fixed host credential sentinel appears in
// the template. Real credentials and broker grants stay in trusted host state.
const rawPluginInputsPayload = `{
	"schema": "serviceradar.plugin_inputs.v1",
	"policy_id": "policy-1",
	"policy_version": 1,
	"agent_id": "agent-1",
	"generated_at": "2026-05-06T19:00:00Z",
	"template": {
		"api_token": "__SERVICERADAR_HOST_CREDENTIAL__",
		"timeout_ms": 45000,
		"max_response_bytes": 262144,
		"max_guests": 250,
		"include_guests": false,
		"auto_discovery_enabled": true
	},
	"inputs": [{
		"name": "targets",
		"entity": "devices",
		"query": "in:devices metadata.proxmox_candidate:true",
		"chunk_index": 0,
		"chunk_total": 1,
		"chunk_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"items": [
			{"uid": "sr:device:1", "ip": "10.10.0.11", "hostname": "pve-a", "partition": "dc-a"},
			{"uid": "sr:device:2", "proxmox_base_url": "https://pve-b.example:8006/", "hostname": "pve-b"}
		]
	}, {
		"name": "services",
		"entity": "services",
		"query": "in:services type:proxmox",
		"chunk_index": 0,
		"chunk_total": 1,
		"chunk_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"items": [
			{"uid": "sr:service:1", "ip": "10.10.0.99", "hostname": "ignored"}
		]
	}]
}`

// TestConfigFromRawConfigGJSONAppliesPluginInputsTemplate is the #4386
// regression test: the TinyGo raw parser must apply the plugin_inputs
// `template` object. The pre-fix parser only read top-level keys, so the
// host-sentinel template.api_token (and timeout/guest settings) were dropped
// and every scheduled run failed with errMissingToken.
func TestConfigFromRawConfigGJSONAppliesPluginInputsTemplate(t *testing.T) {
	cfg := configFromRawConfigGJSON(rawPluginInputsPayload)

	if cfg.APIToken != hostCredentialSentinel {
		t.Fatalf("expected template api_token to be applied, got %q", cfg.APIToken)
	}
	if cfg.TimeoutMS != 45000 {
		t.Fatalf("expected template timeout_ms=45000, got %d", cfg.TimeoutMS)
	}
	if cfg.MaxResponseBytes != 262144 {
		t.Fatalf("expected template max_response_bytes=262144, got %d", cfg.MaxResponseBytes)
	}
	if cfg.MaxGuests != 250 {
		t.Fatalf("expected template max_guests=250, got %d", cfg.MaxGuests)
	}
	if cfg.IncludeGuests == nil || *cfg.IncludeGuests {
		t.Fatalf("expected template include_guests=false to be applied, got %v", cfg.IncludeGuests)
	}
	if !cfg.AutoDiscovery {
		t.Fatal("expected template auto_discovery_enabled=true to be applied")
	}
	if cfg.BaseURL != "" {
		t.Fatalf("expected base_url cleared once targets are generated, got %q", cfg.BaseURL)
	}

	if len(cfg.Targets) != 2 {
		t.Fatalf("expected two generated targets (services input filtered out), got %d: %#v", len(cfg.Targets), cfg.Targets)
	}
	for i, target := range cfg.Targets {
		if target.APIToken != hostCredentialSentinel {
			t.Fatalf("expected target %d to inherit template api_token, got %q", i, target.APIToken)
		}
	}
	if cfg.Targets[0].BaseURL != "https://10.10.0.11:8006" {
		t.Fatalf("unexpected first target URL: %s", cfg.Targets[0].BaseURL)
	}
	if cfg.Targets[0].DeviceID != "sr:device:1" || cfg.Targets[0].Partition != "dc-a" {
		t.Fatalf("unexpected first target metadata: %#v", cfg.Targets[0])
	}
	if cfg.Targets[1].BaseURL != "https://pve-b.example:8006" {
		t.Fatalf("unexpected second target URL: %s", cfg.Targets[1].BaseURL)
	}
}

// TestConfigFromRawConfigGJSONMatchesStdParser feeds identical payloads through
// the gjson parser (used by the TinyGo build) and the encoding/json parser
// (used by the std build, where configFromRawConfig resolves to
// config_raw_std.go) and requires bit-identical configs.
func TestConfigFromRawConfigGJSONMatchesStdParser(t *testing.T) {
	cases := map[string]string{
		"plugin inputs with template": rawPluginInputsPayload,
		"plugin inputs without template": `{
			"schema": "serviceradar.plugin_inputs.v1",
			"policy_id": "policy-1",
			"policy_version": 2,
			"agent_id": "agent-1",
			"generated_at": "2026-05-06T19:00:00Z",
			"inputs": [{
				"name": "targets",
				"entity": "devices",
				"query": "in:devices metadata.proxmox_candidate:true",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
				"items": [{"uid": "sr:device:1", "ip": "10.10.0.11", "hostname": "pve-a"}]
			}]
		}`,
		"plugin inputs invalid missing policy_id": `{
			"schema": "serviceradar.plugin_inputs.v1",
			"policy_version": 1,
			"agent_id": "agent-1",
			"generated_at": "2026-05-06T19:00:00Z",
			"template": {"api_token": "__SERVICERADAR_HOST_CREDENTIAL__"},
			"inputs": [{
				"name": "targets",
				"entity": "devices",
				"query": "in:devices metadata.proxmox_candidate:true",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
				"items": [{"uid": "sr:device:1", "ip": "10.10.0.11"}]
			}]
		}`,
		"plugin inputs non-devices entities keep template base_url": `{
			"schema": "serviceradar.plugin_inputs.v1",
			"policy_id": "policy-1",
			"policy_version": 1,
			"agent_id": "agent-1",
			"generated_at": "2026-05-06T19:00:00Z",
			"template": {
				"base_url": "https://pve.example:8006",
				"api_token": "__SERVICERADAR_HOST_CREDENTIAL__"
			},
			"inputs": [{
				"name": "services",
				"entity": "services",
				"query": "in:services type:proxmox",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
				"items": [{"uid": "sr:service:1", "ip": "10.10.0.99"}]
			}]
		}`,
		"plugin inputs item without host falls back to template base_url": `{
			"schema": "serviceradar.plugin_inputs.v1",
			"policy_id": "policy-1",
			"policy_version": 1,
			"agent_id": "agent-1",
			"generated_at": "2026-05-06T19:00:00Z",
			"template": {
				"base_url": "https://pve.example:8006",
				"api_token": "__SERVICERADAR_HOST_CREDENTIAL__"
			},
			"inputs": [{
				"name": "targets",
				"entity": "devices",
				"query": "in:devices metadata.proxmox_candidate:true",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
				"items": [{"uid": "sr:device:1", "partition": "dc-a"}]
			}]
		}`,
		"plain config full": `{
			"base_url": "https://pve.example:8006",
			"api_token": "__SERVICERADAR_HOST_CREDENTIAL__",
			"timeout_ms": 1000,
			"max_response_bytes": 2048,
			"max_guests": 42,
			"include_guests": false,
			"auto_discovery_enabled": true,
			"targets": [{
				"base_url": "https://pve2.example:8006",
				"api_token": "__SERVICERADAR_HOST_CREDENTIAL__",
				"device_id": "sr:device:9",
				"hostname": "pve2",
				"partition": "dc-b"
			}]
		}`,
		"legacy secret ref fails closed":   `{"api_token_secret_ref":"credential://legacy","api_token":"__SERVICERADAR_HOST_CREDENTIAL__"}`,
		"legacy raw token fails closed":    `{"api_token":"token-material"}`,
		"legacy TLS override fails closed": `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","insecure_skip_verify":true}`,
		"legacy SSH object fails closed":   `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","ssh":{"username":"root","password":"secret"}}`,
		"legacy SSH bypass fails closed":   `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","ssh_host_key_policy":"skip_verify"}`,
		"plain config minimal":             `{"api_token": "__SERVICERADAR_HOST_CREDENTIAL__"}`,
		"plain config empty targets list":  `{"base_url": "https://pve.example:8006", "targets": []}`,
		"empty object":                     `{}`,
		"invalid json":                     `{"api_token": `,
	}

	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			got := configFromRawConfigGJSON(raw)
			want := configFromRawConfig(raw)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("gjson parser diverged from std parser\n got: %#v\nwant: %#v", got, want)
			}
		})
	}
}

func TestRawConfigParsersFailClosedOnLegacyAuthorityFields(t *testing.T) {
	want := defaultConfig()
	tests := map[string]string{
		"secret reference": `{"api_token_secret_ref":"credential://legacy","api_token":"__SERVICERADAR_HOST_CREDENTIAL__"}`,
		"raw token":        `{"api_token":"token-material"}`,
		"TLS bypass":       `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","insecure_skip_verify":true}`,
		"SSH credentials":  `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","ssh":{"username":"root","private_key":"secret"}}`,
		"SSH bypass":       `{"api_token":"__SERVICERADAR_HOST_CREDENTIAL__","ssh_host_key_policy":"skip_verify"}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			if got := configFromRawConfig(raw); !reflect.DeepEqual(got, want) {
				t.Fatalf("std parser returned %#v, want fail-closed default %#v", got, want)
			}
			if got := configFromRawConfigGJSON(raw); !reflect.DeepEqual(got, want) {
				t.Fatalf("gjson parser returned %#v, want fail-closed default %#v", got, want)
			}
		})
	}
}
