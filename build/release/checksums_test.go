package main

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// syntheticChecksumPlan writes one file per name and returns the upload plan
// the publisher would build for them, checksum files included.
func syntheticChecksumPlan(t *testing.T, names ...string) []uploadAsset {
	t.Helper()
	dir := t.TempDir()
	assets := make([]uploadAsset, 0, len(names))
	for _, name := range names {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte("synthetic bytes of "+name), 0o600); err != nil {
			t.Fatal(err)
		}
		assets = append(assets, uploadAsset{sourcePath: path, uploadName: name})
	}
	checksums, err := buildReleaseChecksums(assets)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(checksums.dir) })
	return append(assets, checksums.assets...)
}

func planAsset(t *testing.T, plan []uploadAsset, name string) uploadAsset {
	t.Helper()
	for _, asset := range plan {
		if asset.uploadName == name {
			return asset
		}
	}
	t.Fatalf("upload plan has no %q", name)
	return uploadAsset{}
}

func withoutAsset(plan []uploadAsset, name string) []uploadAsset {
	var kept []uploadAsset
	for _, asset := range plan {
		if asset.uploadName != name {
			kept = append(kept, asset)
		}
	}
	return kept
}

// The sidecar name and bytes are a contract with installers outside this
// repository: they look up "<asset>.sha256" and hand its URL to a downloader
// that expects sha256sum(1) lines keyed by the asset's filename.
func TestReleaseChecksumFilesUseSha256sumFormat(t *testing.T) {
	const (
		deb        = "serviceradar-agent_2.3.4_arm64.deb"
		runtime    = "serviceradar-agent_2.3.4_linux_arm64.tar.gz"
		msi        = "serviceradar-agent_2.3.4_windows_amd64.msi"
		provenance = "serviceradar-agent_2.3.4_windows_amd64.provenance.json"
	)
	plan := syntheticChecksumPlan(t, runtime, provenance, msi, deb)

	line := func(name string) string {
		return digestBytes([]byte("synthetic bytes of "+name)) + "  " + name + "\n"
	}
	names := make([]string, 0, len(plan))
	for _, asset := range plan {
		names = append(names, asset.uploadName)
	}
	sort.Strings(names)
	wantNames := []string{
		checksumManifestAssetName,
		deb, deb + ".sha256",
		runtime, runtime + ".sha256",
		msi, msi + ".sha256",
		provenance,
	}
	sort.Strings(wantNames)
	if strings.Join(names, "\n") != strings.Join(wantNames, "\n") {
		t.Fatalf("upload plan = %v, want %v", names, wantNames)
	}
	for _, name := range []string{deb, runtime, msi} {
		got, err := os.ReadFile(planAsset(t, plan, name+".sha256").sourcePath)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != line(name) {
			t.Fatalf("%s.sha256 = %q, want %q", name, got, line(name))
		}
	}
	got, err := os.ReadFile(planAsset(t, plan, checksumManifestAssetName).sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	if want := line(deb) + line(runtime) + line(msi) + line(provenance); string(got) != want {
		t.Fatalf("SHA256SUMS = %q, want %q", got, want)
	}
}

func TestReleaseRefusesAnAssetWithoutItsChecksum(t *testing.T) {
	const (
		deb        = "serviceradar-agent_2.3.4_amd64.deb"
		rpm        = "serviceradar-agent-2.3.4-1.x86_64.rpm"
		provenance = "serviceradar-agent_2.3.4_darwin_arm64.provenance.json"
	)
	for name, mutate := range map[string]func(*testing.T, []uploadAsset) []uploadAsset{
		"complete": func(_ *testing.T, plan []uploadAsset) []uploadAsset { return plan },
		"sidecar missing": func(_ *testing.T, plan []uploadAsset) []uploadAsset {
			return withoutAsset(plan, rpm+".sha256")
		},
		"SHA256SUMS missing": func(_ *testing.T, plan []uploadAsset) []uploadAsset {
			return withoutAsset(plan, checksumManifestAssetName)
		},
		"package changed after hashing": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			if err := os.WriteFile(planAsset(t, plan, deb).sourcePath, []byte("rebuilt package bytes"), 0o600); err != nil {
				t.Fatal(err)
			}
			return plan
		},
		"provenance changed after hashing": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			if err := os.WriteFile(planAsset(t, plan, provenance).sourcePath, []byte("{}"), 0o600); err != nil {
				t.Fatal(err)
			}
			return plan
		},
		"sidecar names another file": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			other, err := os.ReadFile(planAsset(t, plan, deb+".sha256").sourcePath)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(planAsset(t, plan, rpm+".sha256").sourcePath, other, 0o600); err != nil {
				t.Fatal(err)
			}
			return plan
		},
		"installable added after hashing": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			path := filepath.Join(t.TempDir(), "serviceradar-cli_2.3.4_amd64.deb")
			if err := os.WriteFile(path, []byte("late package"), 0o600); err != nil {
				t.Fatal(err)
			}
			return append(plan, uploadAsset{sourcePath: path, uploadName: filepath.Base(path)})
		},
		"unclassified file type": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			path := filepath.Join(t.TempDir(), "serviceradar-agent_2.3.4_windows_amd64.zip")
			if err := os.WriteFile(path, []byte("new archive type"), 0o600); err != nil {
				t.Fatal(err)
			}
			return append(plan, uploadAsset{sourcePath: path, uploadName: filepath.Base(path)})
		},
		"SHA256SUMS lists a file that is not uploaded": func(_ *testing.T, plan []uploadAsset) []uploadAsset {
			return withoutAsset(plan, provenance)
		},
		"sidecar without its package": func(_ *testing.T, plan []uploadAsset) []uploadAsset {
			return withoutAsset(plan, deb)
		},
	} {
		t.Run(name, func(t *testing.T) {
			plan := mutate(t, syntheticChecksumPlan(t, deb, rpm, provenance))
			err := requireChecksumCoverage(plan)
			if name == "complete" {
				if err != nil {
					t.Fatalf("complete checksum plan refused: %v", err)
				}
				return
			}
			if !errors.Is(err, errChecksumCoverage) {
				t.Fatalf("incomplete checksum plan accepted: error=%v", err)
			}
		})
	}
}

// The publisher's own preflight must reach the guard: a release whose inputs
// are all valid gets a sidecar for every installable before anything uploads.
func TestPreflightPlansAChecksumForEveryInstallable(t *testing.T) {
	ctx := syntheticPackagePreflight(t, []string{
		"serviceradar-agent__amd64.deb", "serviceradar-agent__arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
	}, "none")
	packages, err := preparePackageArtifacts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ctx.packages = packages
	for _, arch := range []string{defaultAgentRuntimeArch, linuxARM64} {
		path := filepath.Join(t.TempDir(), "runtime.tar.gz")
		if err := os.WriteFile(path, []byte("synthetic runtime "+arch), 0o600); err != nil {
			t.Fatal(err)
		}
		ctx.runtimes = append(ctx.runtimes, managedAgentRuntime{arch: arch, path: path})
	}
	if err := prepareReleaseChecksums(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(ctx.checksums.dir) })

	planned := make(map[string]bool)
	for _, asset := range ctx.checksums.assets {
		planned[asset.uploadName] = true
	}
	for _, name := range []string{
		"serviceradar-agent_2.3.4_amd64.deb", "serviceradar-agent_2.3.4_arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
		"serviceradar-agent_2.3.4_darwin_arm64.pkg",
		"serviceradar-agent_2.3.4_windows_amd64.msi", "serviceradar-agent_2.3.4_windows_arm64.msi",
		"serviceradar-agent_2.3.4_linux_amd64.tar.gz", "serviceradar-agent_2.3.4_linux_arm64.tar.gz",
	} {
		if !planned[name+".sha256"] {
			t.Errorf("no %s.sha256 planned", name)
		}
	}
	if !planned[checksumManifestAssetName] {
		t.Errorf("no %s planned", checksumManifestAssetName)
	}
	if len(planned) != 10 {
		t.Errorf("planned %d checksum files, want 9 sidecars and %s", len(planned), checksumManifestAssetName)
	}
}

func TestPublishedReleaseMustHoldTheChecksummedBytes(t *testing.T) {
	const deb = "serviceradar-agent_2.3.4_amd64.deb"
	plan := syntheticChecksumPlan(t, deb)
	stored := func(t *testing.T) []releaseAsset {
		t.Helper()
		assets := make([]releaseAsset, 0, len(plan))
		for i, asset := range plan {
			digest, err := fileSHA256(asset.sourcePath)
			if err != nil {
				t.Fatal(err)
			}
			assets = append(assets, releaseAsset{ID: int64(i + 1), Name: asset.uploadName, Digest: "sha256:" + digest})
		}
		return assets
	}
	for name, mutate := range map[string]func([]releaseAsset) []releaseAsset{
		"stored as uploaded": func(assets []releaseAsset) []releaseAsset { return assets },
		"host reports no digest": func(assets []releaseAsset) []releaseAsset {
			for i := range assets {
				assets[i].Digest = ""
			}
			return assets
		},
		"sidecar not stored": func(assets []releaseAsset) []releaseAsset {
			var kept []releaseAsset
			for _, asset := range assets {
				if asset.Name != deb+".sha256" {
					kept = append(kept, asset)
				}
			}
			return kept
		},
		"package stored with other bytes": func(assets []releaseAsset) []releaseAsset {
			for i := range assets {
				if assets[i].Name == deb {
					assets[i].Digest = "sha256:" + strings.Repeat("0", 64)
				}
			}
			return assets
		},
		"package stored twice": func(assets []releaseAsset) []releaseAsset {
			return append(assets, releaseAsset{ID: 99, Name: deb, Digest: assets[0].Digest})
		},
	} {
		t.Run(name, func(t *testing.T) {
			err := verifyPublishedChecksums(&release{TagName: "v2.3.4", Assets: mutate(stored(t))}, plan)
			accepted := name == "stored as uploaded" || name == "host reports no digest"
			if accepted && err != nil {
				t.Fatalf("matching release refused: %v", err)
			}
			if !accepted && !errors.Is(err, errChecksumCoverage) {
				t.Fatalf("mismatched release accepted: error=%v", err)
			}
		})
	}
}
