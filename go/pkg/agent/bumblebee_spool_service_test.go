package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	sraddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/stretchr/testify/require"
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

func TestBumblebeeSpoolServiceAddonTelemetryEmitsScanAndFindingEvents(t *testing.T) {
	lastScanAt := time.Date(2026, 6, 9, 18, 30, 0, 0, time.UTC)
	payload := bumblebee.ScanPayload{
		SchemaVersion:      bumblebee.SchemaVersion,
		AgentID:            bumblebeeSpoolTestAgentID,
		DeviceUID:          "sr:device-1",
		RunID:              "run-1",
		ScannerVersion:     "0.1.1",
		CatalogSnapshotRef: "catalog-sha",
		State:              "scanned",
		CoverageState:      "complete",
		AttemptedRootCount: 3,
		ScannedRootCount:   3,
		LastScanAt:         lastScanAt,
		Findings: []bumblebee.Finding{
			{
				FindingID:      "finding-1",
				CatalogID:      "catalog-rule-1",
				Severity:       "High",
				Ecosystem:      "deb",
				PackageName:    "nginx",
				PackageVersion: "1.24.0",
				Confidence:     "high",
			},
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	service := NewBumblebeeSpoolService(bumblebeeSpoolTestAgentID, &BumblebeeStatusConfig{SpoolPath: filepath.Join(t.TempDir(), "unused.json")})
	source, batch := service.AddonTelemetryBatch(&proto.StatusResponse{
		Available: true,
		Message:   data,
	})
	if source != bumblebeeTelemetryProducerID {
		t.Fatalf("source = %q, want %s", source, bumblebeeTelemetryProducerID)
	}
	require.NotNil(t, batch, "expected telemetry batch")
	if got := len(batch.Records); got != 2 {
		t.Fatalf("records = %d, want 2", got)
	}
	if batch.Counters.GetReceived() != 2 || batch.Counters.GetEmitted() != 2 {
		t.Fatalf("unexpected counters: %#v", batch.Counters)
	}

	scanEvent := decodeTelemetryPayload(t, batch.Records[0])
	if scanEvent["class_uid"] != float64(6007) || scanEvent["category_uid"] != float64(6) {
		t.Fatalf("scan event class/category = %#v/%#v, want 6007/6", scanEvent["class_uid"], scanEvent["category_uid"])
	}
	if scanEvent["activity_id"] != float64(2) || scanEvent["activity_name"] != "Completed" {
		t.Fatalf("scan event activity = %#v/%#v, want 2/Completed", scanEvent["activity_id"], scanEvent["activity_name"])
	}
	assertTelemetrySchemaRef(t, batch.Records[0], "ocsf.scan_activity")
	assertMetadataVersion(t, scanEvent, "1.9.0-dev")
	assertServiceRadarMetadata(t, scanEvent, "scan_activity", "sr:device-1")

	findingEvent := decodeTelemetryPayload(t, batch.Records[1])
	if findingEvent["class_uid"] != float64(2007) || findingEvent["category_uid"] != float64(2) {
		t.Fatalf("finding event class/category = %#v/%#v, want 2007/2", findingEvent["class_uid"], findingEvent["category_uid"])
	}
	if findingEvent["activity_id"] != float64(1) || findingEvent["activity_name"] != "Create" {
		t.Fatalf("finding event activity = %#v/%#v, want 1/Create", findingEvent["activity_id"], findingEvent["activity_name"])
	}
	if findingEvent["severity_id"] != float64(4) || findingEvent["severity"] != "High" {
		t.Fatalf("finding event severity = %#v/%#v, want 4/High", findingEvent["severity_id"], findingEvent["severity"])
	}
	assertTelemetrySchemaRef(t, batch.Records[1], "ocsf.application_security_posture_finding")
	assertMetadataVersion(t, findingEvent, "1.9.0-dev")
	assertServiceRadarMetadata(t, findingEvent, "application_security_posture_finding", "sr:device-1")
}

func decodeTelemetryPayload(t *testing.T, record *addonpb.TelemetryRecord) map[string]any {
	t.Helper()

	var payload map[string]any
	if err := json.Unmarshal(record.Payload, &payload); err != nil {
		t.Fatal(err)
	}

	return payload
}

func assertTelemetrySchemaRef(t *testing.T, record *addonpb.TelemetryRecord, schemaID string) {
	t.Helper()

	metadata := record.GetMetadata()
	if metadata[sraddon.SignalSchemaMetadataProducerID] != bumblebeeTelemetryProducerID ||
		metadata[sraddon.SignalSchemaMetadataSchemaID] != schemaID ||
		metadata[sraddon.SignalSchemaMetadataPayloadKind] != "ocsf_event" {
		t.Fatalf("unexpected schema ref metadata: %#v", metadata)
	}
}

func assertMetadataVersion(t *testing.T, event map[string]any, version string) {
	t.Helper()

	metadata, ok := event["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("metadata missing or malformed: %#v", event["metadata"])
	}
	if metadata["version"] != version {
		t.Fatalf("metadata.version = %#v, want %s", metadata["version"], version)
	}
}

func assertServiceRadarMetadata(t *testing.T, event map[string]any, ocsfClass string, deviceUID string) {
	t.Helper()

	metadata, ok := event["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("metadata missing or malformed: %#v", event["metadata"])
	}
	serviceRadar, ok := metadata["service_radar"].(map[string]any)
	if !ok {
		t.Fatalf("service_radar metadata missing or malformed: %#v", metadata["service_radar"])
	}
	if serviceRadar["source_type"] != bumblebeeTelemetryProducerID || serviceRadar["addon_id"] != bumblebeeTelemetryProducerID {
		t.Fatalf("unexpected service_radar source metadata: %#v", serviceRadar)
	}
	if serviceRadar["ocsf_class"] != ocsfClass {
		t.Fatalf("service_radar.ocsf_class = %#v, want %s", serviceRadar["ocsf_class"], ocsfClass)
	}
	if serviceRadar["device_uid"] != deviceUID {
		t.Fatalf("service_radar.device_uid = %#v, want %s", serviceRadar["device_uid"], deviceUID)
	}
	device, ok := event["device"].(map[string]any)
	if !ok {
		t.Fatalf("device missing or malformed: %#v", event["device"])
	}
	if device["uid"] != deviceUID {
		t.Fatalf("device.uid = %#v, want %s", device["uid"], deviceUID)
	}
}
