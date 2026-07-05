package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	monitoringpb "github.com/carverauto/serviceradar/proto"
)

const endpointInventoryConfigTestCanonicalAgentID = "agent-canonical"

func TestResolveGatewayEndpointInventoryConfigPrefersTypedProto(t *testing.T) {
	cfg, err := resolveGatewayEndpointInventoryConfig(&monitoringpb.EndpointInventoryConfig{
		Enabled:                true,
		AgentId:                "agent-typed",
		Sources:                []string{"dpkg", "apk"},
		ScanTimeout:            "3m",
		MaxPackages:            123,
		MaxOutputBytes:         456,
		Cadence:                "12h",
		CollectPaths:           true,
		CollectFileHashes:      true,
		ForceFreshEnabled:      true,
		ForceFullScanInterval:  24,
		CacheStaleThreshold:    "36h",
		UploadJitter:           "10m",
		UploadRetryInitial:     "30s",
		UploadRetryMax:         "15m",
		UploadRetryMaxAttempts: 4,
	}, []byte(`{"endpoint_inventory":{"enabled":false}}`))
	if err != nil {
		t.Fatalf("resolve config: %v", err)
	}
	if cfg == nil || !cfg.Enabled {
		t.Fatal("expected enabled typed config")
	}
	if cfg.AgentID != "agent-typed" || cfg.ScanTimeout != "3m" || cfg.MaxPackages != 123 {
		t.Fatalf("typed fields were not retained: %#v", cfg)
	}
	if !cfg.ForceFresh || cfg.ForceFullScan != 24 || cfg.CacheStale != "36h" {
		t.Fatalf("freshness fields were not retained: %#v", cfg)
	}
	if cfg.Cadence != "12h" || !cfg.CollectPaths || !cfg.CollectHashes {
		t.Fatalf("cadence/redaction fields were not retained: %#v", cfg)
	}
	if cfg.UploadJitter != "10m" || cfg.RetryInitial != "30s" || cfg.RetryMax != "15m" || cfg.RetryAttempts != 4 {
		t.Fatalf("upload retry fields were not retained: %#v", cfg)
	}

	profile := cfg.runtimeProfile(endpointInventoryConfigTestCanonicalAgentID)
	if profile.AgentID != endpointInventoryConfigTestCanonicalAgentID {
		t.Fatalf("runtime profile agent = %q, want canonical", profile.AgentID)
	}
	if profile.MaxPackages == nil || *profile.MaxPackages != 123 {
		t.Fatalf("max packages = %#v, want 123", profile.MaxPackages)
	}
	if profile.ForceFreshEnabled == nil || !*profile.ForceFreshEnabled {
		t.Fatalf("force fresh = %#v, want true", profile.ForceFreshEnabled)
	}
	if profile.ForceFullScanInterval == nil || *profile.ForceFullScanInterval != 24 {
		t.Fatalf("force full scan interval = %#v, want 24", profile.ForceFullScanInterval)
	}
	if profile.Cadence != "12h" {
		t.Fatalf("cadence = %q, want 12h", profile.Cadence)
	}
	if profile.CollectPaths == nil || !*profile.CollectPaths {
		t.Fatalf("collect paths = %#v, want true", profile.CollectPaths)
	}
	if profile.CollectFileHashes == nil || !*profile.CollectFileHashes {
		t.Fatalf("collect file hashes = %#v, want true", profile.CollectFileHashes)
	}
}

func TestResolveGatewayEndpointInventoryConfigFallsBackToJSON(t *testing.T) {
	cfg, err := resolveGatewayEndpointInventoryConfig(nil, []byte(`{
		"endpoint_inventory": {
			"enabled": true,
			"agent_id": "agent-json",
			"sources": ["rpm"],
			"scan_timeout": "4m",
			"max_packages": 321,
			"max_output_bytes": 654
		}
	}`))
	if err != nil {
		t.Fatalf("resolve config: %v", err)
	}
	if cfg == nil || !cfg.Enabled {
		t.Fatal("expected enabled JSON config")
	}
	if cfg.AgentID != "agent-json" || len(cfg.Sources) != 1 || cfg.Sources[0] != "rpm" {
		t.Fatalf("json fields were not retained: %#v", cfg)
	}
}

func TestApplyEndpointInventoryConfigWritesRuntimeProfile(t *testing.T) {
	dir := t.TempDir()
	profilePath := filepath.Join(dir, "profile", "runtime.json")
	tmpDir := filepath.Join(dir, "tmp")

	pl := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID: endpointInventoryConfigTestCanonicalAgentID,
				EndpointInventory: &EndpointInventoryStatusConfig{
					ProfilePath: profilePath,
					TmpDir:      tmpDir,
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	disposition, _ := pl.applyEndpointInventoryConfig(context.Background(), &monitoringpb.EndpointInventoryConfig{
		Enabled:                true,
		AgentId:                "agent-from-control-plane",
		Sources:                []string{"dpkg"},
		ScanTimeout:            "5m",
		Cadence:                "6h",
		CollectPaths:           true,
		MaxPackages:            1000,
		MaxOutputBytes:         2048,
		ForceFreshEnabled:      true,
		ForceFullScanInterval:  12,
		CacheStaleThreshold:    "24h",
		UploadJitter:           "7m",
		UploadRetryInitial:     "45s",
		UploadRetryMax:         "20m",
		UploadRetryMaxAttempts: 3,
	}, nil)
	if disposition != addonDeliverySucceeded {
		t.Fatalf("expected endpoint inventory config to apply, got disposition %v", disposition)
	}

	data, err := os.ReadFile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	var profile endpointinventory.RuntimeProfile
	if err := json.Unmarshal(data, &profile); err != nil {
		t.Fatal(err)
	}
	if profile.Enabled == nil || !*profile.Enabled {
		t.Fatalf("profile enabled = %#v, want true", profile.Enabled)
	}
	if profile.AgentID != endpointInventoryConfigTestCanonicalAgentID {
		t.Fatalf("agent id = %q, want canonical", profile.AgentID)
	}
	if len(profile.Sources) != 1 || profile.Sources[0] != "dpkg" {
		t.Fatalf("sources = %#v, want [dpkg]", profile.Sources)
	}
	if profile.ForceFreshEnabled == nil || !*profile.ForceFreshEnabled {
		t.Fatalf("force fresh = %#v, want true", profile.ForceFreshEnabled)
	}
	if profile.ForceFullScanInterval == nil || *profile.ForceFullScanInterval != 12 {
		t.Fatalf("force full scan interval = %#v, want 12", profile.ForceFullScanInterval)
	}
	if profile.Cadence != "6h" {
		t.Fatalf("cadence = %q, want 6h", profile.Cadence)
	}
	if profile.CollectPaths == nil || !*profile.CollectPaths {
		t.Fatalf("collect paths = %#v, want true", profile.CollectPaths)
	}
	if profile.CollectFileHashes == nil || *profile.CollectFileHashes {
		t.Fatalf("collect file hashes = %#v, want false", profile.CollectFileHashes)
	}
	if profile.CacheStaleThreshold != "24h" || profile.UploadJitter != "7m" {
		t.Fatalf("freshness/jitter fields = %#v, want cache 24h jitter 7m", profile)
	}
	if profile.UploadRetryInitial != "45s" || profile.UploadRetryMax != "20m" {
		t.Fatalf("retry durations = %#v, want 45s/20m", profile)
	}
	if profile.UploadRetryMaxAttempts == nil || *profile.UploadRetryMaxAttempts != 3 {
		t.Fatalf("retry attempts = %#v, want 3", profile.UploadRetryMaxAttempts)
	}
}

func TestApplyEndpointInventoryConfigSkipsDisabledRuntimeProfileForKubernetesAgent(t *testing.T) {
	dir := t.TempDir()
	profilePath := filepath.Join(dir, "profile", "runtime.json")

	pl := &PushLoop{
		server: &Server{
			config: &ServerConfig{
				AgentID: kubernetesAgentID,
				EndpointInventory: &EndpointInventoryStatusConfig{
					ProfilePath: profilePath,
					TmpDir:      filepath.Join(dir, "tmp"),
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	disposition, _ := pl.applyEndpointInventoryConfig(context.Background(), &monitoringpb.EndpointInventoryConfig{
		Enabled: false,
	}, nil)
	if disposition != addonDeliverySucceeded {
		t.Fatalf("expected disabled Kubernetes endpoint inventory config application to succeed, got %v", disposition)
	}
	if _, err := os.Stat(profilePath); !os.IsNotExist(err) {
		t.Fatalf("expected no runtime profile to be written, stat err=%v", err)
	}
}
