/*
 * Copyright 2025 Carver Automation Corporation.
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

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const (
	defaultReleaseRuntimeRoot        = "/var/lib/serviceradar/agent/releases"
	releaseVersionsDirName           = "versions"
	releaseTmpDirName                = "tmp"
	releaseMetadataFileName          = ".serviceradar-release.json"
	releaseDefaultEntrypoint         = "serviceradar-agent"
	releaseArtifactFormatTarGz       = "tar.gz"
	releaseArtifactMaxBytes    int64 = 256 * 1024 * 1024

	releasePublicKeyEnv = "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
	releaseRuntimeEnv   = "SERVICERADAR_AGENT_RUNTIME_ROOT"
)

var (
	errReleaseVersionRequired         = errors.New("release version is required")
	errReleaseManifestMissing         = errors.New("release manifest is required")
	errReleaseSignatureMissing        = errors.New("release signature is required")
	errReleaseArtifactURLMissing      = errors.New("release artifact url is required")
	errReleaseArtifactHashMissing     = errors.New("release artifact sha256 is required")
	errReleaseVerificationKeyUnset    = errors.New("release verification key is not configured")
	errReleaseSignatureInvalid        = errors.New("release manifest signature verification failed")
	errReleaseArchiveUnsupported      = errors.New("release archive contains unsupported entry")
	errReleaseEntrypointMissing       = errors.New("release entrypoint not found after extraction")
	errReleaseVersionPathInvalid      = errors.New("release version cannot be used as a directory name")
	errReleaseManifestVersionMismatch = errors.New("release manifest version does not match command version")
	errReleasePublicKeyLengthInvalid  = errors.New("release public key length is invalid")
	errReleaseSignatureEncoding       = errors.New("unsupported signature encoding")
	errReleaseMetadataConflict        = errors.New("staged release already exists with different metadata")
)

// ReleaseSigningPublicKey is set at build time for managed release verification.
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var ReleaseSigningPublicKey = ""

type releaseUpdatePayload struct {
	ReleaseID string                 `json:"release_id,omitempty"`
	RolloutID string                 `json:"rollout_id,omitempty"`
	TargetID  string                 `json:"target_id,omitempty"`
	Version   string                 `json:"version,omitempty"`
	Manifest  map[string]interface{} `json:"manifest,omitempty"`
	Signature string                 `json:"signature,omitempty"`
	Artifact  releaseArtifactPayload `json:"artifact"`
}

type releaseArtifactPayload struct {
	URL        string `json:"url,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	OS         string `json:"os,omitempty"`
	Arch       string `json:"arch,omitempty"`
	Format     string `json:"format,omitempty"`
	Entrypoint string `json:"entrypoint,omitempty"`
}

type releaseStageResult struct {
	Version        string
	RuntimeRoot    string
	VersionDir     string
	EntrypointPath string
	ArtifactSHA256 string
}

type releaseMetadata struct {
	Version     string `json:"version"`
	SHA256      string `json:"sha256"`
	URL         string `json:"url"`
	Entrypoint  string `json:"entrypoint"`
	ReleaseID   string `json:"release_id,omitempty"`
	RolloutID   string `json:"rollout_id,omitempty"`
	TargetID    string `json:"target_id,omitempty"`
	StagedAtUTC string `json:"staged_at_utc"`
}

type releaseStageConfig struct {
	HTTPClient  *http.Client
	Logger      logger.Logger
	RuntimeRoot string
}

func stageAgentRelease(ctx context.Context, payload releaseUpdatePayload, cfg releaseStageConfig) (releaseStageResult, error) {
	payload = normalizeReleasePayload(payload)
	if err := validateReleasePayload(payload); err != nil {
		return releaseStageResult{}, err
	}

	manifestJSON, err := marshalCanonicalJSON(payload.Manifest)
	if err != nil {
		return releaseStageResult{}, fmt.Errorf("marshal manifest: %w", err)
	}
	if err := verifyReleaseManifestSignature(manifestJSON, payload.Signature); err != nil {
		return releaseStageResult{}, err
	}

	data, err := downloadReleaseArtifact(ctx, cfg.HTTPClient, payload.Artifact.URL)
	if err != nil {
		return releaseStageResult{}, err
	}
	if err := verifyContentHash(data, payload.Artifact.SHA256); err != nil {
		return releaseStageResult{}, err
	}

	runtimeRoot := resolveReleaseRuntimeRoot(cfg.RuntimeRoot)
	versionDir, err := releaseVersionDir(runtimeRoot, payload.Version)
	if err != nil {
		return releaseStageResult{}, err
	}

	if existing, ok, err := loadExistingRelease(versionDir, payload); err != nil {
		return releaseStageResult{}, err
	} else if ok {
		return existing, nil
	}

	if err := os.MkdirAll(filepath.Join(runtimeRoot, releaseVersionsDirName), 0o755); err != nil {
		return releaseStageResult{}, fmt.Errorf("create release versions dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(runtimeRoot, releaseTmpDirName), 0o755); err != nil {
		return releaseStageResult{}, fmt.Errorf("create release tmp dir: %w", err)
	}

	tempDir, err := os.MkdirTemp(filepath.Join(runtimeRoot, releaseTmpDirName), "stage-*")
	if err != nil {
		return releaseStageResult{}, fmt.Errorf("create release staging dir: %w", err)
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(tempDir)
		}
	}()

	entrypointRel, err := stageReleasePayload(tempDir, payload.Artifact, data)
	if err != nil {
		return releaseStageResult{}, err
	}

	if err := writeReleaseMetadata(tempDir, payload, entrypointRel); err != nil {
		return releaseStageResult{}, err
	}

	if err := os.Rename(tempDir, versionDir); err != nil {
		if errors.Is(err, os.ErrExist) {
			if existing, ok, loadErr := loadExistingRelease(versionDir, payload); loadErr == nil && ok {
				return existing, nil
			}
		}
		return releaseStageResult{}, fmt.Errorf("publish staged release: %w", err)
	}

	return releaseStageResult{
		Version:        payload.Version,
		RuntimeRoot:    runtimeRoot,
		VersionDir:     versionDir,
		EntrypointPath: filepath.Join(versionDir, entrypointRel),
		ArtifactSHA256: payload.Artifact.SHA256,
	}, nil
}

func normalizeReleasePayload(payload releaseUpdatePayload) releaseUpdatePayload {
	payload.ReleaseID = strings.TrimSpace(payload.ReleaseID)
	payload.RolloutID = strings.TrimSpace(payload.RolloutID)
	payload.TargetID = strings.TrimSpace(payload.TargetID)
	payload.Version = strings.TrimSpace(payload.Version)
	payload.Signature = strings.TrimSpace(payload.Signature)
	payload.Artifact.URL = strings.TrimSpace(payload.Artifact.URL)
	payload.Artifact.SHA256 = strings.TrimSpace(payload.Artifact.SHA256)
	payload.Artifact.OS = strings.TrimSpace(payload.Artifact.OS)
	payload.Artifact.Arch = strings.TrimSpace(payload.Artifact.Arch)
	payload.Artifact.Format = strings.TrimSpace(payload.Artifact.Format)
	payload.Artifact.Entrypoint = strings.TrimSpace(payload.Artifact.Entrypoint)
	return payload
}

func validateReleasePayload(payload releaseUpdatePayload) error {
	switch {
	case payload.Version == "":
		return errReleaseVersionRequired
	case len(payload.Manifest) == 0:
		return errReleaseManifestMissing
	case payload.Signature == "":
		return errReleaseSignatureMissing
	case payload.Artifact.URL == "":
		return errReleaseArtifactURLMissing
	case payload.Artifact.SHA256 == "":
		return errReleaseArtifactHashMissing
	default:
		manifestVersion, _ := payload.Manifest["version"].(string)
		if manifestVersion != "" && strings.TrimSpace(manifestVersion) != payload.Version {
			return fmt.Errorf("%w: manifest=%q command=%q", errReleaseManifestVersionMismatch, manifestVersion, payload.Version)
		}
		return nil
	}
}

func verifyReleaseManifestSignature(manifestJSON []byte, signature string) error {
	publicKey, err := releaseVerificationKey()
	if err != nil {
		return err
	}
	sig, err := decodeReleaseSignature(signature)
	if err != nil {
		return fmt.Errorf("decode release signature: %w", err)
	}
	if !ed25519.Verify(publicKey, manifestJSON, sig) {
		return errReleaseSignatureInvalid
	}
	return nil
}

func releaseVerificationKey() (ed25519.PublicKey, error) {
	keyValue := strings.TrimSpace(os.Getenv(releasePublicKeyEnv))
	if keyValue == "" {
		keyValue = strings.TrimSpace(ReleaseSigningPublicKey)
	}
	if keyValue == "" {
		return nil, errReleaseVerificationKeyUnset
	}
	decoded, err := decodeReleaseSignature(keyValue)
	if err != nil {
		return nil, fmt.Errorf("decode release public key: %w", err)
	}
	if len(decoded) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: expected %d bytes, got %d", errReleasePublicKeyLengthInvalid, ed25519.PublicKeySize, len(decoded))
	}
	return ed25519.PublicKey(decoded), nil
}

func decodeReleaseSignature(value string) ([]byte, error) {
	clean := strings.TrimSpace(value)
	if clean == "" {
		return nil, errReleaseSignatureMissing
	}

	if decoded, err := hex.DecodeString(clean); err == nil {
		return decoded, nil
	}

	base64Variants := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range base64Variants {
		if decoded, err := enc.DecodeString(clean); err == nil {
			return decoded, nil
		}
	}

	return nil, errReleaseSignatureEncoding
}

func resolveReleaseRuntimeRoot(configured string) string {
	if runtimeRoot := strings.TrimSpace(configured); runtimeRoot != "" {
		return runtimeRoot
	}
	if runtimeRoot := strings.TrimSpace(os.Getenv(releaseRuntimeEnv)); runtimeRoot != "" {
		return runtimeRoot
	}
	return defaultReleaseRuntimeRoot
}

func releaseVersionDir(runtimeRoot, version string) (string, error) {
	clean := strings.TrimSpace(version)
	if clean == "" || clean == "." || strings.Contains(clean, string(filepath.Separator)) || strings.Contains(clean, "..") {
		return "", errReleaseVersionPathInvalid
	}
	return filepath.Join(runtimeRoot, releaseVersionsDirName, clean), nil
}

func loadExistingRelease(versionDir string, payload releaseUpdatePayload) (releaseStageResult, bool, error) {
	data, err := os.ReadFile(filepath.Join(versionDir, releaseMetadataFileName))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return releaseStageResult{}, false, nil
		}
		return releaseStageResult{}, false, fmt.Errorf("read staged release metadata: %w", err)
	}

	var meta releaseMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return releaseStageResult{}, false, fmt.Errorf("decode staged release metadata: %w", err)
	}
	if meta.Version != payload.Version || !strings.EqualFold(strings.TrimSpace(meta.SHA256), strings.TrimSpace(payload.Artifact.SHA256)) {
		return releaseStageResult{}, false, fmt.Errorf("%w: version=%s", errReleaseMetadataConflict, payload.Version)
	}

	entrypointPath := filepath.Join(versionDir, meta.Entrypoint)
	if _, err := os.Stat(entrypointPath); err != nil {
		return releaseStageResult{}, false, fmt.Errorf("stat staged release entrypoint: %w", err)
	}

	return releaseStageResult{
		Version:        payload.Version,
		RuntimeRoot:    filepath.Dir(filepath.Dir(versionDir)),
		VersionDir:     versionDir,
		EntrypointPath: entrypointPath,
		ArtifactSHA256: payload.Artifact.SHA256,
	}, true, nil
}

func stageReleasePayload(tempDir string, artifact releaseArtifactPayload, data []byte) (string, error) {
	switch inferReleaseArtifactFormat(artifact) {
	case releaseArtifactFormatTarGz:
		return extractReleaseArchive(tempDir, data, artifact.Entrypoint)
	default:
		entrypoint := artifact.Entrypoint
		if entrypoint == "" {
			entrypoint = releaseDefaultEntrypoint
		}
		targetPath, err := safeJoin(tempDir, entrypoint)
		if err != nil {
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
			return "", fmt.Errorf("create release entrypoint dir: %w", err)
		}
		if err := os.WriteFile(targetPath, data, 0o755); err != nil {
			return "", fmt.Errorf("write release artifact: %w", err)
		}
		return filepath.Clean(entrypoint), nil
	}
}

func inferReleaseArtifactFormat(artifact releaseArtifactPayload) string {
	format := strings.ToLower(strings.TrimSpace(artifact.Format))
	switch format {
	case "tgz", releaseArtifactFormatTarGz, "tarball":
		return releaseArtifactFormatTarGz
	case "bin", "binary", "":
	default:
		return format
	}

	url := strings.ToLower(strings.TrimSpace(artifact.URL))
	if strings.HasSuffix(url, ".tar.gz") || strings.HasSuffix(url, ".tgz") {
		return releaseArtifactFormatTarGz
	}
	return "binary"
}

func extractReleaseArchive(dest string, data []byte, configuredEntrypoint string) (string, error) {
	gzr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return "", fmt.Errorf("open release archive: %w", err)
	}
	defer func() { _ = gzr.Close() }()

	tr := tar.NewReader(gzr)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", fmt.Errorf("read release archive: %w", err)
		}

		name := strings.TrimPrefix(hdr.Name, "./")
		targetPath, err := safeJoin(dest, name)
		if err != nil {
			return "", fmt.Errorf("release archive path %q: %w", hdr.Name, err)
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0o755); err != nil {
				return "", fmt.Errorf("create release dir: %w", err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
				return "", fmt.Errorf("create release file dir: %w", err)
			}
			file, err := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)&0o777)
			if err != nil {
				return "", fmt.Errorf("create release file: %w", err)
			}
			if _, err := io.Copy(file, tr); err != nil {
				_ = file.Close()
				return "", fmt.Errorf("write release file: %w", err)
			}
			if err := file.Close(); err != nil {
				return "", fmt.Errorf("close release file: %w", err)
			}
		default:
			return "", fmt.Errorf("%w: %s (%d)", errReleaseArchiveUnsupported, hdr.Name, hdr.Typeflag)
		}
	}

	entrypoint := strings.TrimSpace(configuredEntrypoint)
	if entrypoint != "" {
		targetPath, err := safeJoin(dest, entrypoint)
		if err != nil {
			return "", err
		}
		if _, err := os.Stat(targetPath); err != nil {
			return "", fmt.Errorf("stat configured release entrypoint: %w", err)
		}
		return filepath.Clean(entrypoint), nil
	}

	discovered, err := discoverReleaseEntrypoint(dest)
	if err != nil {
		return "", err
	}
	return discovered, nil
}

func discoverReleaseEntrypoint(dest string) (string, error) {
	matches := make([]string, 0, 2)
	err := filepath.WalkDir(dest, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if filepath.Base(path) == releaseDefaultEntrypoint {
			rel, err := filepath.Rel(dest, path)
			if err != nil {
				return err
			}
			matches = append(matches, rel)
		}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("discover release entrypoint: %w", err)
	}
	if len(matches) == 0 {
		return "", errReleaseEntrypointMissing
	}
	sort.Strings(matches)
	return filepath.Clean(matches[0]), nil
}

func writeReleaseMetadata(tempDir string, payload releaseUpdatePayload, entrypointRel string) error {
	meta := releaseMetadata{
		Version:     payload.Version,
		SHA256:      payload.Artifact.SHA256,
		URL:         payload.Artifact.URL,
		Entrypoint:  filepath.Clean(entrypointRel),
		ReleaseID:   payload.ReleaseID,
		RolloutID:   payload.RolloutID,
		TargetID:    payload.TargetID,
		StagedAtUTC: time.Now().UTC().Format(time.RFC3339Nano),
	}
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal release metadata: %w", err)
	}
	if err := os.WriteFile(filepath.Join(tempDir, releaseMetadataFileName), data, 0o644); err != nil {
		return fmt.Errorf("write release metadata: %w", err)
	}
	return nil
}

func downloadReleaseArtifact(ctx context.Context, client *http.Client, rawURL string) ([]byte, error) {
	httpClient := client
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 5 * time.Minute}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", errDownloadFailed, resp.StatusCode)
	}

	limited := io.LimitReader(resp.Body, releaseArtifactMaxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > releaseArtifactMaxBytes {
		return nil, fmt.Errorf("%w: %d bytes", errDownloadTooLarge, releaseArtifactMaxBytes)
	}
	return data, nil
}
