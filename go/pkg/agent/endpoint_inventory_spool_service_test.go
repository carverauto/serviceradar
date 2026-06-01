package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
)

const endpointInventorySpoolTestAgentID = "agent-1"

func TestEndpointInventorySpoolServiceMissingSpoolReturnsNotScanned(t *testing.T) {
	spoolPath := filepath.Join(t.TempDir(), "missing.json")
	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{SpoolPath: spoolPath},
	)

	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if status.Available {
		t.Fatal("expected unavailable status")
	}

	var payload endpointinventory.ScanPayload
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.AgentID != endpointInventorySpoolTestAgentID ||
		payload.State != "not_scanned" ||
		payload.CoverageState != "not_scanned" ||
		payload.PackageCount != 0 {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if payload.Metadata["reason"] != "spool_not_found" {
		t.Fatalf("unexpected metadata: %#v", payload.Metadata)
	}
}

func TestEndpointInventorySpoolServiceOverridesExistingAgentID(t *testing.T) {
	tmpDir := t.TempDir()
	spoolPath := filepath.Join(tmpDir, "latest.json")
	if err := os.WriteFile(spoolPath, []byte(`{"agent_id":"agent-original","schema_version":"serviceradar.endpoint_inventory.scan.v1","scan_id":"scan-1","state":"scanned","coverage_state":"complete","package_count":0}`), 0600); err != nil {
		t.Fatal(err)
	}

	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{SpoolPath: spoolPath},
	)
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	var payload map[string]any
	if err := json.Unmarshal(status.Message, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["agent_id"] != endpointInventorySpoolTestAgentID {
		t.Fatalf("agent_id = %#v, want %s", payload["agent_id"], endpointInventorySpoolTestAgentID)
	}
}
