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

func TestEndpointInventorySpoolServiceStabilizesAcknowledgedUnchangedStatus(t *testing.T) {
	tmpDir := t.TempDir()
	spoolDir := filepath.Join(tmpDir, "spool")
	cacheDir := filepath.Join(tmpDir, "cache")
	cfg := endpointinventory.DefaultConfig()
	cfg.AgentID = endpointInventorySpoolTestAgentID
	cfg.SpoolDir = spoolDir
	cfg.CacheDir = cacheDir
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")

	manifest := &endpointinventory.InventoryCacheManifest{
		SchemaVersion:              endpointinventory.CacheVersion,
		AgentID:                    endpointInventorySpoolTestAgentID,
		PackageSetHash:             "package-hash",
		ArtifactHash:               "artifact-hash",
		LastUploadedPackageSetHash: "package-hash",
		LastUploadedArtifactHash:   "artifact-hash",
		HashAlgorithm:              endpointinventory.HashAlgorithm,
		SourceMTimes:               map[string]endpointinventory.SourceMTime{},
		Packages:                   []endpointinventory.Package{},
		SourceSummaries:            []endpointinventory.SourceSummary{},
	}
	if err := endpointinventory.WriteCacheManifest(cfg, manifest); err != nil {
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

	// Two successive unchanged scans (distinct scan_id + timestamps) must yield
	// byte-identical status messages so the push-loop signature dedup suppresses
	// the second push.
	firstScanAt := time.Unix(1_000, 0).UTC()
	firstPayload := endpointInventoryFullUploadPayload(firstScanAt)
	firstPayload.ScanID = "scan-first"
	firstPayload.SBOM = nil
	firstPayload.UploadReason = endpointinventory.UploadReasonUnchanged
	if err := endpointinventory.WriteSpool(cfg, firstPayload); err != nil {
		t.Fatal(err)
	}
	firstStatus, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	secondScanAt := time.Unix(9_999, 0).UTC()
	secondPayload := endpointInventoryFullUploadPayload(secondScanAt)
	secondPayload.ScanID = "scan-second"
	secondPayload.SBOM = nil
	secondPayload.UploadReason = endpointinventory.UploadReasonUnchanged
	if err := endpointinventory.WriteSpool(cfg, secondPayload); err != nil {
		t.Fatal(err)
	}
	secondStatus, err := service.GetStatus(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if string(firstStatus.Message) != string(secondStatus.Message) {
		t.Fatalf("expected stable unchanged status across scans:\nfirst=%s\nsecond=%s",
			firstStatus.Message, secondStatus.Message)
	}

	var got endpointinventory.ScanPayload
	if err := json.Unmarshal(secondStatus.Message, &got); err != nil {
		t.Fatal(err)
	}
	if got.ScanID != endpointinventory.StableUnchangedScanID("package-hash") {
		t.Fatalf("scan_id = %q, want deterministic id", got.ScanID)
	}
	if got.UploadReason != endpointinventory.UploadReasonUnchanged || got.SBOM != nil {
		t.Fatalf("unexpected payload: reason=%q sbom=%v", got.UploadReason, got.SBOM)
	}
	if !got.LastScanAt.IsZero() || got.LastSuccessfulScanAt != nil {
		t.Fatalf("volatile timestamps must be cleared: %#v", got)
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
		Diagnostics:          []endpointinventory.SourceSummary{},
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
