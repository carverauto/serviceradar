package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	// checksumManifestAssetName lists every file in the checksum plan in
	// sha256sum(1) format, so one download verifies a whole release.
	checksumManifestAssetName = "SHA256SUMS"
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
	return name == checksumManifestAssetName || strings.HasSuffix(name, checksumSidecarSuffix)
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
			target := strings.TrimSuffix(name, checksumSidecarSuffix)
			if name != checksumManifestAssetName && !isInstallable(target) {
				return fmt.Errorf("%w: sidecar %q does not belong to an installable asset", errChecksumCoverage, name)
			}
			if _, ok := byName[target]; name != checksumManifestAssetName && !ok {
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
