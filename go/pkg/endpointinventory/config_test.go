package endpointinventory

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

const configTestAgentID = "agent-1"

func TestRuntimeProfileAppliesCadenceAndRedactionControls(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "endpoint-inventory.json")
	profilePath := filepath.Join(tmpDir, "runtime.json")

	profile := `{
		"enabled": true,
		"agent_id": "` + configTestAgentID + `",
		"sources": ["dpkg"],
		"cadence": "` + endpointInventoryTestCadence + `",
		"collect_paths": true,
		"collect_file_hashes": true
	}`
	if err := os.WriteFile(profilePath, []byte(profile), 0600); err != nil {
		t.Fatal(err)
	}

	config := `{
		"enabled": false,
		"profile_path": "` + profilePath + `",
		"spool_dir": "` + filepath.Join(tmpDir, "spool") + `",
		"cache_dir": "` + filepath.Join(tmpDir, "cache") + `",
		"tmp_dir": "` + filepath.Join(tmpDir, "tmp") + `"
	}`
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Enabled || cfg.AgentID != configTestAgentID {
		t.Fatalf("runtime profile did not enable agent config: %#v", cfg)
	}
	if cfg.Cadence != endpointInventoryTestCadence || !cfg.CollectPaths || !cfg.CollectFileHashes {
		t.Fatalf("runtime cadence/redaction controls not applied: %#v", cfg)
	}
}

func TestLoadConfigRejectsInvalidCadence(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "endpoint-inventory.json")
	config := `{
		"enabled": true,
		"agent_id": "` + configTestAgentID + `",
		"cadence": "0s",
		"spool_dir": "` + filepath.Join(tmpDir, "spool") + `",
		"cache_dir": "` + filepath.Join(tmpDir, "cache") + `",
		"tmp_dir": "` + filepath.Join(tmpDir, "tmp") + `"
	}`
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadConfig(configPath); err == nil {
		t.Fatal("expected invalid cadence to be rejected")
	}
}

func TestValidateConfigRejectsInvalidRetryAndOutputBounds(t *testing.T) {
	tests := map[string]func(*Config){
		"negative packages": func(cfg *Config) { cfg.MaxPackages = -1 },
		"negative attempts": func(cfg *Config) { cfg.UploadRetryMaxAttempts = -1 },
		"retry max below initial": func(cfg *Config) {
			cfg.UploadRetryInitial = endpointInventoryTestTenMins
			cfg.UploadRetryMax = "5m"
		},
		"output above transport cap": func(cfg *Config) {
			cfg.MaxOutputBytes = MaxSpoolPayloadBytes + 1
		},
		"nonpositive stale threshold": func(cfg *Config) { cfg.CacheStaleThreshold = "0s" },
	}

	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			cfg := DefaultConfig()
			cfg.Enabled = true
			cfg.AgentID = configTestAgentID
			mutate(&cfg)
			if err := ValidateConfig(cfg); err == nil {
				t.Fatal("expected invalid effective config to be rejected")
			}
		})
	}

	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = configTestAgentID
	cfg.MaxOutputBytes = MaxSpoolPayloadBytes
	if err := ValidateConfig(cfg); err != nil {
		t.Fatalf("exact transport cap should be valid: %v", err)
	}
	cfg.MaxOutputBytes++
	if err := ValidateConfig(cfg); !errors.Is(err, ErrInvalidMaxOutputSize) {
		t.Fatalf("oversize error = %v, want ErrInvalidMaxOutputSize", err)
	}
}

func TestLegacyConfigHashIncludesRPMCommandPath(t *testing.T) {
	cfg := DefaultConfig()
	before := computeConfigHash(cfg)
	cfg.RPMPath = "/custom/bin/rpm"
	if after := computeConfigHash(cfg); after == before {
		t.Fatal("changing the collection RPM command path did not change config hash")
	}
}
