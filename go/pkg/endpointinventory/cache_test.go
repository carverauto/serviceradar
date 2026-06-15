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
	"testing"
	"time"
)

func TestCacheCanSkipFullScanRespectsForceFullScanInterval(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.ForceFullScanInterval = 2
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
	}

	if !cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache should skip before the forced full scan interval")
	}

	manifest.ScansSinceFull = 1
	if cacheCanSkipFullScan(cfg, manifest, current) {
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
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
		LastScanAt:     time.Now().Add(-5 * time.Minute),
	}

	// Scanned 5 minutes ago, cadence is 1h, sources unchanged: skip.
	if !cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache should skip when within the cadence floor and sources unchanged")
	}

	// A source mtime change must defeat the cadence floor even within the window.
	changed := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 99, Size: 21},
	}
	if cacheCanSkipFullScan(cfg, manifest, changed) {
		t.Fatal("cache must not skip within cadence when a source mtime changed")
	}

	// Outside the cadence window the floor no longer applies (and the interval
	// gate is disabled), so a fresh scan is required.
	manifest.LastScanAt = time.Now().Add(-2 * time.Hour)
	if cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache must not skip once the cadence window has elapsed")
	}
}

func TestCacheCanSkipFullScanForceFreshBypassesCadenceFloor(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.Cadence = "1h"
	cfg.ForceFreshScan = true
	current := map[string]SourceMTime{
		PackageSourceDpkg: {Source: PackageSourceDpkg, Path: "/var/lib/dpkg/status", Exists: true, MTimeUnixNano: 10, Size: 20},
	}
	manifest := &InventoryCacheManifest{
		PackageSetHash: "package-hash",
		ArtifactHash:   "artifact-hash",
		SourceMTimes:   copySourceMTimes(current),
		LastScanAt:     time.Now().Add(-1 * time.Minute),
	}

	if cacheCanSkipFullScan(cfg, manifest, current) {
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

	if cacheCanSkipFullScan(cfg, manifest, current) {
		t.Fatal("cache should not skip when the server requested a reconcile upload")
	}
}

func TestFullScanManifestClearsServerReconcileRequestOnChangedUpload(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = "agent-1"
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

	manifest := fullScanManifest(cfg, previous, payload, []Package{{Name: "nginx"}}, nil, scannedAt)

	if manifest.ServerReconcileRequestedAt != nil || manifest.ServerReconcileReason != "" {
		t.Fatalf("server reconcile request should clear after changed upload: %#v", manifest)
	}
}
