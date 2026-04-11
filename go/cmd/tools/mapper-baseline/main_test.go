package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/mapper"
)

func TestLoadRunConfigAndNormalizeSNMP(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "baseline.json")
	raw := []byte(`{
  "mode": "snmp",
  "seeds": ["192.168.1.238", "192.168.1.138"],
  "type": "topology",
  "snmp": {
    "version": "v2c",
    "community": "public"
  }
}`)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadRunConfig(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}

	if cfg.Mode != "snmp" {
		t.Fatalf("unexpected mode %q", cfg.Mode)
	}
	if cfg.DiscoveryMode != "snmp" {
		t.Fatalf("expected discovery mode snmp, got %q", cfg.DiscoveryMode)
	}
	if len(cfg.Seeds) != 2 {
		t.Fatalf("expected 2 seeds, got %d", len(cfg.Seeds))
	}
}

func TestNormalizeDerivesControllerSeeds(t *testing.T) {
	t.Parallel()

	cfg := &runConfig{
		Mode: "unifi",
		UniFi: []mapper.UniFiAPIConfig{{
			BaseURL: "https://unifi.example.com:8443",
			APIKey:  "token",
		}},
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}

	if len(cfg.Seeds) != 1 || cfg.Seeds[0] != "unifi.example.com" {
		t.Fatalf("unexpected derived seeds: %#v", cfg.Seeds)
	}
	if cfg.DiscoveryMode != "api" {
		t.Fatalf("expected discovery mode api, got %q", cfg.DiscoveryMode)
	}
}

func TestNormalizeAcceptsAPIConfigMode(t *testing.T) {
	t.Parallel()

	cfg := &runConfig{
		Mode: "api",
		UniFi: []mapper.UniFiAPIConfig{{
			BaseURL: "https://farm.example.com",
			APIKey:  "token",
		}},
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}

	if cfg.Mode != "controller" {
		t.Fatalf("expected normalized mode controller, got %q", cfg.Mode)
	}
	if cfg.DiscoveryMode != "api" {
		t.Fatalf("expected discovery mode api, got %q", cfg.DiscoveryMode)
	}
	if len(cfg.Seeds) != 1 || cfg.Seeds[0] != "farm.example.com" {
		t.Fatalf("unexpected derived seeds: %#v", cfg.Seeds)
	}
}

func TestNormalizeAcceptsHybridControllerMode(t *testing.T) {
	t.Parallel()

	cfg := &runConfig{
		Mode: "snmp_api",
		UniFi: []mapper.UniFiAPIConfig{{
			BaseURL: "https://farm.example.com",
			APIKey:  "token",
		}},
		MikroTik: []mapper.MikroTikAPIConfig{{
			BaseURL:  "http://mikrotik.example.com/rest",
			Username: "user",
			Password: "pass",
		}},
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}

	if cfg.Mode != "controller" {
		t.Fatalf("expected normalized mode controller, got %q", cfg.Mode)
	}
	if cfg.DiscoveryMode != "snmp_api" {
		t.Fatalf("expected discovery mode snmp_api, got %q", cfg.DiscoveryMode)
	}
	if len(cfg.Seeds) != 2 {
		t.Fatalf("expected 2 derived seeds, got %#v", cfg.Seeds)
	}
}

func TestParseRunConfigFlagsOverrideConfigFile(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "baseline.json")
	raw := []byte(`{
  "mode": "api",
  "output": "/tmp/from-config.json",
  "discovery_mode": "api",
  "unifi": [{
    "base_url": "https://controller.example.com",
    "api_key": "token"
  }]
}`)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := parseRunConfig([]string{
		"--config", path,
		"--output", "/tmp/from-flag.json",
		"--mode", "snmp_api",
	})
	if err != nil {
		t.Fatalf("parse run config: %v", err)
	}

	if cfg.Output != "/tmp/from-flag.json" {
		t.Fatalf("expected output override to win, got %q", cfg.Output)
	}
	if cfg.Mode != "snmp_api" {
		t.Fatalf("expected mode override to win, got %q", cfg.Mode)
	}
}

func TestNormalizeModeAliasOverridesConfigDiscoveryMode(t *testing.T) {
	t.Parallel()

	cfg := &runConfig{
		Mode:          "snmp_api",
		DiscoveryMode: "api",
		UniFi: []mapper.UniFiAPIConfig{{
			BaseURL: "https://farm.example.com",
			APIKey:  "token",
		}},
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}

	if cfg.Mode != "controller" {
		t.Fatalf("expected normalized mode controller, got %q", cfg.Mode)
	}
	if cfg.DiscoveryMode != "snmp_api" {
		t.Fatalf("expected alias to override discovery mode, got %q", cfg.DiscoveryMode)
	}
}

func TestBuildReportProducesStableCounts(t *testing.T) {
	t.Parallel()

	report := buildReport(&runConfig{
		Mode:  "snmp",
		Type:  "topology",
		Seeds: []string{"192.168.1.238"},
	}, &mapper.DiscoveryResults{
		DiscoveryID: "disc-1",
		Status:      &mapper.DiscoveryStatus{Status: mapper.DiscoveryStatusCompleted},
		Devices: []*mapper.DiscoveredDevice{
			{DeviceID: "b", IP: "192.168.1.2"},
			{DeviceID: "a", IP: "192.168.1.1"},
		},
		Interfaces: []*mapper.DiscoveredInterface{
			{DeviceID: "b", IfIndex: 7, IfName: "eth7"},
			{DeviceID: "a", IfIndex: 1, IfName: "eth1"},
		},
		TopologyLinks: []*mapper.TopologyLink{
			{Protocol: "LLDP", LocalDeviceID: "b", NeighborMgmtAddr: "192.168.1.10", Metadata: map[string]string{
				"evidence_class":  "direct-physical",
				"confidence_tier": "high",
			}},
			{Protocol: "snmp-l2", LocalDeviceID: "a", NeighborMgmtAddr: "192.168.1.11", Metadata: map[string]string{
				"evidence_class":  "inferred-segment",
				"confidence_tier": "medium",
			}},
			{Protocol: "lldp", LocalDeviceID: "a", NeighborMgmtAddr: "192.168.1.12", Metadata: map[string]string{
				"evidence_class":  "direct-physical",
				"confidence_tier": "high",
			}},
		},
	})

	if report.Summary.Devices != 2 || report.Summary.Interfaces != 2 || report.Summary.TopologyLinks != 3 {
		t.Fatalf("unexpected summary counts: %#v", report.Summary)
	}

	if report.Devices[0].DeviceID != "a" || report.Devices[1].DeviceID != "b" {
		t.Fatalf("devices not sorted: %#v", report.Devices)
	}

	if len(report.Summary.ByProtocol) != 2 {
		t.Fatalf("unexpected protocol counts: %#v", report.Summary.ByProtocol)
	}
	if report.Summary.ByProtocol[0].Name != "lldp" || report.Summary.ByProtocol[0].Count != 2 {
		t.Fatalf("unexpected first protocol count: %#v", report.Summary.ByProtocol[0])
	}
	if report.Summary.ByProtocol[1].Name != "snmp-l2" || report.Summary.ByProtocol[1].Count != 1 {
		t.Fatalf("unexpected second protocol count: %#v", report.Summary.ByProtocol[1])
	}

	if len(report.Summary.ByEvidenceClass) != 2 {
		t.Fatalf("unexpected evidence counts: %#v", report.Summary.ByEvidenceClass)
	}
	if report.Summary.ByEvidenceClass[0].Name != "direct-physical" || report.Summary.ByEvidenceClass[0].Count != 2 {
		t.Fatalf("unexpected direct-physical count: %#v", report.Summary.ByEvidenceClass[0])
	}
	if report.Summary.ByEvidenceClass[1].Name != "inferred-segment" || report.Summary.ByEvidenceClass[1].Count != 1 {
		t.Fatalf("unexpected inferred count: %#v", report.Summary.ByEvidenceClass[1])
	}
}
