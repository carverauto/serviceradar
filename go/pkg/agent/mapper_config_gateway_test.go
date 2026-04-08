package agent

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestParseGatewayMapperConfigPreservesMikroTikEndpoints(t *testing.T) {
	raw := []byte(`{
		"mapper": {
			"workers": 10,
			"mikrotik_apis": [
				{
					"name": "tonka01",
					"base_url": "http://192.168.6.167/rest",
					"username": "serviceradar",
					"password": "secret",
					"insecure_skip_verify": true
				}
			],
			"scheduled_jobs": [
				{
					"name": "tonka01",
					"type": "network",
					"enabled": true,
					"interval": "5m",
					"discovery_mode": "snmp_api",
					"options": {
						"mikrotik_api_names": "tonka01"
					}
				}
			]
		}
	}`)

	cfg, err := parseGatewayMapperConfig(raw)
	if err != nil {
		t.Fatalf("expected mapper config to parse, got error: %v", err)
	}

	if cfg == nil {
		t.Fatal("expected mapper config, got nil")
		return
	}

	if len(cfg.MikroTikAPIs) != 1 {
		t.Fatalf("expected one MikroTik endpoint, got %d", len(cfg.MikroTikAPIs))
	}

	if got := cfg.MikroTikAPIs[0].BaseURL; got != "http://192.168.6.167/rest" {
		t.Fatalf("expected MikroTik base_url to round-trip, got %q", got)
	}

	if len(cfg.ScheduledJobs) != 1 {
		t.Fatalf("expected one scheduled job, got %d", len(cfg.ScheduledJobs))
	}

	if got := cfg.ScheduledJobs[0].DiscoveryMode; got != "snmp_api" {
		t.Fatalf("expected discovery_mode to round-trip, got %q", got)
	}
}

func TestParseGatewayMapperConfigPreservesProxmoxEndpoints(t *testing.T) {
	raw := []byte(`{
		"mapper": {
			"workers": 10,
			"proxmox_apis": [
				{
					"name": "tonka01-pve",
					"base_url": "https://192.168.2.22:8006",
					"token_id": "svc@pve!codex",
					"token_secret": "secret-token",
					"insecure_skip_verify": true
				}
			],
			"scheduled_jobs": [
				{
					"name": "tonka01",
					"type": "network",
					"enabled": true,
					"interval": "5m",
					"discovery_mode": "snmp_api",
					"options": {
						"proxmox_api_names": "tonka01-pve"
					}
				}
			]
		}
	}`)

	cfg, err := parseGatewayMapperConfig(raw)
	if err != nil {
		t.Fatalf("expected mapper config to parse, got error: %v", err)
	}

	if cfg == nil {
		t.Fatal("expected mapper config, got nil")
		return
	}

	if len(cfg.ProxmoxAPIs) != 1 {
		t.Fatalf("expected one Proxmox endpoint, got %d", len(cfg.ProxmoxAPIs))
	}

	if got := cfg.ProxmoxAPIs[0].BaseURL; got != "https://192.168.2.22:8006" {
		t.Fatalf("expected Proxmox base_url to round-trip, got %q", got)
	}

	if got := cfg.ProxmoxAPIs[0].TokenID; got != "svc@pve!codex" {
		t.Fatalf("expected Proxmox token_id to round-trip, got %q", got)
	}
}

func TestBuildMapperEngineConfigIncludesMikroTikEndpoints(t *testing.T) {
	cfg := &gatewayMapperConfig{
		Workers: 12,
		Timeout: "45s",
		MikroTikAPIs: []mapperMikroTikSpec{
			{
				Name:               "tonka01",
				BaseURL:            "http://192.168.6.167/rest",
				Username:           "serviceradar",
				Password:           "secret",
				InsecureSkipVerify: true,
			},
		},
		ScheduledJobs: []mapperJobSpec{
			{
				Name:          "tonka01",
				Interval:      "5m",
				Enabled:       true,
				Type:          "network",
				DiscoveryMode: "snmp_api",
				Options: map[string]string{
					"mikrotik_api_names": "tonka01",
				},
			},
		},
	}

	serverCfg := &ServerConfig{
		AgentID:   "agent-dusk",
		Partition: "default",
	}

	engineCfg, err := buildMapperEngineConfig(cfg, serverCfg, logger.NewTestLogger())
	if err != nil {
		t.Fatalf("expected mapper engine config to build, got error: %v", err)
	}

	if len(engineCfg.MikroTikAPIs) != 1 {
		t.Fatalf("expected one MikroTik API in engine config, got %d", len(engineCfg.MikroTikAPIs))
	}

	if got := engineCfg.MikroTikAPIs[0].Username; got != "serviceradar" {
		t.Fatalf("expected MikroTik username to be preserved, got %q", got)
	}

	if got := engineCfg.ScheduledJobs[0].DiscoveryMode; got != "snmp_api" {
		t.Fatalf("expected discovery_mode to be preserved, got %q", got)
	}

	if engineCfg.Timeout != 45*time.Second {
		t.Fatalf("expected timeout to parse as 45s, got %s", engineCfg.Timeout)
	}

	if got := engineCfg.StreamConfig.AgentID; got != "agent-dusk" {
		t.Fatalf("expected stream agent_id to be propagated, got %q", got)
	}
}

func TestBuildMapperEngineConfigIncludesProxmoxEndpoints(t *testing.T) {
	cfg := &gatewayMapperConfig{
		Workers: 12,
		Timeout: "45s",
		ProxmoxAPIs: []mapperProxmoxSpec{
			{
				Name:               "tonka01-pve",
				BaseURL:            "https://192.168.2.22:8006",
				TokenID:            "svc@pve!codex",
				TokenSecret:        "secret-token",
				InsecureSkipVerify: true,
			},
		},
		ScheduledJobs: []mapperJobSpec{
			{
				Name:          "tonka01",
				Interval:      "5m",
				Enabled:       true,
				Type:          "network",
				DiscoveryMode: "snmp_api",
				Options: map[string]string{
					"proxmox_api_names": "tonka01-pve",
				},
			},
		},
	}

	serverCfg := &ServerConfig{
		AgentID:   "agent-dusk",
		Partition: "default",
	}

	engineCfg, err := buildMapperEngineConfig(cfg, serverCfg, logger.NewTestLogger())
	if err != nil {
		t.Fatalf("expected mapper engine config to build, got error: %v", err)
	}

	if len(engineCfg.ProxmoxAPIs) != 1 {
		t.Fatalf("expected one Proxmox API in engine config, got %d", len(engineCfg.ProxmoxAPIs))
	}

	if got := engineCfg.ProxmoxAPIs[0].TokenID; got != "svc@pve!codex" {
		t.Fatalf("expected Proxmox token_id to be preserved, got %q", got)
	}

	if got := engineCfg.ScheduledJobs[0].Options["proxmox_api_names"]; got != "tonka01-pve" {
		t.Fatalf("expected proxmox_api_names selector to be preserved, got %q", got)
	}
}

func TestParseGatewayMapperConfigComputesConfigHash(t *testing.T) {
	payload := map[string]any{
		"mapper": map[string]any{
			"workers": 4,
		},
	}

	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("expected payload marshal to succeed, got error: %v", err)
	}

	cfg, err := parseGatewayMapperConfig(raw)
	if err != nil {
		t.Fatalf("expected mapper config to parse, got error: %v", err)
	}

	if cfg == nil || cfg.ConfigHash == "" {
		t.Fatal("expected computed config hash")
	}
}
