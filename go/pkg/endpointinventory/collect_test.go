package endpointinventory

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

const (
	endpointInventoryTestAgentID  = "agent-1"
	endpointInventoryTestCadence  = "6h"
	endpointInventoryTestDaily    = "24h"
	endpointInventoryTestTenMins  = "10m"
	collectionPolicyMetadataKey   = "collection_policy"
	diagnosticStateError          = "error"
	redactionPolicyMetadataKey    = "redaction_policy"
	cycloneDXCollectionCadenceKey = "serviceradar:collection_cadence"
)

//nolint:gocyclo // This integration-style test validates the full payload shape.
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
	cfg.Cadence = endpointInventoryTestCadence
	cfg.CollectPaths = true

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != scanStateScanned || payload.CoverageState != coverageComplete {
		t.Fatalf("unexpected state: %s/%s", payload.State, payload.CoverageState)
	}
	if payload.PackageCount != 1 {
		t.Fatalf("PackageCount = %d, want 1", payload.PackageCount)
	}
	if got, want := payload.EnabledPlugins, []string{"dpkg"}; !sameStrings(got, want) {
		t.Fatalf("EnabledPlugins = %#v, want %#v", got, want)
	}
	if got, want := payload.DetectedPlugins, []string{"dpkg"}; !sameStrings(got, want) {
		t.Fatalf("DetectedPlugins = %#v, want %#v", got, want)
	}
	if len(payload.Diagnostics) != 1 ||
		payload.Diagnostics[0].Name != "dpkg" ||
		payload.Diagnostics[0].Type != "package_source" ||
		payload.Diagnostics[0].PackageCount != 1 {
		t.Fatalf("unexpected generic diagnostics: %#v", payload.Diagnostics)
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(`"sources"`)) ||
		bytes.Contains(encoded, []byte(`"enabled_sources"`)) ||
		bytes.Contains(encoded, []byte(`"detected_sources"`)) ||
		bytes.Contains(encoded, []byte(`"source"`)) {
		t.Fatalf("scan payload should expose only generic diagnostics fields: %s", encoded)
	}
	if payload.SBOM == nil || payload.OS.ID != "ubuntu" || payload.SBOM.BOMFormat != CycloneDXFormat {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if len(payload.SBOM.Components) != 1 || payload.SBOM.Components[0].PURL != "pkg:deb/nginx@1.24.0-2ubuntu7" {
		t.Fatalf("unexpected components: %#v", payload.SBOM.Components)
	}
	policy, ok := payload.Metadata[collectionPolicyMetadataKey].(map[string]any)
	if !ok ||
		policy["cadence"] != endpointInventoryTestCadence ||
		policy["collect_paths"] != true ||
		policy["collect_file_hashes"] != false {
		t.Fatalf("unexpected collection policy metadata: %#v", payload.Metadata)
	}
	redaction, ok := payload.Metadata[redactionPolicyMetadataKey].(map[string]string)
	if !ok || redaction["paths"] != redactionStateCollected || redaction["file_hashes"] != redactionStateOmitted {
		t.Fatalf("unexpected redaction policy metadata: %#v", payload.Metadata)
	}
	if propertyValue(payload.SBOM.Metadata.Properties, cycloneDXCollectionCadenceKey) != endpointInventoryTestCadence {
		t.Fatalf("SBOM cadence property missing: %#v", payload.SBOM.Metadata.Properties)
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
	if secondPayload.Metadata["reason"] != metadataReasonServerReconcileFloor {
		t.Fatalf("metadata reason = %#v, want %s", secondPayload.Metadata["reason"], metadataReasonServerReconcileFloor)
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

func TestRunnerReportsMissingSourceDiagnostics(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := testEndpointInventoryConfig(tmpDir, filepath.Join(tmpDir, "missing-dpkg-status"))
	cfg.Sources = []string{PackageSourceDpkg, PackageSourceRPM, PackageSourceAPK}
	cfg.RPMPath = filepath.Join(tmpDir, "missing-rpm")
	cfg.APKInstalledPath = filepath.Join(tmpDir, "missing-apk-installed")

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != scanStateNotSupported || payload.CoverageState != coverageNoSupportedPackageSource {
		t.Fatalf("unexpected missing source state: %s/%s", payload.State, payload.CoverageState)
	}
	if payload.PackageCount != 0 {
		t.Fatalf("PackageCount = %d, want 0", payload.PackageCount)
	}
	if got, want := payload.EnabledPlugins, cfg.Sources; !sameStrings(got, want) {
		t.Fatalf("EnabledPlugins = %#v, want %#v", got, want)
	}
	if len(payload.DetectedPlugins) != 0 {
		t.Fatalf("DetectedPlugins = %#v, want none", payload.DetectedPlugins)
	}

	assertSourceReason(t, payload.Diagnostics, PackageSourceDpkg, "unavailable", "not_found")
	assertSourceReason(t, payload.Diagnostics, PackageSourceRPM, "unavailable", "not_found")
	assertSourceReason(t, payload.Diagnostics, PackageSourceAPK, "unavailable", "not_found")
}

func TestRunnerTreatsEmptySupportedSourceAsComplete(t *testing.T) {
	tmpDir := t.TempDir()
	dpkgPath := filepath.Join(tmpDir, "status")
	if err := os.WriteFile(dpkgPath, []byte(""), 0600); err != nil {
		t.Fatal(err)
	}

	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)
	cfg.Sources = []string{PackageSourceDpkg}

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != scanStateScanned || payload.CoverageState != coverageComplete {
		t.Fatalf("unexpected empty supported source state: %s/%s", payload.State, payload.CoverageState)
	}
	if payload.PackageCount != 0 {
		t.Fatalf("PackageCount = %d, want 0", payload.PackageCount)
	}
	if len(payload.Diagnostics) != 1 ||
		payload.Diagnostics[0].Name != PackageSourceDpkg ||
		payload.Diagnostics[0].State != scanStateScanned ||
		!payload.Diagnostics[0].Detected {
		t.Fatalf("unexpected diagnostics: %#v", payload.Diagnostics)
	}
}

func TestSourceCoverageStateWithoutDiagnosticsIsUnknown(t *testing.T) {
	if got := sourceCoverageState(nil, 0); got != coverageUnknown {
		t.Fatalf("sourceCoverageState(nil, 0) = %q, want %q", got, coverageUnknown)
	}
}

func TestRunnerReportsPermissionDeniedDiagnostics(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission-denied fixture is not reliable when tests run as root")
	}
	if runtime.GOOS == "windows" {
		t.Skip("unix permission fixture is not meaningful on windows")
	}

	tmpDir := t.TempDir()
	dpkgPath := filepath.Join(tmpDir, "status")
	if err := os.WriteFile(dpkgPath, []byte("Package: nginx\n"), 0000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Chmod(dpkgPath, 0600)
	})

	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)
	cfg.Sources = []string{PackageSourceDpkg}

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != scanStateFailed || payload.CoverageState != coverageFailed {
		t.Fatalf("unexpected permission denied state: %s/%s", payload.State, payload.CoverageState)
	}
	assertSourceReason(t, payload.Diagnostics, PackageSourceDpkg, diagnosticStateError, "permission_denied")
}

func TestRunnerReportsRPMTimeoutDiagnostics(t *testing.T) {
	tmpDir := t.TempDir()
	rpmPath := filepath.Join(tmpDir, "rpm")
	writeExecutable(t, rpmPath, "#!/bin/sh\nsleep 2\n")

	cfg := testEndpointInventoryConfig(tmpDir, filepath.Join(tmpDir, "missing-dpkg-status"))
	cfg.Sources = []string{PackageSourceRPM}
	cfg.RPMPath = rpmPath
	cfg.ScanTimeout = "50ms"

	payload, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if payload.State != scanStateFailed || payload.CoverageState != coverageFailed {
		t.Fatalf("unexpected timeout state: %s/%s", payload.State, payload.CoverageState)
	}
	assertSourceReason(t, payload.Diagnostics, PackageSourceRPM, diagnosticStateError, "timeout")
}

func TestRunnerReportsRPMOutputTruncationDiagnostics(t *testing.T) {
	tmpDir := t.TempDir()
	rpmPath := filepath.Join(tmpDir, "rpm")
	writeExecutable(t, rpmPath, "#!/bin/sh\nprintf 'nginx\\t1.0\\tx86_64\\nopenssl\\t3.0\\tx86_64\\n'\n")

	packages, resolvedPath, truncated, err := CollectRPMPackages(context.Background(), rpmPath, 12)
	if !errors.Is(err, errOutputTruncated) {
		t.Fatalf("err = %v, want %v", err, errOutputTruncated)
	}
	if resolvedPath != rpmPath {
		t.Fatalf("resolvedPath = %q, want %q", resolvedPath, rpmPath)
	}
	if !truncated {
		t.Fatal("truncated = false, want true")
	}
	if len(packages) != 1 {
		t.Fatalf("packages = %#v, want one partially parsed package", packages)
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
	if propertyValue(bom.Metadata.Properties, "serviceradar:redaction_paths") != redactionStateOmitted {
		t.Fatalf("expected redaction property, got %#v", bom.Metadata.Properties)
	}
}

func TestDisabledPayloadIncludesCollectionPolicy(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = endpointInventoryTestAgentID
	cfg.Cadence = endpointInventoryTestDaily

	scan, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	policy, ok := scan.Metadata[collectionPolicyMetadataKey].(map[string]any)
	if !ok || policy["cadence"] != endpointInventoryTestDaily {
		t.Fatalf("disabled payload missing collection policy: %#v", scan.Metadata)
	}
}

func TestScanPayloadsCarryCollectorVersion(t *testing.T) {
	if collectorVersion == "" {
		t.Fatal("collectorVersion constant must not be empty")
	}

	// Disabled scan path.
	disabledCfg := DefaultConfig()
	disabledCfg.AgentID = endpointInventoryTestAgentID
	disabledScan, err := NewRunner(disabledCfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if disabledScan.CollectorVersion != collectorVersion {
		t.Fatalf("disabled payload CollectorVersion = %q, want %q", disabledScan.CollectorVersion, collectorVersion)
	}

	// Full scan path.
	tmpDir := t.TempDir()
	dpkgPath := writeEndpointInventoryFixture(t, tmpDir)
	cfg := testEndpointInventoryConfig(tmpDir, dpkgPath)

	scan, err := NewRunner(cfg).Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if scan.CollectorVersion != collectorVersion {
		t.Fatalf("scan payload CollectorVersion = %q, want %q", scan.CollectorVersion, collectorVersion)
	}
}

func propertyValue(properties []CycloneDXProperty, name string) string {
	for _, property := range properties {
		if property.Name == name {
			return property.Value
		}
	}

	return ""
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

func assertSourceReason(
	t *testing.T,
	sources []SourceSummary,
	source string,
	state string,
	reason string,
) {
	t.Helper()

	for _, summary := range sources {
		if summary.Source != source {
			continue
		}
		if summary.State != state || summary.Reason != reason {
			t.Fatalf("%s summary = %#v, want state=%s reason=%s", source, summary, state, reason)
		}
		return
	}

	t.Fatalf("missing source summary for %s: %#v", source, sources)
}

func writeExecutable(t *testing.T, path string, script string) {
	t.Helper()

	if err := os.WriteFile(path, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
}

func sameStrings(left []string, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for idx := range left {
		if left[idx] != right[idx] {
			return false
		}
	}

	return true
}
