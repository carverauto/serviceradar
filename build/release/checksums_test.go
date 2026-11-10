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
	if err := signReleaseChecksums(checksums, syntheticSigner(t, signerCopiesPayload), false); err != nil {
		t.Fatal(err)
	}
	return append(assets, checksums.assets...)
}

// signerCopiesPayload stands in for the signing command. Its bundle is derived
// from the bytes of the file it was handed, so a test can tell which file that
// was.
const signerCopiesPayload = `printf 'synthetic bundle over: ' > "$2" && cat "$1" >> "$2"`

func syntheticSigner(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "signer.sh")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
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
		checksumManifestAssetName, checksumSignatureAssetName,
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
		"SHA256SUMS signature missing": func(_ *testing.T, plan []uploadAsset) []uploadAsset {
			return withoutAsset(plan, checksumSignatureAssetName)
		},
		"SHA256SUMS signature empty": func(t *testing.T, plan []uploadAsset) []uploadAsset {
			t.Helper()
			if err := os.Truncate(planAsset(t, plan, checksumSignatureAssetName).sourcePath, 0); err != nil {
				t.Fatal(err)
			}
			return plan
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

// The signature must cover the SHA256SUMS file that is uploaded, and a release
// that cannot be signed must stop before it plans any upload.
func TestSHA256SUMSIsSignedAsUploaded(t *testing.T) {
	build := func(t *testing.T) (*releaseChecksums, uploadAsset) {
		t.Helper()
		path := filepath.Join(t.TempDir(), "serviceradar-agent_2.3.4_amd64.deb")
		if err := os.WriteFile(path, []byte("synthetic package"), 0o600); err != nil {
			t.Fatal(err)
		}
		checksums, err := buildReleaseChecksums([]uploadAsset{{sourcePath: path, uploadName: filepath.Base(path)}})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.RemoveAll(checksums.dir) })
		return checksums, planAsset(t, checksums.assets, checksumManifestAssetName)
	}

	t.Run("signer receives the uploaded file and no other credentials", func(t *testing.T) {
		checksums, manifest := build(t)
		t.Setenv(releasePrivateKeyEnv, "synthetic agent key")
		t.Setenv("GH_TOKEN", "synthetic release token")
		signer := syntheticSigner(t, `[ -z "${`+releasePrivateKeyEnv+`:-}${GH_TOKEN:-}" ] || exit 4
`+signerCopiesPayload)
		if err := signReleaseChecksums(checksums, signer, false); err != nil {
			t.Fatal(err)
		}
		uploaded, err := os.ReadFile(manifest.sourcePath)
		if err != nil {
			t.Fatal(err)
		}
		bundle, err := os.ReadFile(planAsset(t, checksums.assets, checksumSignatureAssetName).sourcePath)
		if err != nil {
			t.Fatal(err)
		}
		if string(bundle) != "synthetic bundle over: "+string(uploaded) {
			t.Fatalf("bundle %q was not produced from the uploaded %s %q", bundle, checksumManifestAssetName, uploaded)
		}
	})

	for name, signer := range map[string]func(*testing.T) string{
		"no signer configured": func(*testing.T) string { return "" },
		"relative signer path": func(*testing.T) string { return "sign-release-checksums.sh" },
		"signer fails": func(t *testing.T) string {
			t.Helper()
			return syntheticSigner(t, "exit 3")
		},
		"signer rewrites SHA256SUMS": func(t *testing.T) string {
			t.Helper()
			return syntheticSigner(t, `echo tampered >> "$1" && echo bundle > "$2"`)
		},
	} {
		t.Run(name, func(t *testing.T) {
			checksums, _ := build(t)
			err := signReleaseChecksums(checksums, signer(t), false)
			if !errors.Is(err, errChecksumCoverage) {
				t.Fatalf("unsigned %s accepted: error=%v", checksumManifestAssetName, err)
			}
			for _, asset := range checksums.assets {
				if asset.uploadName == checksumSignatureAssetName {
					t.Fatalf("a signature was planned after the signer was refused")
				}
			}
		})
	}

	t.Run("dry run needs no signer", func(t *testing.T) {
		checksums, _ := build(t)
		if err := signReleaseChecksums(checksums, "", true); err != nil {
			t.Fatalf("dry run refused without signing credentials: %v", err)
		}
		planAsset(t, checksums.assets, checksumSignatureAssetName)
	})
}

// The publisher's own preflight must reach the signer and the guard: a release
// whose inputs are all valid gets a sidecar for every installable and a signed
// SHA256SUMS before anything uploads, and none of it without a signer.
func TestPreflightPlansAChecksumForEveryInstallable(t *testing.T) {
	unsigned := syntheticPackagePreflight(t, []string{
		"serviceradar-agent__amd64.deb", "serviceradar-agent__arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
	}, "none")
	if err := prepareReleaseChecksums(unsigned); !errors.Is(err, errChecksumCoverage) || unsigned.checksums != nil {
		t.Fatalf("preflight without a signer planned checksums: error=%v", err)
	}

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
	ctx.config.checksumsSigner = syntheticSigner(t, signerCopiesPayload)
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
	if !planned[checksumManifestAssetName] || !planned[checksumSignatureAssetName] {
		t.Errorf("no signed %s planned", checksumManifestAssetName)
	}
	if len(planned) != 11 {
		t.Errorf("planned %d checksum files, want 9 sidecars, %s and its signature", len(planned), checksumManifestAssetName)
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
