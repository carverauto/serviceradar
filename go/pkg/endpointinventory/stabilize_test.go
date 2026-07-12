/*
 * Copyright 2026 Carver Automation Corporation.
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

func uploadedUnchangedManifest() *InventoryCacheManifest {
	return &InventoryCacheManifest{
		SchemaVersion:              CacheVersion,
		AgentID:                    "agent-1",
		PackageSetHash:             "pkg-hash",
		ArtifactHash:               "art-hash",
		LastUploadedPackageSetHash: "pkg-hash",
		LastUploadedArtifactHash:   "art-hash",
		SourceMTimes:               map[string]SourceMTime{},
		Packages:                   []Package{},
		SourceSummaries:            []SourceSummary{},
	}
}

func unchangedScanPayload(scannedAt time.Time) *ScanPayload {
	return &ScanPayload{
		SchemaVersion:        SchemaVersion,
		AgentID:              "agent-1",
		ScanID:               "scan-volatile",
		State:                scanStateUnchanged,
		CoverageState:        coverageUnchanged,
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: &scannedAt,
		PackageCount:         315,
		PackageSetHash:       "pkg-hash",
		ArtifactHash:         "art-hash",
		HashAlgorithm:        HashAlgorithm,
		UploadReason:         UploadReasonUnchanged,
		DurationMillis:       42,
		Metadata: map[string]any{
			"reason":                 "cadence_not_due",
			"scans_since_full":       74,
			"scanner_activity":       map[string]any{"scan_id": "nested-volatile"},
			"scanner_findings":       []any{map[string]any{"scan_id": "nested-volatile"}},
			"scanner_findings_count": 1,
		},
	}
}

func TestIsUploadedUnchangedScan(t *testing.T) {
	manifest := uploadedUnchangedManifest()

	if !IsUploadedUnchangedScan(unchangedScanPayload(time.Now()), manifest) {
		t.Fatal("expected an already-uploaded unchanged scan to be recognized")
	}

	// A changed scan with an SBOM must still be uploaded.
	changed := unchangedScanPayload(time.Now())
	changed.UploadReason = UploadReasonChanged
	changed.SBOM = &CycloneDXBOM{BOMFormat: CycloneDXFormat, SpecVersion: CycloneDXSpecVersion, Version: 1}
	if IsUploadedUnchangedScan(changed, manifest) {
		t.Fatal("changed scan with SBOM must not be treated as uploaded-unchanged")
	}

	// A pending upload means the payload still needs to ship.
	pendingManifest := uploadedUnchangedManifest()
	pendingManifest.PendingUpload = &PendingUploadState{PackageSetHash: "pkg-hash"}
	if IsUploadedUnchangedScan(unchangedScanPayload(time.Now()), pendingManifest) {
		t.Fatal("payload with a pending upload must not be treated as uploaded-unchanged")
	}

	// A hash that does not match the last uploaded hash is genuinely new.
	staleManifest := uploadedUnchangedManifest()
	staleManifest.LastUploadedPackageSetHash = "different-hash"
	if IsUploadedUnchangedScan(unchangedScanPayload(time.Now()), staleManifest) {
		t.Fatal("payload whose hash differs from last uploaded must not be uploaded-unchanged")
	}
}

func TestStabilizeUnchangedScanPayloadIsDeterministic(t *testing.T) {
	first := unchangedScanPayload(time.Unix(1_000, 0).UTC())
	second := unchangedScanPayload(time.Unix(9_999, 0).UTC())
	second.ScanID = "scan-different"
	second.DurationMillis = 9999
	second.Metadata["scans_since_full"] = 999

	StabilizeUnchangedScanPayload(first)
	StabilizeUnchangedScanPayload(second)

	if first.ScanID != second.ScanID {
		t.Fatalf("scan ids diverge: %q vs %q", first.ScanID, second.ScanID)
	}
	if first.ScanID != StableUnchangedScanID("pkg-hash") {
		t.Fatalf("scan id = %q, want deterministic hash-derived id", first.ScanID)
	}
	if !first.LastScanAt.IsZero() || first.LastSuccessfulScanAt != nil || first.DurationMillis != 0 {
		t.Fatalf("volatile fields not cleared: %#v", first)
	}
	if first.UploadReason != UploadReasonUnchanged || first.SBOM != nil {
		t.Fatalf("unexpected upload reason/sbom: reason=%q sbom=%v", first.UploadReason, first.SBOM)
	}
	if _, ok := first.Metadata["scans_since_full"]; ok {
		t.Fatal("scans_since_full must be dropped")
	}
	for _, key := range []string{"scanner_activity", "scanner_findings", "scanner_findings_count"} {
		if _, ok := first.Metadata[key]; ok {
			t.Fatalf("%s must be dropped from cached wakeups", key)
		}
	}
	if first.PackageSetHash != "pkg-hash" || first.ArtifactHash != "art-hash" {
		t.Fatal("identity-bearing hashes must be preserved")
	}
	if first.PackageCount != 315 {
		t.Fatalf("package_count must be preserved, got %d", first.PackageCount)
	}
}

func TestShouldStabilizeUnchangedScanPreservesFullScanFreshness(t *testing.T) {
	payload := unchangedScanPayload(time.Unix(1_000, 0).UTC())
	payload.Metadata[MetadataReasonKey] = MetadataReasonFullScanHashUnchanged

	if ShouldStabilizeUnchangedScan(payload, uploadedUnchangedManifest()) {
		t.Fatal("completed full scan must retain its timestamp for one freshness update")
	}
}

func TestStableUnchangedScanIDStableAndDistinct(t *testing.T) {
	// Two separate calls with the same input must agree (kept in vars so the
	// determinism check isn't a syntactically-identical comparison).
	first := StableUnchangedScanID("a")
	again := StableUnchangedScanID("a")
	if first != again {
		t.Fatal("same hash must produce same scan id")
	}
	if StableUnchangedScanID("a") == StableUnchangedScanID("b") {
		t.Fatal("different hashes must produce different scan ids")
	}
	if got := StableUnchangedScanID(""); got != stableUnchangedScanIDPrefix+"unknown" {
		t.Fatalf("empty hash scan id = %q", got)
	}
}
