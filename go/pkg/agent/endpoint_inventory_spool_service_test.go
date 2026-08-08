package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
)

const (
	endpointInventorySpoolTestAgentID         = "agent-1"
	endpointInventorySpoolTestConfigHash      = "config-hash"
	endpointInventorySpoolTestProducerID      = "serviceradar.scalibr.endpoint_inventory"
	endpointInventorySpoolTestProducerVersion = "0.1.2"
)

func TestEndpointInventorySpoolServiceMissingSpoolReturnsNotScanned(t *testing.T) {
	tmpDir := t.TempDir()
	spoolPath := filepath.Join(tmpDir, "missing.json")
	service := NewEndpointInventorySpoolService(
		endpointInventorySpoolTestAgentID,
		&EndpointInventoryStatusConfig{
			SpoolPath: spoolPath,
			CacheDir:  filepath.Join(tmpDir, "cache"),
			TmpDir:    filepath.Join(tmpDir, "tmp"),
		},
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
		SchemaVersion:   endpointinventory.CacheVersion,
		AgentID:         endpointInventorySpoolTestAgentID,
		ConfigHash:      endpointInventorySpoolTestConfigHash,
		ProducerID:      endpointInventorySpoolTestProducerID,
		ProducerVersion: endpointInventorySpoolTestProducerVersion,
		PendingUpload:   endpointInventoryPendingState(payload, time.Now().UTC().Add(time.Hour)),
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
		SchemaVersion:   endpointinventory.CacheVersion,
		AgentID:         endpointInventorySpoolTestAgentID,
		ConfigHash:      endpointInventorySpoolTestConfigHash,
		ProducerID:      endpointInventorySpoolTestProducerID,
		ProducerVersion: endpointInventorySpoolTestProducerVersion,
		PendingUpload:   endpointInventoryPendingState(payload, time.Now().UTC().Add(-time.Second)),
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

func TestEndpointInventorySpoolServiceRejectsMissingOrMismatchedPendingPayload(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(t *testing.T, cfg endpointinventory.Config)
	}{
		{
			name: "missing",
			mutate: func(t *testing.T, cfg endpointinventory.Config) {
				t.Helper()
				if err := os.Remove(endpointinventory.PendingUploadPath(cfg.SpoolDir)); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "mismatched",
			mutate: func(t *testing.T, cfg endpointinventory.Config) {
				t.Helper()
				mismatch := endpointInventoryFullUploadPayload(time.Now().UTC())
				mismatch.ScanID = "different-scan"
				data, err := json.Marshal(mismatch)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(endpointinventory.PendingUploadPath(cfg.SpoolDir), data, 0640); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			cfg := endpointinventory.DefaultConfig()
			cfg.AgentID = endpointInventorySpoolTestAgentID
			cfg.SpoolDir = filepath.Join(root, "spool")
			cfg.CacheDir = filepath.Join(root, "cache")
			cfg.TmpDir = filepath.Join(root, "tmp")
			payload := endpointInventoryFullUploadPayload(time.Now().UTC())
			if err := endpointinventory.WriteSpool(cfg, payload); err != nil {
				t.Fatal(err)
			}
			if err := endpointinventory.WriteCacheManifest(cfg, &endpointinventory.InventoryCacheManifest{
				SchemaVersion: endpointinventory.CacheVersion, AgentID: payload.AgentID,
				ConfigHash: payload.ConfigHash, ProducerID: endpointInventorySpoolTestProducerID,
				ProducerVersion: payload.CollectorVersion,
				PendingUpload:   endpointInventoryPendingState(payload, time.Now().UTC().Add(-time.Minute)),
				Packages:        []endpointinventory.Package{}, SourceSummaries: []endpointinventory.SourceSummary{},
				SourceMTimes: map[string]endpointinventory.SourceMTime{},
			}); err != nil {
				t.Fatal(err)
			}
			test.mutate(t, cfg)

			service := NewEndpointInventorySpoolService(payload.AgentID, &EndpointInventoryStatusConfig{
				SpoolPath: endpointinventory.LatestPath(cfg.SpoolDir), CacheDir: cfg.CacheDir, TmpDir: cfg.TmpDir,
			})
			_, err := service.GetStatus(context.Background())
			if !errors.Is(err, endpointinventory.ErrPendingUploadUnavailable) {
				t.Fatalf("status error = %v, want ErrPendingUploadUnavailable", err)
			}
		})
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
		&EndpointInventoryStatusConfig{
			SpoolPath: spoolPath,
			CacheDir:  filepath.Join(tmpDir, "cache"),
			TmpDir:    filepath.Join(tmpDir, "tmp"),
		},
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

// TestEndpointInventorySpoolPayloadCapDefaultsToTransportLimit pins the tunable to the
// real transport constant. shrinkEndpointInventorySpoolPayloadCap lets tests move it, so
// without this a wrong default would ship and every cap test would still pass.
func TestEndpointInventorySpoolPayloadCapDefaultsToTransportLimit(t *testing.T) {
	if endpointInventorySpoolPayloadCap != endpointinventory.MaxSpoolPayloadBytes {
		t.Fatalf("production cap = %d, want %d",
			endpointInventorySpoolPayloadCap, endpointinventory.MaxSpoolPayloadBytes)
	}
}

// shrinkEndpointInventorySpoolPayloadCap lowers the status-transport size budget for the
// duration of one test. Building a fixture at the real 32 MiB cap costs two marshals of a
// 32 MiB document plus a disk round trip, which under -race was 5.75s -- 20% of this
// package's entire test runtime for one assertion about a size comparison.
func shrinkEndpointInventorySpoolPayloadCap(t *testing.T, limit int64) {
	t.Helper()

	orig := endpointInventorySpoolPayloadCap
	endpointInventorySpoolPayloadCap = limit
	t.Cleanup(func() { endpointInventorySpoolPayloadCap = orig })
}

func TestEndpointInventorySpoolServiceEnforcesCapAfterAgentIDMutation(t *testing.T) {
	const capBytes = int64(8192)

	shrinkEndpointInventorySpoolPayloadCap(t, capBytes)

	root := t.TempDir()
	spoolPath := filepath.Join(root, "latest.json")
	payload := map[string]any{
		"agent_id":       "x",
		"schema_version": endpointinventory.SchemaVersion,
		"scan_id":        "scan-size-cap",
		"state":          "not_scanned",
		"coverage_state": "not_scanned",
		"metadata":       map[string]any{"padding": ""},
	}
	padding := strings.Repeat("p", int(capBytes)-1024)
	payload["metadata"].(map[string]any)["padding"] = padding
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	remaining := int(capBytes) - len(raw)
	if remaining < 0 {
		t.Fatalf("test fixture exceeded cap before final mutation: %d", len(raw))
	}
	payload["metadata"].(map[string]any)["padding"] = padding + strings.Repeat("p", remaining)
	raw, err = json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(raw)) != capBytes {
		t.Fatalf("fixture size = %d, want %d", len(raw), capBytes)
	}
	if err := os.WriteFile(spoolPath, raw, 0600); err != nil {
		t.Fatal(err)
	}

	service := NewEndpointInventorySpoolService(
		strings.Repeat("agent", 1024),
		&EndpointInventoryStatusConfig{
			SpoolPath: spoolPath,
			CacheDir:  filepath.Join(root, "cache"),
			TmpDir:    filepath.Join(root, "tmp"),
		},
	)
	_, err = service.GetStatus(context.Background())
	if !errors.Is(err, errEndpointInventorySpoolTooLarge) {
		t.Fatalf("status error = %v, want errEndpointInventorySpoolTooLarge", err)
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
		ConfigHash:                 endpointInventorySpoolTestConfigHash,
		ProducerID:                 endpointInventorySpoolTestProducerID,
		ProducerVersion:            endpointInventorySpoolTestProducerVersion,
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
	firstPayload.CoverageState = "unchanged"
	firstPayload.Metadata = map[string]any{
		"reason":              "cadence_not_due",
		"scanner_activity":    map[string]any{"scan_id": "nested-first", "started_at": firstScanAt},
		"scanner_producer_id": endpointInventorySpoolTestProducerID,
	}
	manifest.LastScanAt = firstScanAt
	if err := endpointinventory.WriteCacheManifest(cfg, manifest); err != nil {
		t.Fatal(err)
	}
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
	secondPayload.CoverageState = "unchanged"
	secondPayload.Metadata = map[string]any{
		"reason":              "cadence_not_due",
		"scanner_activity":    map[string]any{"scan_id": "nested-second", "started_at": secondScanAt},
		"scanner_producer_id": endpointInventorySpoolTestProducerID,
	}
	manifest.LastScanAt = secondScanAt
	if err := endpointinventory.WriteCacheManifest(cfg, manifest); err != nil {
		t.Fatal(err)
	}
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

func TestSuppressEndpointInventoryUploadedSBOMRequiresHashProof(t *testing.T) {
	payload := endpointInventoryFullUploadPayload(time.Unix(1_000, 0).UTC())
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	assertFullUpload := func(name string, got []byte) {
		t.Helper()
		var decoded endpointinventory.ScanPayload
		if err := json.Unmarshal(got, &decoded); err != nil {
			t.Fatalf("%s: decode payload: %v", name, err)
		}
		if decoded.SBOM == nil || decoded.UploadReason != endpointinventory.UploadReasonChanged {
			t.Fatalf("%s: unacknowledged full upload was suppressed: %#v", name, decoded)
		}
	}

	assertFullUpload("missing manifest", suppressEndpointInventoryUploadedSBOM(data, nil))
	assertFullUpload("mismatched hashes", suppressEndpointInventoryUploadedSBOM(data, &endpointinventory.InventoryCacheManifest{
		LastUploadedPackageSetHash: "older-package-hash",
		LastUploadedArtifactHash:   "older-artifact-hash",
	}))

	got := suppressEndpointInventoryUploadedSBOM(data, &endpointinventory.InventoryCacheManifest{
		LastUploadedPackageSetHash: payload.PackageSetHash,
		LastUploadedArtifactHash:   payload.ArtifactHash,
	})
	var decoded endpointinventory.ScanPayload
	if err := json.Unmarshal(got, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.SBOM != nil || decoded.UploadReason != endpointinventory.UploadReasonUnchanged {
		t.Fatalf("acknowledged upload was not compacted: %#v", decoded)
	}
}

func TestStabilizeEndpointInventoryUnchangedStatusPreservesFullScanFreshness(t *testing.T) {
	scannedAt := time.Unix(1_000, 0).UTC()
	payload := endpointInventoryFullUploadPayload(scannedAt)
	payload.SBOM = nil
	payload.UploadReason = endpointinventory.UploadReasonUnchanged
	payload.Metadata = map[string]any{
		endpointinventory.MetadataReasonKey: endpointinventory.MetadataReasonFullScanHashUnchanged,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	manifest := &endpointinventory.InventoryCacheManifest{
		LastUploadedPackageSetHash: payload.PackageSetHash,
		LastUploadedArtifactHash:   payload.ArtifactHash,
	}

	got := stabilizeEndpointInventoryUnchangedStatus(data, manifest)
	var decoded endpointinventory.ScanPayload
	if err := json.Unmarshal(got, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ScanID != payload.ScanID || !decoded.LastScanAt.Equal(scannedAt) {
		t.Fatalf("completed full scan freshness was stabilized away: %#v", decoded)
	}
}

func endpointInventoryFullUploadPayload(scannedAt time.Time) *endpointinventory.ScanPayload {
	return &endpointinventory.ScanPayload{
		SchemaVersion:        endpointinventory.SchemaVersion,
		AgentID:              endpointInventorySpoolTestAgentID,
		ConfigHash:           endpointInventorySpoolTestConfigHash,
		CollectorVersion:     endpointInventorySpoolTestProducerVersion,
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
		Metadata: map[string]any{
			"scanner_producer_id": endpointInventorySpoolTestProducerID,
		},
		SBOM: &endpointinventory.CycloneDXBOM{
			BOMFormat:   endpointinventory.CycloneDXFormat,
			SpecVersion: endpointinventory.CycloneDXSpecVersion,
			Version:     1,
		},
	}
}

func endpointInventoryPendingState(
	payload *endpointinventory.ScanPayload,
	availableAfter time.Time,
) *endpointinventory.PendingUploadState {
	now := time.Now().UTC()
	return &endpointinventory.PendingUploadState{
		ScanID:          payload.ScanID,
		AgentID:         payload.AgentID,
		ConfigHash:      payload.ConfigHash,
		ProducerID:      endpointInventorySpoolTestProducerID,
		ProducerVersion: payload.CollectorVersion,
		PackageSetHash:  payload.PackageSetHash,
		ArtifactHash:    payload.ArtifactHash,
		UploadReason:    payload.UploadReason,
		AvailableAfter:  availableAfter,
		CreatedAt:       now,
		UpdatedAt:       now,
	}
}
