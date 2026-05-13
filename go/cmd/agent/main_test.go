package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigIgnoresUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.json")
	data := []byte(`{
		"agent_id": "agent-test",
		"checkers_dir": "/tmp/checkers",
		"future_chart_field": "ignored"
	}`)

	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("load config returned error: %v", err)
	}
	if cfg.AgentID != "agent-test" {
		t.Fatalf("agent_id = %q, want agent-test", cfg.AgentID)
	}
}

func TestLoadConfigRejectsTrailingData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.json")
	data := []byte(`{"agent_id":"agent-test","checkers_dir":"/tmp/checkers"} {}`)

	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	_, err := loadConfig(path)
	if !errors.Is(err, errConfigTrailingData) {
		t.Fatalf("error = %v, want %v", err, errConfigTrailingData)
	}
}
