package endpointinventory

import (
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
