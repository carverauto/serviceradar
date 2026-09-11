package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedLinuxManifestRequiresCompleteUniquePlatforms(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime.tar.gz")
	if err := os.WriteFile(path, []byte("synthetic runtime"), 0o600); err != nil {
		t.Fatal(err)
	}
	amd64 := managedAgentRuntime{arch: "amd64", path: path, url: "https://downloads.example.com/amd64.tar.gz"}
	arm64 := managedAgentRuntime{arch: "arm64", path: path, url: "https://downloads.example.com/arm64.tar.gz"}
	for name, runtimes := range map[string][]managedAgentRuntime{
		"missing":   {amd64},
		"duplicate": {amd64, amd64},
		"extra":     {amd64, arm64, arm64},
		"installer": {amd64, {arch: "darwin", path: path, url: "https://downloads.example.com/installer.pkg"}},
		"no URL":    {amd64, {arch: "arm64", path: path}},
		"no file":   {amd64, {arch: "arm64", path: path + ".missing", url: arm64.url}},
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := buildManagedAgentManifestAssets("2.3.4", runtimes, true); err == nil {
				t.Fatal("invalid platform set was accepted")
			}
		})
	}
}

func TestRPMUploadNamesPreserveOneVersionAndArchitecture(t *testing.T) {
	for _, version := range []string{"2.3.4", "2.3.4-rc.2"} {
		deb, rpm, release, err := deriveVersionMetadata("v" + version)
		if err != nil {
			t.Fatal(err)
		}
		for _, arch := range []string{"x86_64", "aarch64"} {
			name := "serviceradar-agent-" + rpm + "-" + release + "." + arch + ".rpm"
			got, err := resolveUploadName(name, deb, rpm, release)
			if err != nil || got != name {
				t.Fatalf("resolveUploadName(%q) = %q, %v", name, got, err)
			}
		}
	}
}

func TestPackagePreflightRequiresEveryLinuxInstaller(t *testing.T) {
	filenames := []string{
		"serviceradar-agent__amd64.deb", "serviceradar-agent__arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
	}
	for _, omitted := range append([]string{"none"}, filenames...) {
		t.Run(omitted, func(t *testing.T) {
			ctx := syntheticPackagePreflight(t, filenames, omitted)
			assets, err := preparePackageArtifacts(ctx)
			if omitted == "none" {
				if err != nil || len(assets) != 10 {
					t.Fatalf("complete installers and provenance rejected: assets=%d error=%v", len(assets), err)
				}
			} else if err == nil {
				t.Fatalf("missing required package %s accepted", omitted)
			}
		})
	}
}

func TestPackagePreflightPublishesWithoutAMissingMacOSInstaller(t *testing.T) {
	filenames := []string{
		"serviceradar-agent__amd64.deb", "serviceradar-agent__arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
	}
	ctx := syntheticPackagePreflight(t, filenames, "none")
	ctx.config.macosPkg, ctx.config.macosProvenance = "", ""
	assets, err := preparePackageArtifacts(ctx)
	if err != nil || len(assets) != 8 {
		t.Fatalf("release without the macOS installer rejected: assets=%d error=%v", len(assets), err)
	}
	for _, a := range assets {
		if strings.Contains(a.uploadName, "darwin") {
			t.Fatalf("unexpected macOS asset %q", a.uploadName)
		}
	}
}

func TestPackagePreflightRejectsHalfAMacOSHandoff(t *testing.T) {
	filenames := []string{
		"serviceradar-agent__amd64.deb", "serviceradar-agent__arm64.deb",
		"serviceradar-agent-2.3.4-1.x86_64.rpm", "serviceradar-agent-2.3.4-1.aarch64.rpm",
	}
	for _, drop := range []string{"pkg", "provenance"} {
		ctx := syntheticPackagePreflight(t, filenames, "none")
		if drop == "pkg" {
			ctx.config.macosPkg = ""
		} else {
			ctx.config.macosProvenance = ""
		}
		if _, err := preparePackageArtifacts(ctx); err == nil {
			t.Fatalf("a macOS handoff missing its %s was accepted", drop)
		}
	}
}

func syntheticPackagePreflight(t *testing.T, filenames []string, omitted string) *publishContext {
	t.Helper()
	config, proof := syntheticMacOSProvenance(t)
	data, err := json.Marshal(proof)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config.macosProvenance, data, 0o600); err != nil {
		t.Fatal(err)
	}
	config.windowsDir = syntheticWindowsHandoff(t, config.commit, nil)
	dir := t.TempDir()
	var paths []string
	for _, name := range filenames {
		if name == omitted {
			continue
		}
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte("synthetic installer bytes"), 0o600); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, path)
	}
	config.manifestPath = filepath.Join(dir, "manifest.txt")
	if err := os.WriteFile(config.manifestPath, []byte(strings.Join(paths, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return &publishContext{config: config, releaseVersion: "2.3.4", rpmVersion: "2.3.4", rpmRelease: "1", resolver: &runfileResolver{}}
}

func syntheticMacOSProvenance(t *testing.T) (publishConfig, macOSPackageProvenance) {
	t.Helper()
	dir := t.TempDir()
	config := publishConfig{
		commit:          strings.Repeat("a", 40),
		macosPkg:        filepath.Join(dir, "serviceradar-agent_2.3.4_darwin_arm64.pkg"),
		macosProvenance: filepath.Join(dir, "macos.provenance.json"),
	}
	contents := []byte("synthetic signed package bytes")
	if err := os.WriteFile(config.macosPkg, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	proof := macOSPackageProvenance{
		SchemaVersion: 1, Product: "serviceradar-agent", Version: "2.3.4", SourceCommit: config.commit,
		OS: "darwin", Arch: "arm64", Mode: "release", PackageFilename: filepath.Base(config.macosPkg),
		PackageSHA256: digestBytes(contents), BinarySHA256: strings.Repeat("b", 64), GatekeeperVerified: true,
		ApplicationSigning: macOSSigningEvidence{Identity: "Synthetic application signer", TeamID: "SYNTHETIC1", HardenedRuntime: true, Timestamp: true, Verified: true},
		InstallerSigning:   macOSSigningEvidence{Identity: "Synthetic installer signer", TeamID: "SYNTHETIC1", Timestamp: true, Verified: true},
	}
	proof.Notarization.Status = "Accepted"
	proof.Notarization.SubmissionID = "11111111-2222-4333-8444-555555555555"
	proof.Notarization.Stapled = true
	proof.Notarization.Validated = true
	return config, proof
}

func syntheticWindowsHandoff(t *testing.T, commit string, mutate func(string, *windowsPackageProvenance)) string {
	t.Helper()
	dir := t.TempDir()
	for _, arch := range []string{"amd64", "arm64"} {
		name := "serviceradar-agent_2.3.4_windows_" + arch + ".msi"
		contents := []byte("synthetic unsigned msi bytes " + arch)
		if err := os.WriteFile(filepath.Join(dir, name), contents, 0o600); err != nil {
			t.Fatal(err)
		}
		proof := windowsPackageProvenance{
			SchemaVersion: 1, Product: "serviceradar-agent", Version: "2.3.4", MSIVersion: "2.3.4", SourceCommit: commit,
			OS: "windows", Arch: arch, Mode: "unsigned", UpgradeCode: windowsUpgradeCodes[arch], PackageFilename: name,
			PackageSHA256: digestBytes(contents), BinarySHA256: strings.Repeat("b", 64), ConfigSHA256: strings.Repeat("c", 64),
		}
		if mutate != nil {
			mutate(arch, &proof)
		}
		data, err := json.Marshal(proof)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, strings.TrimSuffix(name, ".msi")+".provenance.json"), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestWindowsInstallersRequireBoundHandoff(t *testing.T) {
	commit := strings.Repeat("a", 40)
	for name, mutate := range map[string]func(string, *windowsPackageProvenance){
		"valid":                nil,
		"wrong commit":         func(_ string, p *windowsPackageProvenance) { p.SourceCommit = strings.Repeat("c", 40) },
		"wrong version":        func(_ string, p *windowsPackageProvenance) { p.Version = "2.3.5" },
		"wrong checksum":       func(_ string, p *windowsPackageProvenance) { p.PackageSHA256 = strings.Repeat("0", 64) },
		"claims signed":        func(_ string, p *windowsPackageProvenance) { p.Signed = true },
		"wrong filename":       func(_ string, p *windowsPackageProvenance) { p.PackageFilename = "agent.msi" },
		"missing binary proof": func(_ string, p *windowsPackageProvenance) { p.BinarySHA256 = "" },
		"swapped architecture": func(arch string, p *windowsPackageProvenance) {
			if arch == "arm64" {
				p.Arch = "amd64"
			}
		},
		"changed upgrade code": func(arch string, p *windowsPackageProvenance) {
			if arch == "amd64" {
				p.UpgradeCode = windowsUpgradeCodes["arm64"]
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			config := publishConfig{commit: commit, windowsDir: syntheticWindowsHandoff(t, commit, mutate)}
			assets, err := validateWindowsPackages(config, "2.3.4")
			if name == "valid" {
				if err != nil || len(assets) != 4 {
					t.Fatalf("valid Windows handoff rejected: assets=%d error=%v", len(assets), err)
				}
			} else if err == nil {
				t.Fatal("invalid Windows handoff accepted")
			}
		})
	}
	t.Run("missing arm64 installer", func(t *testing.T) {
		dir := syntheticWindowsHandoff(t, commit, nil)
		if err := os.Remove(filepath.Join(dir, "serviceradar-agent_2.3.4_windows_arm64.msi")); err != nil {
			t.Fatal(err)
		}
		if _, err := validateWindowsPackages(publishConfig{commit: commit, windowsDir: dir}, "2.3.4"); err == nil {
			t.Fatal("release accepted a handoff without the arm64 MSI")
		}
	})
}

func TestWindowsUpgradeCodesMatchThePackager(t *testing.T) {
	// Pinned in build/packaging/agent/windows too; changing either strands installed agents.
	if windowsUpgradeCodes["amd64"] != "3B42E26D-C52D-43A8-AFD9-DDC162D2A6B3" || windowsUpgradeCodes["arm64"] != "FE1549BF-9F21-45FF-95D3-05AC0AEE9C3A" {
		t.Fatal("Windows UpgradeCodes changed")
	}
}

func TestMacOSInstallerRequiresBoundVerifiedHandoff(t *testing.T) {
	for name, mutate := range map[string]func(*macOSPackageProvenance){
		"valid":                  func(_ *macOSPackageProvenance) {},
		"wrong commit":           func(p *macOSPackageProvenance) { p.SourceCommit = strings.Repeat("c", 40) },
		"wrong version":          func(p *macOSPackageProvenance) { p.Version = "2.3.5" },
		"wrong platform":         func(p *macOSPackageProvenance) { p.Arch = "amd64" },
		"wrong checksum":         func(p *macOSPackageProvenance) { p.PackageSHA256 = strings.Repeat("0", 64) },
		"unsigned":               func(p *macOSPackageProvenance) { p.Mode = "unsigned" },
		"application unverified": func(p *macOSPackageProvenance) { p.ApplicationSigning.Verified = false },
		"installer unverified":   func(p *macOSPackageProvenance) { p.InstallerSigning.Verified = false },
		"different teams":        func(p *macOSPackageProvenance) { p.InstallerSigning.TeamID = "OTHERTEAM1" },
		"unnotarized":            func(p *macOSPackageProvenance) { p.Notarization.Status = "In Progress" },
		"unstapled":              func(p *macOSPackageProvenance) { p.Notarization.Stapled = false },
		"gatekeeper failed":      func(p *macOSPackageProvenance) { p.GatekeeperVerified = false },
	} {
		t.Run(name, func(t *testing.T) {
			config, proof := syntheticMacOSProvenance(t)
			mutate(&proof)
			data, err := json.Marshal(proof)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(config.macosProvenance, data, 0o600); err != nil {
				t.Fatal(err)
			}
			asset, err := validateMacOSPackage(config, "2.3.4")
			if name == "valid" {
				if err != nil || asset.uploadName != proof.PackageFilename {
					t.Fatalf("valid standalone installer rejected: %v", err)
				}
			} else if err == nil {
				t.Fatal("invalid installer handoff accepted")
			}
		})
	}
}

func TestPublishedReleaseCannotBeMutated(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("published release mutation attempted: %s", r.Method)
		}
		_ = json.NewEncoder(w).Encode(release{ID: 42, TagName: "v2.3.4", Draft: false})
	}))
	t.Cleanup(server.Close)
	client := newGithubClient("", "example/project", server.URL, false)
	if _, _, err := ensureRelease(client, ensureReleaseArgs{tag: "v2.3.4", draft: true}); err == nil {
		t.Fatal("published release accepted for mutation")
	}
}

func TestDraftAssetRetryComparesDigestBeforeReplacement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "installer.pkg")
	contents := []byte("synthetic timestamped package")
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name         string
		digest       string
		overwrite    bool
		wantError    bool
		wantRequests int
	}{
		{"same bytes", "sha256:" + digestBytes(contents), false, false, 0},
		{"different bytes blocked", "sha256:" + strings.Repeat("0", 64), false, true, 0},
		{"explicit draft retry", "sha256:" + strings.Repeat("0", 64), true, false, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests++
				if (requests == 1 && r.Method != http.MethodDelete) || (requests == 2 && r.Method != http.MethodPost) {
					t.Errorf("unexpected retry request: %s", r.Method)
				}
				w.WriteHeader(http.StatusOK)
			}))
			t.Cleanup(server.Close)
			client := newGithubClient("", "example/project", server.URL, false)
			existing := map[string]releaseAsset{"installer.pkg": {ID: 42, Digest: tc.digest}}
			err := uploadReleaseAsset(client, server.URL+"/assets", existing, uploadAsset{sourcePath: path, uploadName: "installer.pkg"}, tc.overwrite)
			if (err != nil) != tc.wantError || requests != tc.wantRequests {
				t.Fatalf("retry error=%v requests=%d, expected error=%t requests=%d", err, requests, tc.wantError, tc.wantRequests)
			}
		})
	}
}
