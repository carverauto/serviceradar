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

package agent

// Pushed-artifact activation for native add-ons. The agent fetches a signed add-on
// artifact from object storage, verifies it, stages it under a versioned directory
// with an atomic `current` symlink, and returns the resolved binary path for the
// add-on supervisor. This mirrors the Bumblebee catalog-staging pattern
// (go/pkg/bumblebee/catalog.go) and the agent release runtime symlink pattern
// (release_runtime.go), reusing hashutil for digest checks and the agent release
// ed25519 trust root for signature verification.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/hashutil"
	"github.com/carverauto/serviceradar/proto"
)

const (
	addonsDirName                  = "addons"
	addonVersionsDir               = "versions"
	addonCurrentLink               = "current"
	addonBinaryMode                = 0o755
	addonManifestMode              = 0o644 // non-executable bundled files (manifest, config, units)
	addonStageMetaFile             = ".serviceradar-addon.json"
	addonSystemdActivationMetaFile = ".serviceradar-systemd-activation.json"

	// addonLocalOverrideFile is the operator-managed local override (break-glass /
	// dev) read from the agent config dir; its entries take precedence over pushed
	// assignments with the same addon_id.
	addonLocalOverrideFile = "addons.local.json"

	// Bounds on a pushed-artifact gzip tarball (binary + manifest/config + systemd
	// units), guarding against decompression bombs from a malformed/hostile artifact.
	maxAddonTarballEntries   = 64
	maxAddonTarballFileBytes = 512 << 20 // 512 MiB per extracted file
	maxAddonTarballBytes     = 1 << 30   // 1 GiB total extracted
)

type addonStageMetadata struct {
	AddonID        string `json:"addon_id"`
	Version        string `json:"version"`
	BinaryName     string `json:"binary_name"`
	ArtifactObject string `json:"artifact_object_key"`
	ArtifactSHA256 string `json:"artifact_sha256"`
	Signature      string `json:"artifact_signature,omitempty"`
}

type addonSystemdActivationMetadata struct {
	AddonID        string   `json:"addon_id"`
	Version        string   `json:"version"`
	BinaryName     string   `json:"binary_name"`
	ArtifactSHA256 string   `json:"artifact_sha256"`
	Signature      string   `json:"artifact_signature,omitempty"`
	ConfigSHA256   string   `json:"config_sha256,omitempty"`
	Units          []string `json:"units"`
	Enable         string   `json:"enable,omitempty"`
}

var (
	// ErrAddonObjectStoreUnavailable is returned when a pushed-artifact add-on is
	// assigned but the agent has no object store configured to fetch it from.
	ErrAddonObjectStoreUnavailable = errors.New("addon object store unavailable")
	// ErrAddonArtifactIncomplete is returned when the assignment is missing the
	// object key or expected sha256 required to fetch and verify the artifact.
	ErrAddonArtifactIncomplete = errors.New("addon artifact reference incomplete")
	// ErrAddonArtifactDownloadFailed is returned when the gateway-proxied HTTPS
	// download of an add-on artifact returns a non-200 status.
	ErrAddonArtifactDownloadFailed = errors.New("addon artifact gateway download failed")
	// ErrAddonArtifactHashMismatch is returned when the fetched artifact does not
	// match the expected sha256.
	ErrAddonArtifactHashMismatch = errors.New("addon artifact sha256 mismatch")
	// ErrAddonSignatureInvalid is returned when a supplied artifact signature fails
	// ed25519 verification.
	ErrAddonSignatureInvalid = errors.New("addon artifact signature invalid")
	// ErrAddonUnsafePath is returned when an add-on id or version would not form a
	// single safe path segment under the staging root (path-traversal guard).
	ErrAddonUnsafePath = errors.New("addon id or version is not a safe path segment")
	// ErrAddonRollbackTargetMissing is returned when a rollback is asked to restore the
	// `current` symlink to a prior version whose staged directory no longer exists, so
	// restoring it would leave a dangling `current` pointing at nothing.
	ErrAddonRollbackTargetMissing = errors.New("addon rollback target version is missing")
	// ErrAddonTarballUnsafe is returned when a pushed-artifact tarball contains an entry
	// that is not a regular file named as a single safe path segment.
	ErrAddonTarballUnsafe = errors.New("addon tarball entry is unsafe")
	// ErrAddonTarballTooLarge is returned when a pushed-artifact tarball exceeds the
	// entry-count or size bounds (decompression-bomb guard).
	ErrAddonTarballTooLarge = errors.New("addon tarball exceeds size limits")
	// ErrAddonTarballBinaryMissing is returned when a pushed-artifact tarball does not
	// contain the add-on's declared executable.
	ErrAddonTarballBinaryMissing = errors.New("addon tarball is missing the add-on binary")
	// ErrAddonRuntimeConfigAmbiguous is returned when assignment config cannot be
	// materialized because a staged systemd add-on has multiple plausible runtime
	// JSON config files and no <addon_id>.json convention match.
	ErrAddonRuntimeConfigAmbiguous = errors.New("addon runtime config file is ambiguous")
)

// safeAddonSegment reports whether s is safe to use as a single path component under
// the staging root: non-empty, not "." or "..", and free of path separators. This
// blocks path traversal from control-plane-supplied addon_id / version values.
func safeAddonSegment(s string) bool {
	switch s {
	case "", ".", "..":
		return false
	}

	return !strings.ContainsRune(s, '/') &&
		!strings.ContainsRune(s, '\\') &&
		!strings.ContainsRune(s, filepath.Separator)
}

// resolveAddonArtifactRoot returns the base directory under which pushed-artifact
// add-ons are staged, alongside the agent release runtime root.
func resolveAddonArtifactRoot(runtimeRoot string) string {
	return filepath.Join(resolveReleaseRuntimeRoot(runtimeRoot), addonsDirName)
}

// stageAddonArtifact fetches a pushed-artifact add-on from object storage, verifies
// its sha256 (and ed25519 signature when one is supplied), stages it in a versioned
// directory, and atomically publishes a `current` symlink. It returns the absolute
// path to the activated binary (under <root>/<addon_id>/current/).
func stageAddonArtifact(
	ctx context.Context,
	downloader ObjectStore,
	root string,
	a *proto.AddonAssignmentConfig,
) (string, error) {
	return stageAddonArtifactWithClient(ctx, downloader, nil, root, a)
}

// stageAddonArtifactWithClient is stageAddonArtifact with an optional gateway HTTP
// client. When the assignment carries a gateway download_url and httpClient is
// non-nil, the artifact is fetched over HTTPS through the agent-gateway artifact
// endpoint instead of the direct object store; the same sha256 + ed25519-signature
// verification is applied either way.
// When download_url is empty it falls back to the direct object store (internal
// agents with a kv_address).
func stageAddonArtifactWithClient(
	ctx context.Context,
	downloader ObjectStore,
	httpClient *http.Client,
	root string,
	a *proto.AddonAssignmentConfig,
) (string, error) {
	objectKey := strings.TrimSpace(a.GetArtifactObjectKey())
	wantSHA := strings.ToLower(strings.TrimSpace(a.GetArtifactSha256()))
	if objectKey == "" || wantSHA == "" {
		return "", ErrAddonArtifactIncomplete
	}

	addonID := strings.TrimSpace(a.GetAddonId())
	version := addonStagedVersion(a, wantSHA)

	// addon_id and version come from the control plane and become path segments under
	// the staging root, so reject anything that is not a single safe segment (no
	// separators, no "." / ".." traversal) before fetching or touching the filesystem.
	if !safeAddonSegment(addonID) {
		return "", fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}
	if !safeAddonSegment(version) {
		return "", fmt.Errorf("%w: version %q", ErrAddonUnsafePath, version)
	}

	binName := addonBinaryName(a)
	addonDir := filepath.Join(root, addonID)
	versionDir := filepath.Join(addonDir, addonVersionsDir, version)
	resolvedBinary := filepath.Join(addonDir, addonCurrentLink, binName)
	if stagedAddonArtifactCurrent(addonDir, versionDir, version, binName, wantSHA, a.GetArtifactSignature()) {
		return resolvedBinary, nil
	}

	data, err := fetchAddonArtifactBytes(ctx, downloader, httpClient, a, objectKey)
	if err != nil {
		return "", err
	}

	// Verify the digest with the shared constant-time helper before touching disk.
	sum := sha256.Sum256(data)
	if !hashutil.EqualSHA256(wantSHA, sum) {
		return "", fmt.Errorf("%w: %s", ErrAddonArtifactHashMismatch, objectKey)
	}

	// Verify the artifact signature when the control plane supplied one. Signing is
	// finalized by the build/signing pipeline (add-native-addon-build-signing); until
	// then the caller decides whether to allow an unsigned artifact through.
	if sig := strings.TrimSpace(a.GetArtifactSignature()); sig != "" {
		if err := verifyAddonArtifactSignature(data, sig); err != nil {
			return "", err
		}
	}

	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		return "", fmt.Errorf("create addon version dir: %w", err)
	}

	// A pushed artifact is either a bare executable (single-binary add-ons) or a gzip
	// tarball bundling the binary plus its manifest/config and any systemd unit files.
	// The sha256/signature above covered the raw artifact bytes either way; the tarball
	// is extracted into the version dir so the agent (discovery) and updater (setcap /
	// systemd install) see the binary and units side by side under `current`.
	if isGzipArtifact(data) {
		if err := extractAddonTarball(versionDir, data, binName); err != nil {
			return "", err
		}
	} else if err := writeAddonBinaryAtomic(filepath.Join(versionDir, binName), data); err != nil {
		return "", err
	}

	if err := writeAddonStageMetadata(versionDir, addonStageMetadata{
		AddonID:        addonID,
		Version:        version,
		BinaryName:     binName,
		ArtifactObject: objectKey,
		ArtifactSHA256: wantSHA,
		Signature:      strings.TrimSpace(a.GetArtifactSignature()),
	}); err != nil {
		return "", err
	}

	// Publish current -> versions/<version> atomically so a concurrent reader never
	// observes a half-written link.
	if err := switchAddonCurrentSymlink(addonDir, filepath.Join(addonVersionsDir, version)); err != nil {
		return "", err
	}

	return resolvedBinary, nil
}

func stagedAddonArtifactCurrent(addonDir, versionDir, version, binName, wantSHA, signature string) bool {
	target, ok := readAddonCurrentTarget(addonDir)
	if !ok || target != filepath.Join(addonVersionsDir, version) {
		return false
	}

	data, err := os.ReadFile(filepath.Join(versionDir, addonStageMetaFile))
	if err != nil {
		return false
	}

	var meta addonStageMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return false
	}

	if strings.TrimSpace(meta.Version) != version ||
		strings.TrimSpace(meta.BinaryName) != binName ||
		strings.ToLower(strings.TrimSpace(meta.ArtifactSHA256)) != wantSHA ||
		strings.TrimSpace(meta.Signature) != strings.TrimSpace(signature) {
		return false
	}

	info, err := os.Stat(filepath.Join(versionDir, binName))
	return err == nil && info.Mode().IsRegular()
}

func writeAddonStageMetadata(versionDir string, meta addonStageMetadata) error {
	data, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("marshal addon stage metadata: %w", err)
	}

	data = append(data, '\n')
	if err := writeAddonFileAtomic(filepath.Join(versionDir, addonStageMetaFile), data, addonManifestMode); err != nil {
		return fmt.Errorf("write addon stage metadata: %w", err)
	}

	return nil
}

func systemdAddonActivationCurrent(
	versionDir, version, binName, wantSHA, signature string,
	configSHA string,
	units []string,
) bool {
	data, err := os.ReadFile(filepath.Join(versionDir, addonSystemdActivationMetaFile))
	if err != nil {
		return false
	}

	var meta addonSystemdActivationMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return false
	}

	return strings.TrimSpace(meta.Version) == version &&
		strings.TrimSpace(meta.BinaryName) == binName &&
		strings.ToLower(strings.TrimSpace(meta.ArtifactSHA256)) == wantSHA &&
		strings.TrimSpace(meta.Signature) == strings.TrimSpace(signature) &&
		strings.TrimSpace(meta.ConfigSHA256) == strings.TrimSpace(configSHA) &&
		sameStringSet(meta.Units, units)
}

func writeAddonSystemdActivationMetadata(versionDir string, meta addonSystemdActivationMetadata) error {
	meta.Units = sortedStrings(meta.Units)

	data, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("marshal addon systemd activation metadata: %w", err)
	}

	data = append(data, '\n')
	if err := writeAddonFileAtomic(filepath.Join(versionDir, addonSystemdActivationMetaFile), data, addonManifestMode); err != nil {
		return fmt.Errorf("write addon systemd activation metadata: %w", err)
	}

	return nil
}

func addonAssignmentConfigSHA256(configJSON []byte) string {
	configJSON = bytes.TrimSpace(configJSON)
	if len(configJSON) == 0 {
		return ""
	}

	sum := sha256.Sum256(configJSON)
	return fmt.Sprintf("%x", sum[:])
}

func applyStagedAddonRuntimeConfig(runtimeRoot string, a *proto.AddonAssignmentConfig) error {
	configJSON := bytes.TrimSpace(a.GetConfigJson())
	if len(configJSON) == 0 {
		return nil
	}

	addonID := strings.TrimSpace(a.GetAddonId())
	if !safeAddonSegment(addonID) {
		return fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}

	currentDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID, addonCurrentLink)
	configName, err := selectStagedAddonRuntimeConfig(currentDir, addonID)
	if err != nil {
		return err
	}
	if configName == "" {
		return nil
	}

	configPath := filepath.Join(currentDir, configName)
	basePath := filepath.Join(currentDir, ".serviceradar-config-base-"+configName)

	baseConfig, err := os.ReadFile(basePath)
	if errors.Is(err, os.ErrNotExist) {
		baseConfig, err = os.ReadFile(configPath)
		if err != nil {
			return fmt.Errorf("read staged addon config: %w", err)
		}
		if err := writeAddonFileAtomic(basePath, baseConfig, addonManifestMode); err != nil {
			return fmt.Errorf("preserve staged addon config base: %w", err)
		}
	} else if err != nil {
		return fmt.Errorf("read staged addon config base: %w", err)
	}

	mergedConfig, err := mergeAddonRuntimeConfig(baseConfig, configJSON)
	if err != nil {
		return err
	}

	if err := writeAddonFileAtomic(configPath, mergedConfig, addonManifestMode); err != nil {
		return fmt.Errorf("write staged addon runtime config: %w", err)
	}

	return nil
}

func selectStagedAddonRuntimeConfig(dir, addonID string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", fmt.Errorf("read staged addon dir: %w", err)
	}

	candidates := make([]string, 0, 1)
	preferred := addonID + ".json"
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		name := entry.Name()
		if name == preferred {
			return name, nil
		}
		if strings.HasPrefix(name, ".serviceradar-") ||
			name == "config.schema.json" ||
			!strings.HasSuffix(name, ".json") {
			continue
		}

		candidates = append(candidates, name)
	}

	switch len(candidates) {
	case 0:
		return "", nil
	case 1:
		return candidates[0], nil
	default:
		sort.Strings(candidates)
		return "", fmt.Errorf("%w: %s", ErrAddonRuntimeConfigAmbiguous, strings.Join(candidates, ", "))
	}
}

func mergeAddonRuntimeConfig(baseConfig, overrideConfig []byte) ([]byte, error) {
	var base map[string]any
	var override map[string]any
	if err := json.Unmarshal(baseConfig, &base); err != nil {
		return nil, fmt.Errorf("decode staged addon config base: %w", err)
	}
	if err := json.Unmarshal(overrideConfig, &override); err != nil {
		return nil, fmt.Errorf("decode addon assignment config: %w", err)
	}

	for key, value := range override {
		base[key] = value
	}

	out, err := json.MarshalIndent(base, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("encode merged addon config: %w", err)
	}

	return append(out, '\n'), nil
}

func sameStringSet(a, b []string) bool {
	a = sortedStrings(a)
	b = sortedStrings(b)
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}

	return true
}

func sortedStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := append([]string(nil), values...)
	sort.Strings(out)

	return out
}

// fetchAddonArtifactBytes returns the raw artifact bytes, preferring the gateway-proxied
// HTTPS download (download_url + download_token) when the assignment carries one and an
// HTTP client is available, mirroring the WASM plugin download path. It falls back to the
// direct object store otherwise. The bytes are returned UNVERIFIED; the caller applies the
// sha256 + ed25519-signature checks regardless of which path produced them.
func fetchAddonArtifactBytes(
	ctx context.Context,
	downloader ObjectStore,
	httpClient *http.Client,
	a *proto.AddonAssignmentConfig,
	objectKey string,
) ([]byte, error) {
	if downloadURL := strings.TrimSpace(a.GetDownloadUrl()); downloadURL != "" {
		if httpClient == nil {
			return nil, ErrAddonObjectStoreUnavailable
		}

		data, err := downloadAddonArtifactHTTP(ctx, httpClient, downloadURL, a.GetDownloadToken())
		if err != nil {
			return nil, fmt.Errorf("download addon artifact via gateway: %w", err)
		}

		return data, nil
	}

	// No gateway download URL: fall back to the direct object store (internal agents
	// configured with a kv_address).
	if downloader == nil {
		return nil, ErrAddonObjectStoreUnavailable
	}

	data, err := downloader.DownloadObject(ctx, objectKey)
	if err != nil {
		return nil, fmt.Errorf("download addon artifact %q: %w", objectKey, err)
	}

	return data, nil
}

// downloadAddonArtifactHTTP fetches an add-on artifact from the agent-gateway artifact
// endpoint over HTTPS, presenting the per-poll signed download token in the
// X-ServiceRadar-Plugin-Token header (the same header the WASM plugin download uses). The
// response body is bounded to the maximum add-on tarball size to guard against a hostile
// or misbehaving endpoint. The returned bytes are unverified; the caller still checks the
// sha256 and ed25519 signature.
func downloadAddonArtifactHTTP(ctx context.Context, client *http.Client, downloadURL, token string) ([]byte, error) {
	return downloadGatewayArtifactHTTP(
		ctx,
		client,
		downloadURL,
		token,
		maxAddonTarballBytes,
		ErrAddonArtifactDownloadFailed,
		ErrAddonTarballTooLarge,
	)
}

// verifyAddonArtifactSignature verifies an ed25519 signature over the artifact bytes
// using the agent release trust root (reused per the 3425 decision to share the
// existing signing key); the build/signing pipeline finalizes key management.
func verifyAddonArtifactSignature(data []byte, signature string) error {
	key, err := releaseVerificationKey()
	if err != nil {
		return fmt.Errorf("addon signature verification key: %w", err)
	}

	sig, err := decodeReleaseSignature(signature)
	if err != nil {
		return fmt.Errorf("decode addon signature: %w", err)
	}

	if !ed25519.Verify(key, data, sig) {
		return ErrAddonSignatureInvalid
	}

	return nil
}

// addonStagedVersion picks a stable directory name for the staged artifact: the
// assigned version when present, otherwise a short prefix of the content digest.
func addonStagedVersion(a *proto.AddonAssignmentConfig, sha string) string {
	if v := strings.TrimSpace(a.GetVersion()); v != "" {
		return v
	}

	if len(sha) > 12 {
		return sha[:12]
	}

	return sha
}

// addonBinaryName derives the staged binary filename from the assignment's
// binary_path basename, falling back to a name derived from the add-on id. The
// basename must itself be a safe single path segment (rejecting "..", separators,
// etc.) so a crafted binary_path cannot escape the staging dir.
func addonBinaryName(a *proto.AddonAssignmentConfig) string {
	if bp := strings.TrimSpace(a.GetBinaryPath()); bp != "" {
		if base := filepath.Base(bp); safeAddonSegment(base) {
			return base
		}
	}

	return "serviceradar-" + strings.TrimSpace(a.GetAddonId()) + "-addon"
}

// isGzipArtifact reports whether data begins with the gzip magic bytes, distinguishing
// a tarball pushed-artifact from a bare executable.
func isGzipArtifact(data []byte) bool {
	return len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b
}

// extractAddonTarball extracts a gzip tarball pushed-artifact into versionDir. Every
// entry MUST be a regular file named as a single safe path segment (no directories,
// symlinks, hardlinks, or "../" traversal); the add-on binary (binName) is written
// executable, all other files 0644. The binary must be present. Entry count and sizes
// are bounded to guard against a decompression bomb in a malformed/hostile artifact.
func extractAddonTarball(versionDir string, data []byte, binName string) error {
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("open addon tarball: %w", err)
	}
	defer func() { _ = gz.Close() }()

	tr := tar.NewReader(gz)
	var (
		entries   int
		totalSize int64
		sawBinary bool
	)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read addon tarball: %w", err)
		}

		entries++
		if entries > maxAddonTarballEntries {
			return fmt.Errorf("%w: more than %d entries", ErrAddonTarballTooLarge, maxAddonTarballEntries)
		}
		if hdr.Typeflag != tar.TypeReg {
			return fmt.Errorf("%w: %q is not a regular file", ErrAddonTarballUnsafe, hdr.Name)
		}
		if !safeAddonSegment(hdr.Name) {
			return fmt.Errorf("%w: entry name %q", ErrAddonTarballUnsafe, hdr.Name)
		}
		if hdr.Size < 0 || hdr.Size > maxAddonTarballFileBytes {
			return fmt.Errorf("%w: %q is %d bytes", ErrAddonTarballTooLarge, hdr.Name, hdr.Size)
		}

		// Read with a hard cap (one byte over the per-file limit) so a header that
		// understates Size still cannot blow past the bound.
		content, err := io.ReadAll(io.LimitReader(tr, maxAddonTarballFileBytes+1))
		if err != nil {
			return fmt.Errorf("read addon tarball entry %q: %w", hdr.Name, err)
		}
		if int64(len(content)) > maxAddonTarballFileBytes {
			return fmt.Errorf("%w: %q exceeds per-file limit", ErrAddonTarballTooLarge, hdr.Name)
		}
		totalSize += int64(len(content))
		if totalSize > maxAddonTarballBytes {
			return fmt.Errorf("%w: total extracted size exceeds limit", ErrAddonTarballTooLarge)
		}

		mode := os.FileMode(addonManifestMode)
		if hdr.Name == binName {
			mode = addonBinaryMode
			sawBinary = true
		}
		if err := writeAddonFileAtomic(filepath.Join(versionDir, hdr.Name), content, mode); err != nil {
			return err
		}
	}

	if !sawBinary {
		return fmt.Errorf("%w: %q", ErrAddonTarballBinaryMissing, binName)
	}

	return nil
}

// writeAddonBinaryAtomic writes the add-on executable atomically (mode 0755).
func writeAddonBinaryAtomic(path string, data []byte) error {
	return writeAddonFileAtomic(path, data, addonBinaryMode)
}

// writeAddonFileAtomic writes data to path via a temp file + rename, with the given mode.
func writeAddonFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".new"

	if err := os.WriteFile(tmp, data, mode); err != nil {
		return fmt.Errorf("write addon file: %w", err)
	}

	// WriteFile honors umask, so set the mode explicitly.
	if err := os.Chmod(tmp, mode); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("chmod addon file: %w", err)
	}

	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish addon file: %w", err)
	}

	return nil
}

func switchAddonCurrentSymlink(addonDir, target string) error {
	currentPath := filepath.Join(addonDir, addonCurrentLink)
	tempPath := currentPath + ".new"

	_ = os.Remove(tempPath)

	if err := os.Symlink(target, tempPath); err != nil {
		return fmt.Errorf("create addon current symlink: %w", err)
	}

	if err := os.Rename(tempPath, currentPath); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("publish addon current symlink: %w", err)
	}

	return nil
}

// readAddonCurrentTarget returns the target of the add-on's `current` symlink (the
// relative versions/<version> path it points at) and whether it exists. Callers
// capture this BEFORE staging a new version so they can roll the symlink back to the
// previously-active version if a subsequent activation step (capability application,
// unit install, launch) fails. ok is false when no `current` symlink is present yet
// (a first-time activation has nothing to roll back to).
func readAddonCurrentTarget(addonDir string) (string, bool) {
	target, err := os.Readlink(filepath.Join(addonDir, addonCurrentLink))
	if err != nil {
		return "", false
	}

	target = strings.TrimSpace(target)
	if target == "" {
		return "", false
	}

	return target, true
}

// rollbackAddonCurrent restores an add-on's `current` symlink after a failed
// activation. When priorTarget is empty the activation was a first-time install with
// no previous version, so `current` is removed (the add-on simply does not activate).
// Otherwise `current` is atomically re-pointed at priorTarget; if that prior version
// directory no longer exists, rollback fails with ErrAddonRollbackTargetMissing rather
// than publishing a dangling symlink. addonID is validated as a safe path segment to
// keep the staging-root traversal guarantees that stageAddonArtifact relies on.
func rollbackAddonCurrent(root, addonID, priorTarget string) error {
	if !safeAddonSegment(addonID) {
		return fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}

	addonDir := filepath.Join(root, addonID)
	currentPath := filepath.Join(addonDir, addonCurrentLink)

	if priorTarget == "" {
		// No previous version to restore to: drop the symlink so a failed first-time
		// activation does not leave `current` pointing at the unusable new version.
		if err := os.Remove(currentPath); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove addon current symlink during rollback: %w", err)
		}

		return nil
	}

	// Refuse to restore a symlink to a version directory that is gone, which would
	// leave `current` dangling. priorTarget is a trusted value previously read from
	// our own symlink, but verify the directory is still present before re-pointing.
	if info, err := os.Stat(filepath.Join(addonDir, priorTarget)); err != nil || !info.IsDir() {
		return fmt.Errorf("%w: %s", ErrAddonRollbackTargetMissing, priorTarget)
	}

	if err := switchAddonCurrentSymlink(addonDir, priorTarget); err != nil {
		return fmt.Errorf("restore addon current symlink during rollback: %w", err)
	}

	return nil
}

// addonLocalOverridePath returns the path to the local add-on override file within
// the agent config directory.
func addonLocalOverridePath(configDir string) string {
	return filepath.Join(configDir, addonLocalOverrideFile)
}

// localAddonAssignmentsFile is the on-disk schema of the local override file.
type localAddonAssignmentsFile struct {
	Addons []localAddonAssignment `json:"addons"`
}

// localAddonAssignment mirrors AddonAssignmentConfig in operator-friendly JSON for
// the local override file. Enabled is a pointer so an omitted value defaults to true
// (an override entry is normally present to enable an add-on).
type localAddonAssignment struct {
	AddonID           string          `json:"addon_id"`
	Version           string          `json:"version"`
	Enabled           *bool           `json:"enabled"`
	BinaryPath        string          `json:"binary_path"`
	Args              []string        `json:"args"`
	ConfigJSON        json.RawMessage `json:"config_json"`
	Capabilities      []string        `json:"capabilities"`
	Delivery          string          `json:"delivery"`
	Supervision       string          `json:"supervision"`
	ArtifactObjectKey string          `json:"artifact_object_key"`
	ArtifactSha256    string          `json:"artifact_sha256"`
	ArtifactSignature string          `json:"artifact_signature"`
	TargetOS          string          `json:"target_os"`
	TargetArch        string          `json:"target_arch"`
}

// toProto builds a proto assignment for a local-only override (no pushed assignment
// to inherit from); it defaults to enabled.
func (o localAddonAssignment) toProto() *proto.AddonAssignmentConfig {
	return o.mergeOnto(&proto.AddonAssignmentConfig{AddonId: strings.TrimSpace(o.AddonID), Enabled: true})
}

// mergeOnto returns base patched with the fields the override actually specifies. An
// omitted field (empty string, nil pointer, or empty list) leaves the base value
// intact, so an operator can pin a single field (e.g. binary_path to a dev build)
// without silently blanking the pushed config, capabilities, or artifact reference.
func (o localAddonAssignment) mergeOnto(base *proto.AddonAssignmentConfig) *proto.AddonAssignmentConfig {
	merged := &proto.AddonAssignmentConfig{
		AddonId:           base.GetAddonId(),
		Version:           base.GetVersion(),
		Enabled:           base.GetEnabled(),
		BinaryPath:        base.GetBinaryPath(),
		Args:              base.GetArgs(),
		ConfigJson:        base.GetConfigJson(),
		Capabilities:      base.GetCapabilities(),
		Delivery:          base.GetDelivery(),
		Supervision:       base.GetSupervision(),
		ArtifactObjectKey: base.GetArtifactObjectKey(),
		ArtifactSha256:    base.GetArtifactSha256(),
		ArtifactSignature: base.GetArtifactSignature(),
		TargetOs:          base.GetTargetOs(),
		TargetArch:        base.GetTargetArch(),
	}

	if o.Enabled != nil {
		merged.Enabled = *o.Enabled
	}
	if o.Version != "" {
		merged.Version = o.Version
	}
	if o.BinaryPath != "" {
		merged.BinaryPath = o.BinaryPath
	}
	if len(o.Args) > 0 {
		merged.Args = o.Args
	}
	if len(o.ConfigJSON) > 0 {
		merged.ConfigJson = []byte(o.ConfigJSON)
	}
	if len(o.Capabilities) > 0 {
		merged.Capabilities = o.Capabilities
	}
	if o.Delivery != "" {
		merged.Delivery = o.Delivery
	}
	if o.Supervision != "" {
		merged.Supervision = o.Supervision
	}
	if o.ArtifactObjectKey != "" {
		merged.ArtifactObjectKey = o.ArtifactObjectKey
	}
	if o.ArtifactSha256 != "" {
		merged.ArtifactSha256 = o.ArtifactSha256
	}
	if o.ArtifactSignature != "" {
		merged.ArtifactSignature = o.ArtifactSignature
	}
	if o.TargetOS != "" {
		merged.TargetOs = o.TargetOS
	}
	if o.TargetArch != "" {
		merged.TargetArch = o.TargetArch
	}

	return merged
}

// applyLocalAddonOverrides patches an operator-managed local override file onto the
// pushed add-on assignments. For a matching addon_id the override patches only the
// fields it specifies (others are inherited from the pushed assignment); local-only
// entries are appended, preserving file order (the last entry wins for a duplicate
// addon_id). A missing file is a no-op; a malformed file returns the pushed
// assignments unchanged plus an error so the caller can log it without breaking
// pushed delivery.
func applyLocalAddonOverrides(
	pushed []*proto.AddonAssignmentConfig,
	path string,
) ([]*proto.AddonAssignmentConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return pushed, nil
		}

		return pushed, fmt.Errorf("read addon override %q: %w", path, err)
	}

	var file localAddonAssignmentsFile
	if err := json.Unmarshal(data, &file); err != nil {
		return pushed, fmt.Errorf("parse addon override %q: %w", path, err)
	}

	if len(file.Addons) == 0 {
		return pushed, nil
	}

	overrides := make(map[string]localAddonAssignment, len(file.Addons))
	order := make([]string, 0, len(file.Addons))

	for _, o := range file.Addons {
		id := strings.TrimSpace(o.AddonID)
		if id == "" {
			continue
		}

		if _, seen := overrides[id]; !seen {
			order = append(order, id)
		}

		overrides[id] = o
	}

	merged := make([]*proto.AddonAssignmentConfig, 0, len(pushed)+len(order))
	used := make(map[string]bool, len(order))

	for _, a := range pushed {
		if a == nil {
			continue
		}

		if ov, ok := overrides[a.GetAddonId()]; ok {
			merged = append(merged, ov.mergeOnto(a))
			used[a.GetAddonId()] = true

			continue
		}

		merged = append(merged, a)
	}

	for _, id := range order {
		if !used[id] {
			merged = append(merged, overrides[id].toProto())
		}
	}

	return merged, nil
}
