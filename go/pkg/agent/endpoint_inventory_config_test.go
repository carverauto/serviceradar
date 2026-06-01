package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	monitoringpb "github.com/carverauto/serviceradar/proto"
)

func TestResolveGatewayEndpointInventoryConfigPrefersTypedProto(t *testing.T) {
	cfg, err := resolveGatewayEndpointInventoryConfig(&monitoringpb.EndpointInventoryConfig{
		Enabled:        true,
		AgentId:        "agent-typed",
		Sources:        []string{"dpkg", "apk"},
		ScanTimeout:    "3m",
		MaxPackages:    123,
		MaxOutputBytes: 456,
		Cadence:        "12h",
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

	profile := cfg.runtimeProfile("agent-canonical")
	if profile.AgentID != "agent-canonical" {
		t.Fatalf("runtime profile agent = %q, want canonical", profile.AgentID)
	}
	if profile.MaxPackages == nil || *profile.MaxPackages != 123 {
		t.Fatalf("max packages = %#v, want 123", profile.MaxPackages)
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
				AgentID: "agent-canonical",
				EndpointInventory: &EndpointInventoryStatusConfig{
					ProfilePath: profilePath,
					TmpDir:      tmpDir,
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	ok := pl.applyEndpointInventoryConfig(nil, &monitoringpb.EndpointInventoryConfig{
		Enabled:        true,
		AgentId:        "agent-from-control-plane",
		Sources:        []string{"dpkg"},
		ScanTimeout:    "5m",
		MaxPackages:    1000,
		MaxOutputBytes: 2048,
	}, nil)
	if !ok {
		t.Fatal("expected endpoint inventory config to apply")
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
	if profile.AgentID != "agent-canonical" {
		t.Fatalf("agent id = %q, want canonical", profile.AgentID)
	}
	if len(profile.Sources) != 1 || profile.Sources[0] != "dpkg" {
		t.Fatalf("sources = %#v, want [dpkg]", profile.Sources)
	}
}
