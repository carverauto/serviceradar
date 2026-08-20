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
	_ "embed"
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
	defaultReleaseRuntimeRoot                 = "/var/lib/serviceradar/agent"
	releaseVersionsDirName                    = "versions"
	releaseTmpDirName                         = "tmp"
	releaseMetadataFileName                   = ".serviceradar-release.json"
	releaseDefaultEntrypoint                  = "serviceradar-agent"
	releaseArtifactFormatTarGz                = "tar.gz"
	releaseArtifactMaxBytes             int64 = 256 * 1024 * 1024
	releasePublicKeyEnv                       = "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
	releaseCapabilityRemoteAccessRDP          = "remote_access.rdp"
	releaseRDPHelperBinary                    = "serviceradar-rdp-adapter"
	releaseRDPHelperInstallPath               = "/usr/local/bin/serviceradar-rdp-adapter"
	releaseRDPHelperReadinessProbe            = "--capabilities"
	releaseRequirementHelper                  = "helper"
	releaseRequirementInstallPath             = "install_path"
	releaseRequirementHelperCapArg            = "helper_capabilities_arg"
	releaseRequirementRequiresProbe           = "requires_helper_readiness_probe"
	releaseRequirementHelperReady             = "helper_connector_ready"
	releaseRequirementHelperReadyReason       = "helper_connector_ready_reason"
	releaseRequirementReleasePhase            = "release_phase"
	releaseReleasePhaseExperimental           = "experimental"
	releaseCompatibleAgentMin                 = "min"
	releaseCompatibleAgentMax                 = "max"
	releaseHelperReadyReasonMaxBytes          = 256

	// Bounded in-band retry for transient release artifact download failures.
	releaseDownloadMaxAttempts = 4
)

// Backoff durations for transient release artifact download retries. Declared as
// vars (not consts) so tests can shrink them; production values are fixed.
//
//nolint:gochecknoglobals // tunable for tests
var (
	releaseDownloadInitialBackoff = 1 * time.Second
	releaseDownloadMaxBackoff     = 15 * time.Second
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
	errReleaseHelperCapabilityMissing = errors.New("release helper install requires signed artifact capability")
	errReleaseHelperReadinessMissing  = errors.New("release helper install requires signed readiness metadata")
	errReleaseHelperConnectorNotReady = errors.New("release helper install requires connector-ready artifact")
)

// releaseSigningPublicKeyPEM is the trusted Ed25519 release-signing PUBLIC key, embedded from a
// committed source file rather than injected by the linker.
//
// WHY A SOURCE FILE AND NOT --stamp. This used to arrive through
//
//	x_defs = {"...agent.ReleaseSigningPublicKey": "{STABLE_AGENT_RELEASE_PUBLIC_KEY}"}
//
// which requires the GLOBAL --stamp flag: rules_go exposes no per-target stamp attribute, so
// there is no way to ask for it on this binary alone. Two consequences followed, both measured:
//
//   - Every build without --stamp shipped an agent whose key was the empty string, silently.
//     That is every developer build and every CI build; only the release job passed the flag.
//   - The release job therefore built in a configuration no other job shared.
//
// There is no secret here to protect: this is the PUBLIC half. Committing it makes the value
// reviewable in git, makes the build hermetic, and makes a dev build behave like a release
// build. Rotation costs a commit -- but rotation already required rebuilding and re-releasing
// every agent, because the key is embedded either way.
//
// The release workflow no longer injects this; it ASSERTS that the key derived from the signing
// secret equals this file, which is a stronger check than the injection it replaces.
//
//go:embed release_signing_key.txt
var releaseSigningPublicKeyPEM string

// ReleaseSigningPublicKey is the trusted key used for managed release verification.
//
// Still a package-level var rather than a const: the tests reassign it to exercise the unset and
// wrong-key paths.
//
//nolint:gochecknoglobals // Reassigned by tests; embedded default above.
var ReleaseSigningPublicKey = parseEmbeddedSigningKey(releaseSigningPublicKeyPEM)

// parseEmbeddedSigningKey returns the first meaningful line of the embedded key file.
//
// The file is allowed to carry `#` comments so that a security-relevant constant can explain
// what it is and how to regenerate it, rather than sitting in the tree as an unexplained blob.
func parseEmbeddedSigningKey(contents string) string {
	for _, line := range strings.Split(contents, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		return line
	}

	return ""
}

type releaseUpdatePayload struct {
	ReleaseID         string                   `json:"release_id,omitempty"`
	RolloutID         string                   `json:"rollout_id,omitempty"`
	TargetID          string                   `json:"target_id,omitempty"`
	Version           string                   `json:"version,omitempty"`
	Manifest          map[string]interface{}   `json:"manifest,omitempty"`
	Signature         string                   `json:"signature,omitempty"`
	Artifact          releaseArtifactPayload   `json:"artifact"`
	ArtifactTransport releaseArtifactTransport `json:"artifact_transport,omitempty"`
	HelperInstall     *releaseHelperInstall    `json:"helper_install,omitempty"`
}

type releaseArtifactPayload struct {
	URL                     string                 `json:"url,omitempty"`
	SHA256                  string                 `json:"sha256,omitempty"`
	OS                      string                 `json:"os,omitempty"`
	Arch                    string                 `json:"arch,omitempty"`
	Format                  string                 `json:"format,omitempty"`
	Entrypoint              string                 `json:"entrypoint,omitempty"`
	Capabilities            []string               `json:"capabilities,omitempty"`
	HelperProtocolVersion   string                 `json:"helper_protocol_version,omitempty"`
	CompatibleAgentVersions map[string]string      `json:"compatible_agent_versions,omitempty"`
	DeploymentRequirements  map[string]interface{} `json:"deployment_requirements,omitempty"`
}

type releaseArtifactTransport struct {
	Kind     string `json:"kind,omitempty"`
	Path     string `json:"path,omitempty"`
	Port     int    `json:"port,omitempty"`
	TargetID string `json:"target_id,omitempty"`
}

type releaseHelperInstall struct {
	Enabled                 bool                   `json:"enabled,omitempty"`
	Capability              string                 `json:"capability,omitempty"`
	HelperProtocolVersion   string                 `json:"helper_protocol_version,omitempty"`
	CompatibleAgentVersions map[string]string      `json:"compatible_agent_versions,omitempty"`
	DeploymentRequirements  map[string]interface{} `json:"deployment_requirements,omitempty"`
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
	payload.Artifact.Capabilities = normalizeReleaseCapabilities(payload.Artifact.Capabilities)
	payload.Artifact.HelperProtocolVersion = strings.TrimSpace(payload.Artifact.HelperProtocolVersion)
	payload.ArtifactTransport.Kind = strings.TrimSpace(payload.ArtifactTransport.Kind)
	payload.ArtifactTransport.Path = strings.TrimSpace(payload.ArtifactTransport.Path)
	payload.ArtifactTransport.TargetID = strings.TrimSpace(payload.ArtifactTransport.TargetID)
	if payload.HelperInstall != nil {
		payload.HelperInstall.Capability = strings.TrimSpace(payload.HelperInstall.Capability)
		payload.HelperInstall.HelperProtocolVersion = strings.TrimSpace(payload.HelperInstall.HelperProtocolVersion)
	}
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
		if err := validateReleaseHelperInstall(payload); err != nil {
			return err
		}
		return nil
	}
}

func validateReleaseHelperInstall(payload releaseUpdatePayload) error {
	if payload.HelperInstall == nil || !payload.HelperInstall.Enabled {
		return nil
	}

	capability := payload.HelperInstall.Capability
	if capability == "" {
		capability = releaseCapabilityRemoteAccessRDP
	}
	if capability != releaseCapabilityRemoteAccessRDP {
		return fmt.Errorf("%w: %s", errReleaseHelperCapabilityMissing, capability)
	}
	if !releaseArtifactHasCapability(payload.Artifact, capability) {
		return fmt.Errorf("%w: %s", errReleaseHelperCapabilityMissing, capability)
	}
	connectorReady, err := validateRDPHelperArtifactReadiness(payload.Artifact)
	if err != nil {
		return err
	}
	if !connectorReady {
		return errReleaseHelperConnectorNotReady
	}
	if err := validateRDPHelperInstallMatchesArtifact(*payload.HelperInstall, payload.Artifact); err != nil {
		return err
	}

	return nil
}

func validateRDPHelperInstallMatchesArtifact(helper releaseHelperInstall, artifact releaseArtifactPayload) error {
	if helper.HelperProtocolVersion != artifact.HelperProtocolVersion {
		return errReleaseHelperReadinessMissing
	}
	if canonicalArtifactValue(helper.CompatibleAgentVersions) != canonicalArtifactValue(artifact.CompatibleAgentVersions) {
		return errReleaseHelperReadinessMissing
	}
	if canonicalArtifactValue(helper.DeploymentRequirements) != canonicalArtifactValue(artifact.DeploymentRequirements) {
		return errReleaseHelperReadinessMissing
	}

	return nil
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
	if releaseArtifactHasCapability(artifact, releaseCapabilityRemoteAccessRDP) {
		if _, err := validateRDPHelperArtifactReadiness(artifact); err != nil {
			return err
		}
	}
	return nil
}

func validateRDPHelperArtifactReadiness(artifact releaseArtifactPayload) (bool, error) {
	if strings.TrimSpace(artifact.HelperProtocolVersion) == "" {
		return false, errReleaseHelperReadinessMissing
	}
	if strings.TrimSpace(artifact.CompatibleAgentVersions[releaseCompatibleAgentMin]) == "" {
		return false, errReleaseHelperReadinessMissing
	}
	if strings.TrimSpace(artifact.CompatibleAgentVersions[releaseCompatibleAgentMax]) == "" {
		return false, errReleaseHelperReadinessMissing
	}
	if releaseDeploymentRequirementString(
		artifact.DeploymentRequirements,
		releaseRequirementHelper,
	) != releaseRDPHelperBinary {
		return false, errReleaseHelperReadinessMissing
	}
	if releaseDeploymentRequirementString(
		artifact.DeploymentRequirements,
		releaseRequirementInstallPath,
	) != releaseRDPHelperInstallPath {
		return false, errReleaseHelperReadinessMissing
	}
	if releaseDeploymentRequirementString(
		artifact.DeploymentRequirements,
		releaseRequirementHelperCapArg,
	) != releaseRDPHelperReadinessProbe {
		return false, errReleaseHelperReadinessMissing
	}
	requiresProbe, ok := releaseDeploymentRequirementBool(
		artifact.DeploymentRequirements,
		releaseRequirementRequiresProbe,
	)
	if !ok || !requiresProbe {
		return false, errReleaseHelperReadinessMissing
	}
	connectorReady, ok := releaseDeploymentRequirementBool(
		artifact.DeploymentRequirements,
		releaseRequirementHelperReady,
	)
	if !ok {
		return false, errReleaseHelperReadinessMissing
	}
	readinessReason := normalizeReleaseHelperReadyReason(releaseDeploymentRequirementString(
		artifact.DeploymentRequirements,
		releaseRequirementHelperReadyReason,
	))
	if connectorReady {
		if readinessReason != "" {
			return false, errReleaseHelperReadinessMissing
		}

		return true, nil
	}
	if releaseDeploymentRequirementString(
		artifact.DeploymentRequirements,
		releaseRequirementReleasePhase,
	) != releaseReleasePhaseExperimental || readinessReason == "" {
		return false, errReleaseHelperReadinessMissing
	}

	return false, nil
}

func normalizeReleaseHelperReadyReason(reason string) string {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ""
	}

	var out strings.Builder
	for _, r := range reason {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		next := string(r)
		if out.Len()+len(next) > releaseHelperReadyReasonMaxBytes {
			break
		}
		out.WriteString(next)
	}

	return strings.TrimSpace(out.String())
}

func releaseDeploymentRequirementString(requirements map[string]interface{}, key string) string {
	value, ok := requirements[key]
	if !ok {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func releaseDeploymentRequirementBool(requirements map[string]interface{}, key string) (bool, bool) {
	value, ok := requirements[key]
	if !ok {
		return false, false
	}
	switch typed := value.(type) {
	case bool:
		return typed, true
	case string:
		normalized := strings.TrimSpace(typed)
		switch {
		case strings.EqualFold(normalized, "true"):
			return true, true
		case strings.EqualFold(normalized, "false"):
			return false, true
		default:
			return false, false
		}
	default:
		return false, false
	}
}

func validateReleaseArtifactURL(rawURL string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("%w: %w", errReleaseArtifactURLInvalid, err)
	}
	if parsed == nil || !strings.EqualFold(parsed.Scheme, httpsScheme) || parsed.Host == "" {
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
		normalizedArtifactField(candidate["entrypoint"]) == normalizedArtifactField(artifact.Entrypoint) &&
		optionalArtifactFieldMatches(candidate, "capabilities", artifact.Capabilities) &&
		optionalArtifactFieldMatches(candidate, "helper_protocol_version", artifact.HelperProtocolVersion) &&
		optionalArtifactFieldMatches(candidate, "compatible_agent_versions", artifact.CompatibleAgentVersions) &&
		optionalArtifactFieldMatches(candidate, "deployment_requirements", artifact.DeploymentRequirements)
}

func normalizedArtifactField(value interface{}) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(strings.ToLower(fmt.Sprint(value)))
}

func optionalArtifactFieldMatches(candidate map[string]interface{}, field string, value interface{}) bool {
	if releaseArtifactFieldEmpty(value) {
		return true
	}

	return canonicalArtifactValue(candidate[field]) == canonicalArtifactValue(value)
}

func releaseArtifactFieldEmpty(value interface{}) bool {
	switch typed := value.(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(typed) == ""
	case []string:
		return len(typed) == 0
	case map[string]string:
		return len(typed) == 0
	case map[string]interface{}:
		return len(typed) == 0
	default:
		return false
	}
}

func canonicalArtifactValue(value interface{}) string {
	normalized := normalizeArtifactValue(value)
	encoded, err := marshalCanonicalJSON(normalized)
	if err != nil {
		return ""
	}

	return string(encoded)
}

func normalizeArtifactValue(value interface{}) interface{} {
	switch typed := value.(type) {
	case []string:
		values := make([]interface{}, 0, len(typed))
		for _, entry := range normalizeReleaseCapabilities(typed) {
			values = append(values, entry)
		}
		return values
	case []interface{}:
		values := make([]interface{}, 0, len(typed))
		for _, entry := range typed {
			values = append(values, normalizeArtifactValue(entry))
		}
		return values
	case map[string]string:
		values := make(map[string]interface{}, len(typed))
		for key, entry := range typed {
			values[key] = strings.TrimSpace(entry)
		}
		return values
	case map[string]interface{}:
		values := make(map[string]interface{}, len(typed))
		for key, entry := range typed {
			values[key] = normalizeArtifactValue(entry)
		}
		return values
	case string:
		return strings.TrimSpace(typed)
	default:
		return typed
	}
}

func releaseArtifactHasCapability(artifact releaseArtifactPayload, capability string) bool {
	capability = strings.TrimSpace(capability)
	if capability == "" {
		return false
	}

	for _, candidate := range artifact.Capabilities {
		if candidate == capability {
			return true
		}
	}

	return false
}

func normalizeReleaseCapabilities(capabilities []string) []string {
	seen := make(map[string]struct{}, len(capabilities))
	normalized := make([]string, 0, len(capabilities))

	for _, capability := range capabilities {
		capability = strings.TrimSpace(capability)
		if capability == "" {
			continue
		}
		if _, ok := seen[capability]; ok {
			continue
		}
		seen[capability] = struct{}{}
		normalized = append(normalized, capability)
	}

	return normalized
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
		keyValue = strings.TrimSpace(os.Getenv(releasePublicKeyEnv))
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

// downloadReleaseArtifact fetches the release artifact, retrying transient
// failures with exponential backoff. A single gateway/agent racing a rollout can
// briefly get a not-ready artifact (HTTP 409/424), a not-yet-replicated object
// (404), a 5xx, or a network blip. Those are transient and clearly recoverable
// (peers downloading the identical artifact a moment later succeed), so retrying
// in-band lets the agent recover instead of reporting a terminal failure. Hard
// rejections (bad signature/platform handled earlier, or a genuine 4xx here) are
// not retried.
func downloadReleaseArtifact(ctx context.Context, payload releaseUpdatePayload, cfg releaseStageConfig) ([]byte, error) {
	httpClient, err := releaseHTTPClient(payload, cfg)
	if err != nil {
		return nil, err
	}

	backoff := releaseDownloadInitialBackoff
	var lastErr error

	for attempt := 1; attempt <= releaseDownloadMaxAttempts; attempt++ {
		data, attemptErr := downloadReleaseArtifactAttempt(ctx, payload, cfg, httpClient)
		if attemptErr == nil {
			return data, nil
		}

		lastErr = attemptErr
		if !isRetryableReleaseDownloadError(attemptErr) || attempt == releaseDownloadMaxAttempts {
			return nil, attemptErr
		}

		if cfg.Logger != nil {
			cfg.Logger.Warn().
				Err(attemptErr).
				Int("attempt", attempt).
				Int("max_attempts", releaseDownloadMaxAttempts).
				Dur("backoff", backoff).
				Msg("Transient release artifact download failure; retrying")
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(backoff):
		}

		if backoff *= 2; backoff > releaseDownloadMaxBackoff {
			backoff = releaseDownloadMaxBackoff
		}
	}

	return nil, lastErr
}

func downloadReleaseArtifactAttempt(
	ctx context.Context,
	payload releaseUpdatePayload,
	cfg releaseStageConfig,
	httpClient *http.Client,
) ([]byte, error) {
	req, err := buildReleaseArtifactRequest(ctx, payload, cfg)
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
		// Preserve the "download failed: status <code>" message shape while
		// carrying the status code for transient-vs-terminal classification.
		return nil, &gatewayArtifactStatusError{sentinel: errDownloadFailed, statusCode: resp.StatusCode}
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

// isRetryableReleaseDownloadError classifies a release artifact download failure
// as transient (worth retrying) versus terminal. Not-ready/not-staged artifacts
// (409/424/404), rate limits (429), and 5xx are transient; so are non-HTTP
// transport errors (dial/timeout/reset/EOF). A genuine 4xx client rejection
// (400/401/403 auth denial) and an over-size artifact are terminal.
func isRetryableReleaseDownloadError(err error) bool {
	if err == nil {
		return false
	}

	if errors.Is(err, errDownloadTooLarge) {
		return false
	}

	var statusErr *gatewayArtifactStatusError
	if errors.As(err, &statusErr) {
		return isRetryableReleaseDownloadStatus(statusErr.StatusCode())
	}

	// Non-HTTP transport error: treat as transient and retry.
	return true
}

func isRetryableReleaseDownloadStatus(status int) bool {
	switch status {
	case http.StatusRequestTimeout, // 408
		http.StatusConflict,         // 409 (artifact not ready yet)
		http.StatusLocked,           // 423
		http.StatusFailedDependency, // 424 (artifact not mirrored yet)
		http.StatusTooEarly,         // 425
		http.StatusTooManyRequests,  // 429
		http.StatusNotFound:         // 404 (object not staged/replicated yet)
		return true
	default:
		return status >= 500
	}
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
	if req == nil || req.URL == nil || !strings.EqualFold(req.URL.Scheme, httpsScheme) {
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
	case strings.EqualFold(parsed.Scheme, httpsScheme):
		return "443"
	case strings.EqualFold(parsed.Scheme, httpScheme):
		return "80"
	default:
		return ""
	}
}
