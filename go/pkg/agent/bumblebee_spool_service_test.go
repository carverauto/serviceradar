package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
)

const (
	bumblebeeSpoolTestAgentID = "agent-1"
	bumblebeeStateNotScanned  = "not_scanned"
)

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
	if payload.AgentID != bumblebeeSpoolTestAgentID || payload.State != bumblebeeStateNotScanned || payload.CoverageState != bumblebeeStateNotScanned {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if payload.Metadata["reason"] != "spool_not_found" {
		t.Fatalf("unexpected metadata: %#v", payload.Metadata)
	}
	if !payload.LastScanAt.IsZero() {
		t.Fatalf("not-scanned payload should not stamp volatile last_scan_at, got %s", payload.LastScanAt)
	}
}

func TestBumblebeeSpoolServiceMissingSpoolStatusIsStable(t *testing.T) {
	spoolPath := filepath.Join(t.TempDir(), "missing.json")
	service := NewBumblebeeSpoolService(bumblebeeSpoolTestAgentID, &BumblebeeStatusConfig{SpoolPath: spoolPath})

	first, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if string(first.Message) != string(second.Message) {
		t.Fatalf("missing-spool status should be stable:\nfirst=%s\nsecond=%s", first.Message, second.Message)
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

func TestBumblebeeSpoolServiceOverridesExistingAgentID(t *testing.T) {
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
	if payload["agent_id"] != bumblebeeSpoolTestAgentID {
		t.Fatalf("agent_id = %#v, want %s", payload["agent_id"], bumblebeeSpoolTestAgentID)
	}
}
