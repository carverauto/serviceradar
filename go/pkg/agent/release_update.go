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
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	defaultReleaseRuntimeRoot        = "/var/lib/serviceradar/agent/releases"
	releaseVersionsDirName           = "versions"
	releaseTmpDirName                = "tmp"
	releaseMetadataFileName          = ".serviceradar-release.json"
	releaseDefaultEntrypoint         = "serviceradar-agent"
	releaseArtifactFormatTarGz       = "tar.gz"
	releaseArtifactMaxBytes    int64 = 256 * 1024 * 1024
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
	errReleaseArtifactNotSigned       = errors.New("release artifact is not present in the signed manifest")
	errReleaseArtifactURLInvalid      = errors.New("release artifact url must use https")
	errReleaseArtifactPlatformInvalid = errors.New("release artifact platform does not match this agent")
	errReleaseRedirectInsecure        = errors.New("release artifact redirects must use https")
	errReleaseRedirectOriginChanged   = errors.New("release artifact redirects must preserve origin")
	errReleaseRedirectLimitExceeded   = errors.New("release artifact redirect limit exceeded")
	errReleaseGatewaySecurityRequired = errors.New("gateway security configuration is required for release download")
	errReleaseGatewayCAAppendFailed   = errors.New("failed to append gateway CA certificate")
)

// ReleaseSigningPublicKey is set at build time for managed release verification.
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var ReleaseSigningPublicKey = ""

type releaseUpdatePayload struct {
	ReleaseID         string                   `json:"release_id,omitempty"`
	RolloutID         string                   `json:"rollout_id,omitempty"`
	TargetID          string                   `json:"target_id,omitempty"`
	Version           string                   `json:"version,omitempty"`
	Manifest          map[string]interface{}   `json:"manifest,omitempty"`
	Signature         string                   `json:"signature,omitempty"`
	Artifact          releaseArtifactPayload   `json:"artifact"`
	ArtifactTransport releaseArtifactTransport `json:"artifact_transport,omitempty"`
}

type releaseArtifactPayload struct {
	URL        string `json:"url,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	OS         string `json:"os,omitempty"`
	Arch       string `json:"arch,omitempty"`
	Format     string `json:"format,omitempty"`
	Entrypoint string `json:"entrypoint,omitempty"`
}

type releaseArtifactTransport struct {
	Kind     string `json:"kind,omitempty"`
	Path     string `json:"path,omitempty"`
	Port     int    `json:"port,omitempty"`
	TargetID string `json:"target_id,omitempty"`
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
	HTTPClient      *http.Client
	Logger          logger.Logger
	RuntimeRoot     string
	GatewayAddr     string
	GatewaySecurity *models.SecurityConfig
	CommandID       string
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

	data, err := downloadReleaseArtifact(ctx, payload, cfg)
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
	payload.ArtifactTransport.Kind = strings.TrimSpace(payload.ArtifactTransport.Kind)
	payload.ArtifactTransport.Path = strings.TrimSpace(payload.ArtifactTransport.Path)
	payload.ArtifactTransport.TargetID = strings.TrimSpace(payload.ArtifactTransport.TargetID)
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
		if err := validateSignedArtifact(payload.Manifest, payload.Artifact); err != nil {
			return err
		}
		return nil
	}
}

func validateSignedArtifact(manifest map[string]interface{}, artifact releaseArtifactPayload) error {
	if err := validateReleaseArtifactURL(artifact.URL); err != nil {
		return err
	}
	if err := validateReleaseArtifactPlatform(artifact); err != nil {
		return err
	}
	if !manifestContainsArtifact(manifest, artifact) {
		return errReleaseArtifactNotSigned
	}
	return nil
}

func validateReleaseArtifactURL(rawURL string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("%w: %w", errReleaseArtifactURLInvalid, err)
	}
	if parsed == nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.Host == "" {
		return errReleaseArtifactURLInvalid
	}
	return nil
}

func validateReleaseArtifactPlatform(artifact releaseArtifactPayload) error {
	artifactOS := strings.ToLower(strings.TrimSpace(artifact.OS))
	artifactArch := strings.ToLower(strings.TrimSpace(artifact.Arch))

	if artifactOS == "" || artifactArch == "" {
		return errReleaseArtifactNotSigned
	}
	if artifactOS != runtime.GOOS || artifactArch != runtime.GOARCH {
		return fmt.Errorf(
			"%w: artifact=%s/%s agent=%s/%s",
			errReleaseArtifactPlatformInvalid,
			artifactOS,
			artifactArch,
			runtime.GOOS,
			runtime.GOARCH,
		)
	}
	return nil
}

func manifestContainsArtifact(manifest map[string]interface{}, artifact releaseArtifactPayload) bool {
	artifacts, ok := normalizeManifestArtifacts(manifest).([]interface{})
	if !ok {
		return false
	}

	for _, candidate := range artifacts {
		candidateMap, ok := candidate.(map[string]interface{})
		if !ok {
			continue
		}
		if manifestArtifactMatches(candidateMap, artifact) {
			return true
		}
	}

	return false
}

func normalizeManifestArtifacts(manifest map[string]interface{}) interface{} {
	if manifest == nil {
		return nil
	}
	if artifacts, ok := manifest["artifacts"]; ok {
		return artifacts
	}
	return nil
}

func manifestArtifactMatches(candidate map[string]interface{}, artifact releaseArtifactPayload) bool {
	return normalizedArtifactField(candidate["url"]) == normalizedArtifactField(artifact.URL) &&
		normalizedArtifactField(candidate["sha256"]) == normalizedArtifactField(artifact.SHA256) &&
		normalizedArtifactField(candidate["os"]) == normalizedArtifactField(artifact.OS) &&
		normalizedArtifactField(candidate["arch"]) == normalizedArtifactField(artifact.Arch) &&
		normalizedArtifactField(candidate["format"]) == normalizedArtifactField(artifact.Format) &&
		normalizedArtifactField(candidate["entrypoint"]) == normalizedArtifactField(artifact.Entrypoint)
}

func normalizedArtifactField(value interface{}) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(strings.ToLower(fmt.Sprint(value)))
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
	keyValue := strings.TrimSpace(ReleaseSigningPublicKey)
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
	return defaultReleaseRuntimeRoot
}

func releaseVersionDir(runtimeRoot, version string) (string, error) {
	clean, err := normalizeManagedReleaseVersion(version)
	if err != nil {
		return "", err
	}
	if clean == "." || strings.Contains(clean, string(filepath.Separator)) || strings.Contains(clean, "..") {
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

func downloadReleaseArtifact(ctx context.Context, payload releaseUpdatePayload, cfg releaseStageConfig) ([]byte, error) {
	req, err := buildReleaseArtifactRequest(ctx, payload, cfg)
	if err != nil {
		return nil, err
	}

	httpClient, err := releaseHTTPClient(payload, cfg)
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

func buildReleaseArtifactRequest(ctx context.Context, payload releaseUpdatePayload, cfg releaseStageConfig) (*http.Request, error) {
	if usesGatewayArtifactTransport(payload.ArtifactTransport) {
		rawURL, err := gatewayArtifactURL(cfg.GatewayAddr, payload.ArtifactTransport)
		if err != nil {
			return nil, err
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("X-ServiceRadar-Release-Target-ID", payload.ArtifactTransport.TargetID)
		req.Header.Set("X-ServiceRadar-Release-Command-ID", cfg.CommandID)
		return req, nil
	}

	return http.NewRequestWithContext(ctx, http.MethodGet, payload.Artifact.URL, nil)
}

func usesGatewayArtifactTransport(transport releaseArtifactTransport) bool {
	return strings.EqualFold(strings.TrimSpace(transport.Kind), "gateway_https") &&
		strings.TrimSpace(transport.Path) != "" &&
		transport.Port > 0 &&
		strings.TrimSpace(transport.TargetID) != ""
}

func gatewayArtifactURL(gatewayAddr string, transport releaseArtifactTransport) (string, error) {
	host, _, err := net.SplitHostPort(strings.TrimSpace(gatewayAddr))
	if err != nil {
		return "", fmt.Errorf("invalid gateway address for release artifact download: %w", err)
	}
	if host == "" {
		return "", errReleaseArtifactURLInvalid
	}
	return fmt.Sprintf("https://%s:%d%s", host, transport.Port, transport.Path), nil
}

func releaseHTTPClient(payload releaseUpdatePayload, cfg releaseStageConfig) (*http.Client, error) {
	if cfg.HTTPClient != nil {
		clientCopy := *cfg.HTTPClient
		clientCopy.CheckRedirect = validateReleaseRedirect
		return &clientCopy, nil
	}

	if usesGatewayArtifactTransport(payload.ArtifactTransport) {
		return gatewayArtifactHTTPClient(cfg.GatewaySecurity)
	}

	client := &http.Client{Timeout: 5 * time.Minute}
	client.CheckRedirect = validateReleaseRedirect
	return client, nil
}

func gatewayArtifactHTTPClient(security *models.SecurityConfig) (*http.Client, error) {
	if security == nil {
		return nil, errReleaseGatewaySecurityRequired
	}

	tlsConfig, err := gatewayArtifactTLSConfig(security)
	if err != nil {
		return nil, err
	}

	return &http.Client{
		Timeout: 5 * time.Minute,
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
		CheckRedirect: validateReleaseRedirect,
	}, nil
}

func gatewayArtifactTLSConfig(security *models.SecurityConfig) (*tls.Config, error) {
	certPath := resolveSecurityPath(security.CertDir, security.TLS.CertFile)
	keyPath := resolveSecurityPath(security.CertDir, security.TLS.KeyFile)
	caPath := resolveSecurityPath(security.CertDir, security.TLS.CAFile)

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, err
	}

	caCert, err := os.ReadFile(caPath)
	if err != nil {
		return nil, err
	}

	rootCAs := x509.NewCertPool()
	if !rootCAs.AppendCertsFromPEM(caCert) {
		return nil, errReleaseGatewayCAAppendFailed
	}

	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		RootCAs:      rootCAs,
		ServerName:   security.ServerName,
	}, nil
}

func resolveSecurityPath(certDir, file string) string {
	if filepath.IsAbs(file) || certDir == "" {
		return file
	}
	return filepath.Join(certDir, file)
}

func validateReleaseRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= 5 {
		return errReleaseRedirectLimitExceeded
	}
	if req == nil || req.URL == nil || !strings.EqualFold(req.URL.Scheme, "https") {
		return errReleaseRedirectInsecure
	}
	if len(via) == 0 || via[0] == nil || via[0].URL == nil {
		return errReleaseRedirectOriginChanged
	}
	if !sameReleaseOrigin(via[0].URL, req.URL) {
		return errReleaseRedirectOriginChanged
	}
	return nil
}

func sameReleaseOrigin(a, b *url.URL) bool {
	if a == nil || b == nil {
		return false
	}
	if !strings.EqualFold(a.Scheme, b.Scheme) {
		return false
	}
	if !strings.EqualFold(a.Hostname(), b.Hostname()) {
		return false
	}
	return releaseURLPort(a) == releaseURLPort(b)
}

func releaseURLPort(parsed *url.URL) string {
	if parsed == nil {
		return ""
	}
	if port := parsed.Port(); port != "" {
		return port
	}
	switch {
	case strings.EqualFold(parsed.Scheme, "https"):
		return "443"
	case strings.EqualFold(parsed.Scheme, "http"):
		return "80"
	default:
		return ""
	}
}
