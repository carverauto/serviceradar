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
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/hashutil"
	"github.com/carverauto/serviceradar/proto"
)

const (
	addonsDirName    = "addons"
	addonVersionsDir = "versions"
	addonCurrentLink = "current"
	addonBinaryMode  = 0o755

	// addonLocalOverrideFile is the operator-managed local override (break-glass /
	// dev) read from the agent config dir; its entries take precedence over pushed
	// assignments with the same addon_id.
	addonLocalOverrideFile = "addons.local.json"
)

var (
	// ErrAddonObjectStoreUnavailable is returned when a pushed-artifact add-on is
	// assigned but the agent has no object store configured to fetch it from.
	ErrAddonObjectStoreUnavailable = errors.New("addon object store unavailable")
	// ErrAddonArtifactIncomplete is returned when the assignment is missing the
	// object key or expected sha256 required to fetch and verify the artifact.
	ErrAddonArtifactIncomplete = errors.New("addon artifact reference incomplete")
	// ErrAddonArtifactHashMismatch is returned when the fetched artifact does not
	// match the expected sha256.
	ErrAddonArtifactHashMismatch = errors.New("addon artifact sha256 mismatch")
	// ErrAddonSignatureInvalid is returned when a supplied artifact signature fails
	// ed25519 verification.
	ErrAddonSignatureInvalid = errors.New("addon artifact signature invalid")
	// ErrAddonUnsafePath is returned when an add-on id or version would not form a
	// single safe path segment under the staging root (path-traversal guard).
	ErrAddonUnsafePath = errors.New("addon id or version is not a safe path segment")
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
	if downloader == nil {
		return "", ErrAddonObjectStoreUnavailable
	}

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

	data, err := downloader.DownloadObject(ctx, objectKey)
	if err != nil {
		return "", fmt.Errorf("download addon artifact %q: %w", objectKey, err)
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

	binName := addonBinaryName(a)

	addonDir := filepath.Join(root, addonID)
	versionDir := filepath.Join(addonDir, addonVersionsDir, version)
	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		return "", fmt.Errorf("create addon version dir: %w", err)
	}

	if err := writeAddonBinaryAtomic(filepath.Join(versionDir, binName), data); err != nil {
		return "", err
	}

	// Publish current -> versions/<version> atomically so a concurrent reader never
	// observes a half-written link.
	if err := switchAddonCurrentSymlink(addonDir, filepath.Join(addonVersionsDir, version)); err != nil {
		return "", err
	}

	return filepath.Join(addonDir, addonCurrentLink, binName), nil
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

func writeAddonBinaryAtomic(path string, data []byte) error {
	tmp := path + ".new"

	if err := os.WriteFile(tmp, data, addonBinaryMode); err != nil {
		return fmt.Errorf("write addon artifact: %w", err)
	}

	// WriteFile honors umask, so set the executable bit explicitly.
	if err := os.Chmod(tmp, addonBinaryMode); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("chmod addon artifact: %w", err)
	}

	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish addon artifact: %w", err)
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
