package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// checksumManifestAssetName lists every file in the checksum plan in
	// sha256sum(1) format, so one download verifies a whole release.
	checksumManifestAssetName = "SHA256SUMS"
	// checksumSignatureAssetName is the Sigstore bundle holding the release
	// key's signature over the exact SHA256SUMS bytes that are uploaded.
	checksumSignatureAssetName = checksumManifestAssetName + ".sigstore.json"
	dryRunChecksumSignature    = "dry-run-signature\n"
	// checksumSidecarSuffix names the per-installable sidecar. Installers that
	// discover a release look for exactly "<asset name>.sha256".
	checksumSidecarSuffix = ".sha256"
)

var errChecksumCoverage = errors.New("release checksum coverage is incomplete")

// isInstallable reports whether an operator downloads and installs or runs the
// file. Each installable is published with a sidecar.
func isInstallable(name string) bool {
	return hasAnySuffix(name, ".deb", ".rpm", ".pkg", ".msi", ".tar.gz")
}

// isAttestation reports whether the file is published beside an installable to
// describe it. It is listed in SHA256SUMS and has no sidecar of its own.
func isAttestation(name string) bool {
	return hasAnySuffix(name, ".provenance.json")
}

// releaseChecksums is the checksum material for one release, computed from the
// files this process is about to upload.
type releaseChecksums struct {
	dir    string
	assets []uploadAsset
}

func hasAnySuffix(name string, suffixes ...string) bool {
	for _, suffix := range suffixes {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

func isChecksumAsset(name string) bool {
	return name == checksumManifestAssetName || name == checksumSignatureAssetName ||
		strings.HasSuffix(name, checksumSidecarSuffix)
}

// signReleaseChecksums has the signer command sign the SHA256SUMS file that
// will be uploaded and adds the bundle it writes to the checksum assets. The
// command receives the SHA256SUMS path and the bundle output path. A dry run
// needs no signing credentials and plans a placeholder instead.
func signReleaseChecksums(checksums *releaseChecksums, signer string, dryRun bool) error {
	var manifest uploadAsset
	for _, asset := range checksums.assets {
		if asset.uploadName == checksumManifestAssetName {
			manifest = asset
		}
	}
	if manifest.sourcePath == "" {
		return fmt.Errorf("%w: no %s to sign", errChecksumCoverage, checksumManifestAssetName)
	}
	bundlePath := filepath.Join(checksums.dir, checksumSignatureAssetName)
	bundle := uploadAsset{sourcePath: bundlePath, uploadName: checksumSignatureAssetName}
	if dryRun {
		if err := os.WriteFile(bundlePath, []byte(dryRunChecksumSignature), 0o644); err != nil {
			return err
		}
		checksums.assets = append(checksums.assets, bundle)
		return nil
	}
	if !filepath.IsAbs(signer) {
		return fmt.Errorf("%w: --checksums_signer must be an absolute path to the command that signs %s", errChecksumCoverage, checksumManifestAssetName)
	}
	before, err := fileSHA256(manifest.sourcePath)
	if err != nil {
		return err
	}
	command := exec.CommandContext(context.Background(), signer, manifest.sourcePath, bundlePath)
	command.Env = signerEnvironment(os.Environ())
	command.Stdout = os.Stderr
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%w: signing %s failed: %w", errChecksumCoverage, checksumManifestAssetName, err)
	}
	after, err := fileSHA256(manifest.sourcePath)
	if err != nil {
		return err
	}
	if before != after {
		return fmt.Errorf("%w: the signer changed %s", errChecksumCoverage, checksumManifestAssetName)
	}
	checksums.assets = append(checksums.assets, bundle)
	return nil
}

// checksumLine is one sha256sum(1) text-mode line. Ansible get_url accepts a
// file of such lines from a checksum URL and selects the line whose filename
// equals the last path segment of the download URL.
func checksumLine(digest, name string) string {
	return digest + "  " + name + "\n"
}

// buildReleaseChecksums hashes each file once, from the path that will be
// uploaded, and writes a sidecar for every installable plus one SHA256SUMS.
// The caller removes the returned directory.
func buildReleaseChecksums(assets []uploadAsset) (*releaseChecksums, error) {
	dir, err := os.MkdirTemp("", "serviceradar-release-checksums-*")
	if err != nil {
		return nil, err
	}
	checksums := &releaseChecksums{dir: dir}
	sorted := append([]uploadAsset(nil), assets...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].uploadName < sorted[j].uploadName })

	var manifest strings.Builder
	for _, asset := range sorted {
		digest, err := fileSHA256(asset.sourcePath)
		if err != nil {
			_ = os.RemoveAll(dir)
			return nil, err
		}
		line := checksumLine(digest, asset.uploadName)
		manifest.WriteString(line)
		if !isInstallable(asset.uploadName) {
			continue
		}
		sidecar, err := writeChecksumFile(dir, asset.uploadName+checksumSidecarSuffix, line)
		if err != nil {
			_ = os.RemoveAll(dir)
			return nil, err
		}
		checksums.assets = append(checksums.assets, sidecar)
	}
	manifestAsset, err := writeChecksumFile(dir, checksumManifestAssetName, manifest.String())
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	checksums.assets = append(checksums.assets, manifestAsset)
	return checksums, nil
}

func writeChecksumFile(dir, name, content string) (uploadAsset, error) {
	if name != filepath.Base(name) {
		return uploadAsset{}, fmt.Errorf("%w: asset name %q is not a plain filename", errChecksumCoverage, name)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return uploadAsset{}, err
	}
	return uploadAsset{sourcePath: path, uploadName: name}, nil
}

// signerEnvironment is the publisher's environment without the credentials
// the signer has no use for: the agent manifest key and the release API tokens.
func signerEnvironment(environment []string) []string {
	kept := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, _, _ := strings.Cut(entry, "=")
		switch name {
		case releasePrivateKeyEnv, releasePrivateKeyFileEnv, "FORGEJO_TOKEN", "GITEA_TOKEN", "GITHUB_TOKEN", "GH_TOKEN":
			continue
		}
		kept = append(kept, entry)
	}
	return kept
}

// requireChecksumCoverage refuses an upload plan in which a file would be
// published without its checksum. It reads the plan as it will be uploaded
// and hashes every file again, so it does not depend on how the checksum
// files were produced.
func requireChecksumCoverage(plan []uploadAsset) error {
	byName := make(map[string]uploadAsset, len(plan))
	for _, asset := range plan {
		if _, duplicate := byName[asset.uploadName]; duplicate {
			return fmt.Errorf("%w: duplicate asset %q", errChecksumCoverage, asset.uploadName)
		}
		byName[asset.uploadName] = asset
	}
	manifestAsset, ok := byName[checksumManifestAssetName]
	if !ok {
		return fmt.Errorf("%w: %s is not in the upload plan", errChecksumCoverage, checksumManifestAssetName)
	}
	manifest, err := os.ReadFile(manifestAsset.sourcePath)
	if err != nil {
		return err
	}
	signature, ok := byName[checksumSignatureAssetName]
	if !ok {
		return fmt.Errorf("%w: %s would be published without %s", errChecksumCoverage, checksumManifestAssetName, checksumSignatureAssetName)
	}
	if info, err := os.Stat(signature.sourcePath); err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
		return fmt.Errorf("%w: %s is missing or empty", errChecksumCoverage, checksumSignatureAssetName)
	}
	listed := make(map[string]bool)
	for _, line := range strings.SplitAfter(string(manifest), "\n") {
		if line != "" {
			listed[line] = true
		}
	}

	covered := 0
	for _, asset := range plan {
		name := asset.uploadName
		if isChecksumAsset(name) {
			if !strings.HasSuffix(name, checksumSidecarSuffix) {
				continue
			}
			target := strings.TrimSuffix(name, checksumSidecarSuffix)
			if !isInstallable(target) {
				return fmt.Errorf("%w: sidecar %q does not belong to an installable asset", errChecksumCoverage, name)
			}
			if _, ok := byName[target]; !ok {
				return fmt.Errorf("%w: sidecar %q has no asset %q", errChecksumCoverage, name, target)
			}
			continue
		}
		installable := isInstallable(name)
		if !installable && !isAttestation(name) {
			return fmt.Errorf("%w: asset %q has no checksum rule; classify its file type before publishing it", errChecksumCoverage, name)
		}
		digest, err := fileSHA256(asset.sourcePath)
		if err != nil {
			return err
		}
		want := checksumLine(digest, name)
		if !listed[want] {
			return fmt.Errorf("%w: %s does not list %q with its current SHA256", errChecksumCoverage, checksumManifestAssetName, name)
		}
		covered++
		if !installable {
			continue
		}
		sidecar, ok := byName[name+checksumSidecarSuffix]
		if !ok {
			return fmt.Errorf("%w: %q would be published without %q", errChecksumCoverage, name, name+checksumSidecarSuffix)
		}
		content, err := os.ReadFile(sidecar.sourcePath)
		if err != nil {
			return err
		}
		if string(content) != want {
			return fmt.Errorf("%w: %q does not hold the current SHA256 of %q", errChecksumCoverage, sidecar.uploadName, name)
		}
	}
	if len(listed) != covered {
		return fmt.Errorf("%w: %s lists %d files but the upload plan has %d", errChecksumCoverage, checksumManifestAssetName, len(listed), covered)
	}
	return nil
}

// verifyPublishedChecksums checks the release as the host now reports it: each
// planned file is present exactly once, and where the host reports a digest of
// the stored bytes it equals the digest of the local file.
func verifyPublishedChecksums(rel *release, plan []uploadAsset) error {
	published := make(map[string][]releaseAsset, len(rel.Assets))
	for _, asset := range rel.Assets {
		published[asset.Name] = append(published[asset.Name], asset)
	}
	for _, asset := range plan {
		stored := published[asset.uploadName]
		if len(stored) != 1 {
			return fmt.Errorf("%w: release %s holds %d copies of %q, expected 1", errChecksumCoverage, rel.TagName, len(stored), asset.uploadName)
		}
		if stored[0].Digest == "" {
			continue
		}
		digest, err := fileSHA256(asset.sourcePath)
		if err != nil {
			return err
		}
		if stored[0].Digest != "sha256:"+digest {
			return fmt.Errorf("%w: stored %q differs from the file its checksum was computed from", errChecksumCoverage, asset.uploadName)
		}
	}
	return nil
}
