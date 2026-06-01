package endpointinventory

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
	cfg.AgentID = "agent-1"
	cfg.Sources = []string{"dpkg"}
	cfg.OSReleasePath = osReleasePath
	cfg.DpkgStatusPath = dpkgPath
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
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
	if payload.OS.ID != "ubuntu" || payload.SBOM.BOMFormat != CycloneDXFormat {
		t.Fatalf("unexpected payload: %#v", payload)
	}
	if len(payload.SBOM.Components) != 1 || payload.SBOM.Components[0].PURL != "pkg:deb/nginx@1.24.0-2ubuntu7" {
		t.Fatalf("unexpected components: %#v", payload.SBOM.Components)
	}
}

func TestBuildCycloneDXIncludesAgentAndOSProperties(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AgentID = "agent-1"
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
