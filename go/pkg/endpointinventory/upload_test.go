package endpointinventory

import (
	"context"
	"errors"
	"testing"
	"time"
)

var errEndpointInventoryUploadTestGatewayUnavailable = errors.New("gateway unavailable")

func TestRunnerSchedulesPendingUploadWithoutReplacingUploadedHashes(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)
	cfg.UploadJitter = "10m"

	previousUpload := "old-package-hash"
	if err := WriteCacheManifest(cfg, &InventoryCacheManifest{
		SchemaVersion:              CacheVersion,
		AgentID:                    cfg.AgentID,
		PackageSetHash:             previousUpload,
		ArtifactHash:               "old-artifact-hash",
		LastUploadedPackageSetHash: previousUpload,
		LastUploadedArtifactHash:   "old-artifact-hash",
		SourceMTimes:               map[string]SourceMTime{},
		Packages:                   []Package{},
		SourceSummaries:            []SourceSummary{},
	}); err != nil {
		t.Fatal(err)
	}

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if payload.UploadReason != UploadReasonChanged {
		t.Fatalf("upload reason = %q, want changed", payload.UploadReason)
	}

	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.LastUploadedPackageSetHash != previousUpload {
		t.Fatalf("last uploaded hash = %q, want previous %q", manifest.LastUploadedPackageSetHash, previousUpload)
	}
	if manifest.PendingUpload == nil {
		t.Fatal("expected pending upload")
	}
	if manifest.PendingUpload.PackageSetHash != payload.PackageSetHash {
		t.Fatalf("pending package hash = %q, want %q", manifest.PendingUpload.PackageSetHash, payload.PackageSetHash)
	}
	if manifest.PendingUpload.AvailableAfter.Before(payload.LastScanAt) ||
		manifest.PendingUpload.AvailableAfter.After(payload.LastScanAt.Add(10*time.Minute)) {
		t.Fatalf("pending upload available_after outside jitter window: %#v", manifest.PendingUpload)
	}
}

func TestUploadRetryAndSuccessUpdatePendingState(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)
	cfg.UploadRetryInitial = "2m"
	cfg.UploadRetryMax = "5m"
	cfg.UploadRetryMaxAttempts = 2

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	failedAt := time.Unix(100, 0).UTC()
	if err := MarkUploadFailed(cfg, payload, failedAt, errEndpointInventoryUploadTestGatewayUnavailable); err != nil {
		t.Fatal(err)
	}
	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.LastUploadedPackageSetHash != "" {
		t.Fatalf("last uploaded hash = %q, want empty until success", manifest.LastUploadedPackageSetHash)
	}
	if manifest.PendingUpload == nil || manifest.PendingUpload.Attempts != 1 || manifest.PendingUpload.NextAttemptAt == nil {
		t.Fatalf("unexpected pending retry state: %#v", manifest.PendingUpload)
	}
	if got, want := *manifest.PendingUpload.NextAttemptAt, failedAt.Add(2*time.Minute); !got.Equal(want) {
		t.Fatalf("next attempt = %s, want %s", got, want)
	}

	if err := MarkUploadSucceeded(cfg, payload, failedAt.Add(3*time.Minute)); err != nil {
		t.Fatal(err)
	}
	manifest, err = ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.PendingUpload != nil {
		t.Fatalf("pending upload should be cleared: %#v", manifest.PendingUpload)
	}
	if manifest.LastUploadedPackageSetHash != payload.PackageSetHash ||
		manifest.LastUploadedArtifactHash != payload.ArtifactHash {
		t.Fatalf("uploaded hashes not recorded: %#v", manifest)
	}
}

func TestUploadRetryExhaustionSuppressesDueUpload(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)
	cfg.UploadRetryInitial = "1s"
	cfg.UploadRetryMax = "1s"
	cfg.UploadRetryMaxAttempts = 1

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	failedAt := time.Unix(100, 0).UTC()
	if err := MarkUploadFailed(cfg, payload, failedAt, errEndpointInventoryUploadTestGatewayUnavailable); err != nil {
		t.Fatal(err)
	}
	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !PendingUploadExhausted(cfg, manifest) || PendingUploadDue(cfg, manifest, failedAt.Add(time.Hour)) {
		t.Fatalf("expected exhausted pending upload not to become due: %#v", manifest.PendingUpload)
	}
}
