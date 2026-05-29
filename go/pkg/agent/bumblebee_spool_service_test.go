package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
)

const bumblebeeSpoolTestAgentID = "agent-1"

func TestBumblebeeSpoolServiceMissingSpoolReturnsNotScanned(t *testing.T) {
	spoolPath := filepath.Join(t.TempDir(), "missing.json")
	service := NewBumblebeeSpoolService(bumblebeeSpoolTestAgentID, &BumblebeeStatusConfig{SpoolPath: spoolPath})

	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if status.Available {
		t.Fatal("expected unavailable status")
	}

	var payload bumblebee.ScanPayload
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.AgentID != bumblebeeSpoolTestAgentID || payload.State != "not_scanned" || payload.CoverageState != "not_scanned" {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if payload.Metadata["reason"] != "spool_not_found" {
		t.Fatalf("unexpected metadata: %#v", payload.Metadata)
	}
}

func TestBumblebeeSpoolServiceInjectsMissingAgentID(t *testing.T) {
	tmpDir := t.TempDir()
	spoolPath := filepath.Join(tmpDir, "latest.json")
	if err := os.WriteFile(spoolPath, []byte(`{"schema_version":"serviceradar.bumblebee.scan.v1","run_id":"run-1","state":"scanned","coverage_state":"complete","findings":[]}`), 0600); err != nil {
		t.Fatal(err)
	}

	service := NewBumblebeeSpoolService(bumblebeeSpoolTestAgentID, &BumblebeeStatusConfig{SpoolPath: spoolPath})
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if !status.Available {
		t.Fatal("expected available status")
	}

	var payload map[string]any
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["agent_id"] != bumblebeeSpoolTestAgentID {
		t.Fatalf("agent_id = %#v, want %s", payload["agent_id"], bumblebeeSpoolTestAgentID)
	}
}

func TestBumblebeeSpoolServicePreservesExistingAgentID(t *testing.T) {
	tmpDir := t.TempDir()
	spoolPath := filepath.Join(tmpDir, "latest.json")
	if err := os.WriteFile(spoolPath, []byte(`{"agent_id":"agent-original","schema_version":"serviceradar.bumblebee.scan.v1","run_id":"run-1","state":"scanned","coverage_state":"complete","findings":[]}`), 0600); err != nil {
		t.Fatal(err)
	}

	service := NewBumblebeeSpoolService(bumblebeeSpoolTestAgentID, &BumblebeeStatusConfig{SpoolPath: spoolPath})
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	var payload map[string]any
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["agent_id"] != "agent-original" {
		t.Fatalf("agent_id = %#v, want agent-original", payload["agent_id"])
	}
}
