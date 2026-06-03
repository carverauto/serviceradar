package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

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

func TestEndpointInventorySpoolServiceDefersPendingUploadBeforeDue(t *testing.T) {
	tmpDir := t.TempDir()
	spoolDir := filepath.Join(tmpDir, "spool")
	cacheDir := filepath.Join(tmpDir, "cache")
	spoolPath := endpointinventory.LatestPath(spoolDir)
	cfg := endpointinventory.DefaultConfig()
	cfg.AgentID = endpointInventorySpoolTestAgentID
	cfg.SpoolDir = spoolDir
	cfg.CacheDir = cacheDir
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	payload := endpointInventoryFullUploadPayload(time.Now().UTC())

	if err := endpointinventory.WriteSpool(cfg, payload); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.WriteCacheManifest(cfg, &endpointinventory.InventoryCacheManifest{
		SchemaVersion: endpointinventory.CacheVersion,
		AgentID:       endpointInventorySpoolTestAgentID,
		PendingUpload: &endpointinventory.PendingUploadState{
			ScanID:         payload.ScanID,
			PackageSetHash: payload.PackageSetHash,
			ArtifactHash:   payload.ArtifactHash,
			UploadReason:   payload.UploadReason,
			AvailableAfter: time.Now().UTC().Add(time.Hour),
			CreatedAt:      time.Now().UTC(),
			UpdatedAt:      time.Now().UTC(),
		},
		SourceMTimes:    map[string]endpointinventory.SourceMTime{},
		Packages:        []endpointinventory.Package{},
		SourceSummaries: []endpointinventory.SourceSummary{},
	}); err != nil {
		t.Fatal(err)
	}

	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{
			SpoolPath: spoolPath,
			CacheDir:  cacheDir,
			TmpDir:    cfg.TmpDir,
		},
	)
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	var got map[string]any
	if err := json.Unmarshal(status.Message, &got); err != nil {
		t.Fatal(err)
	}
	if got["state"] != "upload_deferred" || got["sbom"] != nil {
		t.Fatalf("expected compact deferred payload, got %#v", got)
	}
}

func TestEndpointInventorySpoolServiceReturnsPendingUploadWhenDue(t *testing.T) {
	tmpDir := t.TempDir()
	spoolDir := filepath.Join(tmpDir, "spool")
	cacheDir := filepath.Join(tmpDir, "cache")
	cfg := endpointinventory.DefaultConfig()
	cfg.AgentID = endpointInventorySpoolTestAgentID
	cfg.SpoolDir = spoolDir
	cfg.CacheDir = cacheDir
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	payload := endpointInventoryFullUploadPayload(time.Now().UTC())

	if err := endpointinventory.WriteSpool(cfg, payload); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.WriteCacheManifest(cfg, &endpointinventory.InventoryCacheManifest{
		SchemaVersion: endpointinventory.CacheVersion,
		AgentID:       endpointInventorySpoolTestAgentID,
		PendingUpload: &endpointinventory.PendingUploadState{
			ScanID:         payload.ScanID,
			PackageSetHash: payload.PackageSetHash,
			ArtifactHash:   payload.ArtifactHash,
			UploadReason:   payload.UploadReason,
			AvailableAfter: time.Now().UTC().Add(-time.Second),
			CreatedAt:      time.Now().UTC().Add(-time.Minute),
			UpdatedAt:      time.Now().UTC().Add(-time.Minute),
		},
		SourceMTimes:    map[string]endpointinventory.SourceMTime{},
		Packages:        []endpointinventory.Package{},
		SourceSummaries: []endpointinventory.SourceSummary{},
	}); err != nil {
		t.Fatal(err)
	}

	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{
			SpoolPath: endpointinventory.LatestPath(spoolDir),
			CacheDir:  cacheDir,
			TmpDir:    cfg.TmpDir,
		},
	)
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	var got endpointinventory.ScanPayload
	if err := json.Unmarshal(status.Message, &got); err != nil {
		t.Fatal(err)
	}
	if got.SBOM == nil || got.UploadReason != endpointinventory.UploadReasonChanged {
		t.Fatalf("expected pending full upload, got %#v", got)
	}
}

func TestEndpointInventorySpoolServiceAttachesStandingQuestionCountsFromManifest(t *testing.T) {
	tmpDir := t.TempDir()
	spoolDir := filepath.Join(tmpDir, "spool")
	cacheDir := filepath.Join(tmpDir, "cache")
	cfg := endpointinventory.DefaultConfig()
	cfg.AgentID = endpointInventorySpoolTestAgentID
	cfg.SpoolDir = spoolDir
	cfg.CacheDir = cacheDir
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	payload := endpointInventoryFullUploadPayload(time.Now().UTC())
	payload.SBOM = nil
	payload.UploadReason = endpointinventory.UploadReasonUnchanged
	evaluatedAt := time.Unix(1_735_689_600, 0).UTC()

	if err := endpointinventory.WriteSpool(cfg, payload); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.WriteCacheManifest(cfg, &endpointinventory.InventoryCacheManifest{
		SchemaVersion:   endpointinventory.CacheVersion,
		AgentID:         endpointInventorySpoolTestAgentID,
		PackageSetHash:  payload.PackageSetHash,
		ArtifactHash:    payload.ArtifactHash,
		HashAlgorithm:   endpointinventory.HashAlgorithm,
		SourceMTimes:    map[string]endpointinventory.SourceMTime{},
		Packages:        []endpointinventory.Package{},
		SourceSummaries: []endpointinventory.SourceSummary{},
		StandingQuestionResultCounts: []endpointinventory.StandingQuestionResultCount{
			{
				QuestionID:     "nginx-installed",
				PredicateHash:  "sha256:predicate",
				Mode:           endpointinventory.QueryModeExists,
				Matched:        true,
				Count:          1,
				PackageSetHash: payload.PackageSetHash,
				HashAlgorithm:  endpointinventory.HashAlgorithm,
				EvaluatedAt:    evaluatedAt,
			},
		},
	}); err != nil {
		t.Fatal(err)
	}

	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{
			SpoolPath: endpointinventory.LatestPath(spoolDir),
			CacheDir:  cacheDir,
			TmpDir:    cfg.TmpDir,
		},
	)
	status, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	var got endpointinventory.ScanPayload
	if err := json.Unmarshal(status.Message, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.StandingQuestionResultCounts) != 1 {
		t.Fatalf("standing question counts = %#v, want one count", got.StandingQuestionResultCounts)
	}
	count := got.StandingQuestionResultCounts[0]
	if count.QuestionID != "nginx-installed" ||
		count.PredicateHash != "sha256:predicate" ||
		count.Mode != endpointinventory.QueryModeExists ||
		!count.Matched ||
		count.Count != 1 ||
		!count.EvaluatedAt.Equal(evaluatedAt) {
		t.Fatalf("unexpected standing question count: %#v", count)
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

func endpointInventoryFullUploadPayload(scannedAt time.Time) *endpointinventory.ScanPayload {
	return &endpointinventory.ScanPayload{
		SchemaVersion:        endpointinventory.SchemaVersion,
		AgentID:              "agent-original",
		ScanID:               "scan-1",
		State:                "scanned",
		CoverageState:        "complete",
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: &scannedAt,
		Sources:              []endpointinventory.SourceSummary{},
		PackageCount:         1,
		PackageSetHash:       "package-hash",
		ArtifactHash:         "artifact-hash",
		HashAlgorithm:        endpointinventory.HashAlgorithm,
		UploadReason:         endpointinventory.UploadReasonChanged,
		SBOM: &endpointinventory.CycloneDXBOM{
			BOMFormat:   endpointinventory.CycloneDXFormat,
			SpecVersion: endpointinventory.CycloneDXSpecVersion,
			Version:     1,
		},
	}
}
