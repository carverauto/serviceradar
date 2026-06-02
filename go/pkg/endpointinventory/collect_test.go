package endpointinventory

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const endpointInventoryTestAgentID = "agent-1"

func TestRunnerBuildsCycloneDXFromFixturePackages(t *testing.T) {
	tmpDir := t.TempDir()
	osReleasePath := filepath.Join(tmpDir, "os-release")
	dpkgPath := filepath.Join(tmpDir, "status")

	if err := os.WriteFile(osReleasePath, []byte(`NAME="Ubuntu"
ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dpkgPath, []byte(`Package: nginx
Status: install ok installed
Architecture: amd64
Version: 1.24.0-2ubuntu7
`), 0600); err != nil {
		t.Fatal(err)
	}

	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Sources = []string{"dpkg"}
	cfg.OSReleasePath = osReleasePath
	cfg.DpkgStatusPath = dpkgPath
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.CacheDir = filepath.Join(tmpDir, "cache")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != "scanned" || payload.CoverageState != "complete" {
		t.Fatalf("unexpected state: %s/%s", payload.State, payload.CoverageState)
	}
	if payload.PackageCount != 1 {
		t.Fatalf("PackageCount = %d, want 1", payload.PackageCount)
	}
	if payload.SBOM == nil || payload.OS.ID != "ubuntu" || payload.SBOM.BOMFormat != CycloneDXFormat {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if len(payload.SBOM.Components) != 1 || payload.SBOM.Components[0].PURL != "pkg:deb/nginx@1.24.0-2ubuntu7" {
		t.Fatalf("unexpected components: %#v", payload.SBOM.Components)
	}
}

func TestRunnerUsesCacheForUnchangedSourceMTimes(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	firstPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if firstPayload.UploadReason != UploadReasonChanged || firstPayload.SBOM == nil {
		t.Fatalf("first payload should be full changed upload: %#v", firstPayload)
	}
	if err := MarkUploadSucceeded(cfg, firstPayload, time.Unix(11, 0).UTC()); err != nil {
		t.Fatal(err)
	}

	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if manifest == nil ||
		manifest.PackageSetHash != firstPayload.PackageSetHash ||
		manifest.LastUploadedPackageSetHash != firstPayload.PackageSetHash {
		t.Fatalf("unexpected cache manifest: %#v", manifest)
	}

	secondPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if secondPayload.State != scanStateUnchanged || secondPayload.UploadReason != UploadReasonUnchanged {
		t.Fatalf("second payload should be unchanged: %#v", secondPayload)
	}
	if secondPayload.SBOM != nil {
		t.Fatalf("unchanged payload should not include full SBOM: %#v", secondPayload.SBOM)
	}
	if secondPayload.PackageSetHash != firstPayload.PackageSetHash || secondPayload.ArtifactHash != firstPayload.ArtifactHash {
		t.Fatalf("unchanged payload hash mismatch: %#v", secondPayload)
	}
}

func TestRunnerForcesFullUploadAfterServerReconcileRequest(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	firstPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := MarkUploadSucceeded(cfg, firstPayload, time.Unix(11, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	if err := MarkServerReconcileRequested(cfg, time.Unix(12, 0).UTC(), "reconcile floor"); err != nil {
		t.Fatal(err)
	}

	secondPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if secondPayload.UploadReason != UploadReasonChanged || secondPayload.SBOM == nil {
		t.Fatalf("server reconcile should force full changed upload: %#v", secondPayload)
	}
	if secondPayload.PackageSetHash != firstPayload.PackageSetHash ||
		secondPayload.ArtifactHash != firstPayload.ArtifactHash {
		t.Fatalf("reconcile upload should preserve unchanged hashes: %#v", secondPayload)
	}
	if secondPayload.Metadata["reason"] != "server_reconcile_floor" {
		t.Fatalf("metadata reason = %#v, want server_reconcile_floor", secondPayload.Metadata["reason"])
	}
}

func TestRunnerReparsesWhenSourceMTimeChanges(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	firstPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := MarkUploadSucceeded(cfg, firstPayload, time.Unix(11, 0).UTC()); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(dpkgPath, []byte(`Package: nginx
Status: install ok installed
Architecture: amd64
Version: 1.25.0-1
`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dpkgPath, time.Unix(20, 0), time.Unix(20, 0)); err != nil {
		t.Fatal(err)
	}

	secondPayload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if secondPayload.UploadReason != UploadReasonChanged || secondPayload.SBOM == nil {
		t.Fatalf("mtime change should force full changed upload: %#v", secondPayload)
	}
	if secondPayload.PackageSetHash == firstPayload.PackageSetHash {
		t.Fatalf("package hash should change after version update: %s", secondPayload.PackageSetHash)
	}
}

func TestBuildCycloneDXIncludesAgentAndOSProperties(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	bom := BuildCycloneDX(cfg, time.Unix(10, 0).UTC(), OSInfo{ID: "debian", VersionID: "12"}, []Package{{
		Name:      "openssl",
		Version:   "3.0.0",
		Arch:      "amd64",
		Manager:   "dpkg",
		Ecosystem: "deb",
		PURL:      "pkg:deb/openssl@3.0.0",
	}})

	if bom.BOMFormat != "CycloneDX" || bom.SpecVersion != "1.6" {
		t.Fatalf("unexpected bom identifiers: %#v", bom)
	}
	if len(bom.Components) != 1 || bom.Components[0].Name != "openssl" {
		t.Fatalf("unexpected components: %#v", bom.Components)
	}
	if len(bom.Metadata.Properties) < 3 {
		t.Fatalf("expected metadata properties, got %#v", bom.Metadata.Properties)
	}
}

func writeEndpointInventoryFixture(t *testing.T, tmpDir string) string {
	t.Helper()

	osReleasePath := filepath.Join(tmpDir, "os-release")
	if err := os.WriteFile(osReleasePath, []byte(`NAME="Ubuntu"
ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
`), 0600); err != nil {
		t.Fatal(err)
	}

	dpkgPath := filepath.Join(tmpDir, "status")
	if err := os.WriteFile(dpkgPath, []byte(`Package: nginx
Status: install ok installed
Architecture: amd64
Version: 1.24.0-2ubuntu7
`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dpkgPath, time.Unix(10, 0), time.Unix(10, 0)); err != nil {
		t.Fatal(err)
	}

	return dpkgPath
}

func testEndpointInventoryConfig(tmpDir string, dpkgPath string) Config {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Sources = []string{PackageSourceDpkg}
	cfg.OSReleasePath = filepath.Join(tmpDir, "os-release")
	cfg.DpkgStatusPath = dpkgPath
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.CacheDir = filepath.Join(tmpDir, "cache")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.ForceFullScanInterval = 24

	return cfg
}
