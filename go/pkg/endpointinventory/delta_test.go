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
	"context"
	"testing"
	"time"
)

const deltaTestPkgCurl = "curl"

func pkg(name, version string) Package {
	return Package{Name: name, Version: version, Arch: "amd64", Manager: PackageSourceDpkg}
}

func TestComputePackageSetDeltaAddRemoveChange(t *testing.T) {
	previous := []Package{
		pkg("bash", "5.1"),
		pkg(deltaTestPkgCurl, "7.80"),
		pkg("openssl", "3.0"),
	}
	current := []Package{
		pkg("bash", "5.1"),            // unchanged
		pkg(deltaTestPkgCurl, "7.81"), // changed (version bump)
		pkg("nginx", "1.24"),          // added
		// openssl removed
	}

	delta := ComputePackageSetDelta(previous, current, "base", "target")

	if delta.BasePackageSetHash != "base" || delta.TargetPackageSetHash != "target" {
		t.Fatalf("unexpected hashes: %#v", delta)
	}
	if len(delta.Added) != 1 || delta.Added[0].Name != "nginx" {
		t.Fatalf("added = %#v, want [nginx]", delta.Added)
	}
	if len(delta.Removed) != 1 || delta.Removed[0].Name != "openssl" {
		t.Fatalf("removed = %#v, want [openssl]", delta.Removed)
	}
	if len(delta.Changed) != 1 || delta.Changed[0].Name != deltaTestPkgCurl {
		t.Fatalf("changed = %#v, want [curl]", delta.Changed)
	}
	if delta.Changed[0].PreviousVersion != "7.80" || delta.Changed[0].Version != "7.81" {
		t.Fatalf("changed curl versions = %q -> %q", delta.Changed[0].PreviousVersion, delta.Changed[0].Version)
	}
}

func TestComputePackageSetDeltaNoChange(t *testing.T) {
	set := []Package{pkg("bash", "5.1"), pkg(deltaTestPkgCurl, "7.80")}
	delta := ComputePackageSetDelta(set, set, "h", "h")
	if !delta.IsEmpty() {
		t.Fatalf("expected empty delta for identical sets, got %#v", delta)
	}
}

func TestComputePackageSetDeltaIsDeterministic(t *testing.T) {
	previous := []Package{pkg("a", "1"), pkg("b", "1")}
	current := []Package{pkg("c", "1"), pkg("d", "1"), pkg("e", "1")}

	first := ComputePackageSetDelta(previous, current, "b", "t")
	second := ComputePackageSetDelta(previous, current, "b", "t")

	if len(first.Added) != len(second.Added) {
		t.Fatalf("added length mismatch")
	}
	for i := range first.Added {
		if first.Added[i].Name != second.Added[i].Name {
			t.Fatalf("added order not deterministic at %d: %q vs %q", i, first.Added[i].Name, second.Added[i].Name)
		}
	}
	// Added should be sorted by coordinate (c, d, e).
	if first.Added[0].Name != "c" || first.Added[2].Name != "e" {
		t.Fatalf("added not sorted by coordinate: %#v", first.Added)
	}
}

func TestComputePackageSetDeltaFromEmptyPrevious(t *testing.T) {
	current := []Package{pkg("bash", "5.1")}
	delta := ComputePackageSetDelta(nil, current, "", "target")
	if len(delta.Added) != 1 || len(delta.Removed) != 0 || len(delta.Changed) != 0 {
		t.Fatalf("expected single add from empty previous, got %#v", delta)
	}
}

func TestRunAttachesDeltaOnChangedScanWithPriorUploadedState(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	// Seed a prior uploaded manifest whose package set differs from the current
	// dpkg fixture (nginx) so the next scan registers as a change with a delta.
	priorPackages := []Package{
		{Name: deltaTestPkgCurl, Version: "7.80", Arch: "amd64", Manager: PackageSourceDpkg},
	}
	priorHash := ComputePackageSetHash(priorPackages)
	configHash := computeConfigHash(cfg)
	if err := WriteCacheManifest(cfg, &InventoryCacheManifest{
		SchemaVersion:              CacheVersion,
		AgentID:                    cfg.AgentID,
		ConfigHash:                 configHash,
		ProducerID:                 collectorName,
		ProducerVersion:            collectorVersion,
		PackageSetHash:             priorHash,
		ArtifactHash:               "prior-artifact",
		LastUploadedPackageSetHash: priorHash,
		LastUploadedArtifactHash:   "prior-artifact",
		Packages:                   priorPackages,
		SourceMTimes:               map[string]SourceMTime{},
		SourceSummaries:            []SourceSummary{},
		LastScanAt:                 time.Now().Add(-48 * time.Hour),
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
	if payload.PackageDelta == nil {
		t.Fatal("expected a package delta on a changed scan with prior uploaded state")
	}
	if payload.PackageDelta.BasePackageSetHash != priorHash {
		t.Fatalf("delta base hash = %q, want %q", payload.PackageDelta.BasePackageSetHash, priorHash)
	}
	if payload.PackageDelta.TargetPackageSetHash != payload.PackageSetHash {
		t.Fatalf("delta target hash %q != payload hash %q",
			payload.PackageDelta.TargetPackageSetHash, payload.PackageSetHash)
	}
	// curl removed, nginx added.
	if len(payload.PackageDelta.Removed) != 1 || payload.PackageDelta.Removed[0].Name != deltaTestPkgCurl {
		t.Fatalf("removed = %#v, want [curl]", payload.PackageDelta.Removed)
	}
	if len(payload.PackageDelta.Added) != 1 || payload.PackageDelta.Added[0].Name != "nginx" {
		t.Fatalf("added = %#v, want [nginx]", payload.PackageDelta.Added)
	}
	// The full SBOM anchor must still be present for resync fallback.
	if payload.SBOM == nil {
		t.Fatal("expected the full SBOM anchor alongside the delta")
	}
}

func TestRunOmitsDeltaWhenNoPriorUploadedState(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	// No cache manifest at all: first-ever scan must be a full anchor, no delta.
	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if payload.UploadReason != UploadReasonChanged {
		t.Fatalf("upload reason = %q, want changed", payload.UploadReason)
	}
	if payload.PackageDelta != nil {
		t.Fatalf("expected no delta on first-ever upload, got %#v", payload.PackageDelta)
	}
	if payload.SBOM == nil {
		t.Fatal("expected a full SBOM anchor on first-ever upload")
	}
}
