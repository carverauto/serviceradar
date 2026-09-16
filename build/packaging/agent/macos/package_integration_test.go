//go:build darwin && arm64

package main

import (
	"encoding/json"
	"encoding/xml"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This test runs only on a Darwin ARM64 host. Its inputs are the real CGO agent
// and committed installer payload; no signing identity or installation is used.
func TestUnsignedInstallerRoundTrip(t *testing.T) {
	if os.Getenv("SERVICERADAR_MACOS_AGENT_RUNFILE") == "" {
		if os.Getenv("TEST_SRCDIR") != "" {
			t.Fatal("Bazel test is missing its declared agent input")
		}
		t.Skip("run //build/packaging/agent/macos:package_macos_test for the actual installer round-trip")
	}
	in, err := declaredInputs()
	if err != nil {
		t.Fatal(err)
	}
	opts := options{Mode: modeUnsigned, OutputDir: t.TempDir(), Version: fullVersion, SourceCommit: strings.Repeat("1", 40)}
	out, err := (builder{runner: systemRunner{env: platformEnvironment()}}).build(t.Context(), opts, in)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(out.ProvenancePath)
	if err != nil {
		t.Fatal(err)
	}
	var proof provenance
	if err := json.Unmarshal(data, &proof); err != nil {
		t.Fatal(err)
	}
	if proof.Mode != modeUnsigned || proof.Version != fullVersion || proof.ApplicationSigning.Verified || proof.Notarization.Status != "" {
		t.Fatalf("unexpected unsigned provenance: %+v", proof)
	}
}

// Package receipts accept and retain the same prerelease version as the binary;
// do not collapse distinct prereleases to a stable receipt version.
func TestPrereleaseReceiptRoundTrip(t *testing.T) {
	for _, version := range []string{"2.3.4-pre1", "2.3.4-rc2", "2.3.4-alpha0", "2.3.4-beta3"} {
		t.Run(version, func(t *testing.T) {
			work := t.TempDir()
			root, scripts := filepath.Join(work, "root"), filepath.Join(work, "scripts")
			if err := os.Mkdir(root, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(scripts, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "synthetic.txt"), []byte("synthetic installer payload"), 0644); err != nil {
				t.Fatal(err)
			}
			b := builder{runner: systemRunner{env: platformEnvironment()}}
			pkg, err := b.unsignedPackage(t.Context(), work, root, scripts, version)
			if err != nil {
				t.Fatal(err)
			}
			expanded := filepath.Join(work, "expanded")
			if _, err := b.runner.run(t.Context(), "/usr/sbin/pkgutil", "--expand-full", pkg, expanded); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(filepath.Join(expanded, "agent-component.pkg", "PackageInfo"))
			if err != nil {
				t.Fatal(err)
			}
			var info struct {
				Version string `xml:"version,attr"`
			}
			if err := xml.Unmarshal(data, &info); err != nil {
				t.Fatal(err)
			}
			if info.Version != version {
				t.Fatalf("receipt version %q does not match %q", info.Version, version)
			}
		})
	}
}
