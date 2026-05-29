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
)

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

	addonID := strings.TrimSpace(a.GetAddonId())
	version := addonStagedVersion(a, wantSHA)
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

// lastKnownGoodAddonBinary returns the path to the previously activated binary for
// the add-on (the target of its `current` symlink) when it still resolves to a
// regular file. The versioned staging directory doubles as the last-known-good
// cache: when a fresh delivery or verification fails, the caller falls back to this
// path so a transient object-store/signature failure does not tear down a running
// add-on. Returns ("", false) when nothing has been staged yet.
func lastKnownGoodAddonBinary(root string, a *proto.AddonAssignmentConfig) (string, bool) {
	addonID := strings.TrimSpace(a.GetAddonId())
	if addonID == "" {
		return "", false
	}

	binPath := filepath.Join(root, addonID, addonCurrentLink, addonBinaryName(a))

	// os.Stat follows the current -> versions/<v> symlink, so this confirms the
	// real staged binary still exists.
	if info, err := os.Stat(binPath); err == nil && info.Mode().IsRegular() {
		return binPath, true
	}

	return "", false
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
// binary_path basename, falling back to a name derived from the add-on id.
func addonBinaryName(a *proto.AddonAssignmentConfig) string {
	if bp := strings.TrimSpace(a.GetBinaryPath()); bp != "" {
		if base := filepath.Base(bp); base != "." && base != string(filepath.Separator) {
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
