/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package endpointinventory

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCacheCanSkipFullScanRespectsForceFullScanInterval(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.Cadence = "invalid"
	cfg.ForceFullScanInterval = 2
	now := time.Unix(1_000, 0).UTC()
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
	}

	if !cacheCanSkipFullScanForTest(cfg, manifest, current, now) {
		t.Fatal("cache should skip before the forced full scan interval")
	}

	manifest.ScansSinceFull = 1
	if cacheCanSkipFullScanForTest(cfg, manifest, current, now) {
		t.Fatal("cache should not skip at the forced full scan interval")
	}
}

func TestCacheCanSkipFullScanRespectsCadenceFloor(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.Cadence = "1h"
	// Disable the older interval gate so we isolate the cadence floor.
	cfg.ForceFullScanInterval = 1
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	lastFullScanAt := time.Unix(10_000, 0).UTC()
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
		LastScanAt:     lastFullScanAt,
		LastFullScanAt: &lastFullScanAt,
	}
	now := lastFullScanAt.Add(5 * time.Minute)

	// Scanned 5 minutes ago, cadence is 1h, sources unchanged: skip.
	if !cacheCanSkipFullScanForTest(cfg, manifest, current, now) {
		t.Fatal("cache should skip when within the cadence floor and sources unchanged")
	}

	// A source mtime change must defeat the cadence floor even within the window.
	changed := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 99, Size: 21},
	}
	if cacheCanSkipFullScanForTest(cfg, manifest, changed, now) {
		t.Fatal("cache must not skip within cadence when a source mtime changed")
	}

	// Outside the cadence window the floor no longer applies (and the interval
	// gate is disabled), so a fresh scan is required.
	if cacheCanSkipFullScanForTest(cfg, manifest, current, lastFullScanAt.Add(2*time.Hour)) {
		t.Fatal("cache must not skip once the cadence window has elapsed")
	}
}

func TestCacheCanSkipFullScanForceFreshBypassesCadenceFloor(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.Cadence = "1h"
	cfg.ForceFreshScan = true
	now := time.Unix(10_000, 0).UTC()
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
		LastScanAt:     now.Add(-time.Minute),
	}

	if cacheCanSkipFullScanForTest(cfg, manifest, current, now) {
		t.Fatal("force-fresh scan must never skip the full collection")
	}
}

func TestCacheCanSkipFullScanRespectsServerReconcileRequest(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.ForceFullScanInterval = 24
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	requestedAt := time.Unix(100, 0).UTC()
	manifest := &InventoryCacheManifest{
		PackageSetHash:             "package-hash",
		ArtifactHash:               "artifact-hash",
		LastUploadedPackageSetHash: "package-hash",
		LastUploadedArtifactHash:   "artifact-hash",
		SourceMTimes:               copySourceMTimes(current),
		ServerReconcileRequestedAt: &requestedAt,
	}

	if cacheCanSkipFullScanForTest(cfg, manifest, current, requestedAt) {
		t.Fatal("cache should not skip when the server requested a reconcile upload")
	}
}

func TestCacheCanSkipFullScanWhileReconcileAnchorAwaitsAck(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	identity := testCacheIdentity(cfg)
	now := time.Unix(1_000, 0).UTC()
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Exists: true, MTimeUnixNano: 10},
	}
	requestedAt := now.Add(-time.Minute)
	manifest := &InventoryCacheManifest{
		PackageSetHash:             "package-hash",
		ArtifactHash:               "artifact-hash",
		SourceMTimes:               copySourceMTimes(current),
		LastFullScanAt:             &now,
		ServerReconcileRequestedAt: &requestedAt,
		PendingUpload: &PendingUploadState{
			ScanID:          "scan-reconcile",
			AgentID:         identity.AgentID,
			ConfigHash:      identity.ConfigHash,
			ProducerID:      identity.ProducerID,
			ProducerVersion: identity.ProducerVersion,
			PackageSetHash:  "package-hash",
			ArtifactHash:    "artifact-hash",
		},
	}
	if err := WriteSpool(cfg, &ScanPayload{
		AgentID:          identity.AgentID,
		ConfigHash:       identity.ConfigHash,
		CollectorVersion: identity.ProducerVersion,
		ScanID:           "scan-reconcile",
		State:            scanStateScanned,
		CoverageState:    coverageComplete,
		PackageSetHash:   "package-hash",
		ArtifactHash:     "artifact-hash",
		UploadReason:     UploadReasonChanged,
		SBOM:             &CycloneDXBOM{},
		Metadata: map[string]any{
			"scanner_producer_id": identity.ProducerID,
		},
	}); err != nil {
		t.Fatal(err)
	}

	if !cacheCanSkipFullScanForTest(cfg, manifest, current, now.Add(time.Hour)) {
		t.Fatal("pending reconcile anchor should suppress duplicate full scans until acknowledgement")
	}
}

func TestCacheCanSkipFullScanRecoversInterruptedPendingSpoolWrite(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.Cadence = endpointInventoryTestDaily
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	cfg.UploadJitter = "0s"
	now := time.Unix(1_000, 0).UTC()
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Exists: true, MTimeUnixNano: 10},
	}
	newPayload := func(scanID string, scannedAt time.Time) *ScanPayload {
		return &ScanPayload{
			SchemaVersion:  SchemaVersion,
			AgentID:        cfg.AgentID,
			ScanID:         scanID,
			State:          scanStateScanned,
			CoverageState:  coverageComplete,
			LastScanAt:     scannedAt,
			PackageCount:   1,
			PackageSetHash: "package-hash",
			ArtifactHash:   "artifact-hash",
			HashAlgorithm:  HashAlgorithm,
			UploadReason:   UploadReasonChanged,
			SBOM:           &CycloneDXBOM{},
		}
	}
	packages := []Package{{Name: "openssl", Version: "3.0.2"}}

	first := newPayload("scan-interrupted", now)
	if err := finalizeFullScanForTest(cfg, nil, first, packages, current, now); err != nil {
		t.Fatal(err)
	}
	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest == nil || manifest.PendingUpload == nil {
		t.Fatalf("full scan did not persist pending state: %#v", manifest)
	}
	if err := os.Remove(PendingUploadPath(cfg.SpoolDir)); err != nil {
		t.Fatal(err)
	}
	if cacheCanSkipFullScanForTest(cfg, manifest, current, now.Add(time.Hour)) {
		t.Fatal("missing pending spool must force a replacement full scan")
	}

	retryAt := now.Add(time.Hour)
	retry := newPayload("scan-retry", retryAt)
	if err := finalizeFullScanForTest(cfg, manifest, retry, packages, current, retryAt); err != nil {
		t.Fatal(err)
	}
	if err := WriteSpool(cfg, retry); err != nil {
		t.Fatal(err)
	}
	manifest, err = ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.PendingUpload == nil || manifest.PendingUpload.ScanID != retry.ScanID {
		t.Fatalf("replacement scan did not refresh pending identity: %#v", manifest.PendingUpload)
	}
	if !cacheCanSkipFullScanForTest(cfg, manifest, current, retryAt.Add(time.Hour)) {
		t.Fatal("matching pending spool should suppress duplicate full scans while awaiting acknowledgement")
	}
}

func TestFullScanManifestRetainsServerReconcileRequestUntilUploadAck(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	requestedAt := time.Unix(100, 0).UTC()
	scannedAt := time.Unix(120, 0).UTC()
	previous := &InventoryCacheManifest{
		ServerReconcileRequestedAt: &requestedAt,
		ServerReconcileReason:      "reconcile floor",
	}
	payload := &ScanPayload{
		ScanID:               "scan-1",
		PackageSetHash:       "package-hash",
		ArtifactHash:         "artifact-hash",
		HashAlgorithm:        HashAlgorithm,
		PackageCount:         1,
		LastSuccessfulScanAt: &scannedAt,
		UploadReason:         UploadReasonChanged,
	}

	manifest := fullScanManifest(cfg, testCacheIdentity(cfg), previous, payload, []Package{{Name: "nginx"}}, nil, scannedAt)

	if manifest.ServerReconcileRequestedAt == nil ||
		!manifest.ServerReconcileRequestedAt.Equal(requestedAt) ||
		manifest.ServerReconcileReason != "reconcile floor" {
		t.Fatalf("server reconcile request must remain until upload acknowledgement: %#v", manifest)
	}
}

func testCacheIdentity(cfg Config) CacheIdentity {
	return CacheIdentity{
		AgentID:         firstNonEmptyForCacheTest(cfg.AgentID, endpointInventoryTestAgentID),
		ConfigHash:      "test-config-hash",
		ProducerID:      "test-producer",
		ProducerVersion: "test-version",
	}
}

func cacheCanSkipFullScanForTest(
	cfg Config,
	manifest *InventoryCacheManifest,
	current map[string]SourceMTime,
	now time.Time,
) bool {
	identity := testCacheIdentity(cfg)
	if manifest != nil {
		manifest.AgentID = identity.AgentID
		manifest.ConfigHash = identity.ConfigHash
		manifest.ProducerID = identity.ProducerID
		manifest.ProducerVersion = identity.ProducerVersion
	}

	return CacheCanSkipFullScan(cfg, identity, manifest, current, now)
}

func finalizeFullScanForTest(
	cfg Config,
	_ *InventoryCacheManifest,
	payload *ScanPayload,
	packages []Package,
	current map[string]SourceMTime,
	scannedAt time.Time,
) error {
	identity := testCacheIdentity(cfg)
	payload.AgentID = identity.AgentID
	payload.ConfigHash = identity.ConfigHash
	if payload.Metadata == nil {
		payload.Metadata = map[string]any{}
	}
	payload.Metadata["scanner_producer_id"] = identity.ProducerID
	payload.CollectorVersion = identity.ProducerVersion

	return FinalizeFullScan(cfg, identity, payload, packages, current, scannedAt)
}

func firstNonEmptyForCacheTest(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}

	return "test-agent"
}
