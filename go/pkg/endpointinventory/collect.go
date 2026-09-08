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

package endpointinventory

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const collectorName = "serviceradar-endpoint-inventory"

// collectorVersion identifies the legacy endpoint-inventory collector build. It
// is surfaced on every ScanPayload so the core ingest path and UI can attribute
// a scan to a concrete collector revision instead of showing an empty/"None"
// version. ScaLibr now supersedes the retired native endpoint-inventory add-on,
// but this shared package still emits the generic endpoint inventory payload.
const collectorVersion = "0.1.1"

const (
	scanStateFailed       = "scan_failed"
	scanStateNotScanned   = "not_scanned"
	scanStateNotSupported = "not_supported"
	scanStateScanned      = "scanned"
	scanStatePartial      = "partial"
	scanStateUnchanged    = "unchanged"

	coverageComplete                 = "complete"
	coverageDisabled                 = "disabled"
	coverageFailed                   = "failed"
	coverageNoSupportedPackageSource = "no_supported_package_source"
	coveragePartial                  = "partial"
	coverageUnchanged                = "unchanged"
	coverageUnknown                  = "unknown"

	metadataReasonServerReconcileFloor = "server_reconcile_floor"
	redactionStateCollected            = "collected_when_available"
	redactionStateOmitted              = "omitted"
)

var (
	errPackageLimitExceeded = errors.New("endpoint inventory package limit exceeded")
	errOutputTruncated      = errors.New("endpoint inventory source output truncated")
)

type Runner struct {
	cfg Config
}

func NewRunner(cfg Config) *Runner {
	return &Runner{cfg: cfg}
}

func (r *Runner) Run(ctx context.Context) (*ScanPayload, error) {
	started := time.Now().UTC()
	configHash := computeConfigHash(r.cfg)
	identity := CacheIdentity{
		AgentID:         r.cfg.AgentID,
		ConfigHash:      configHash,
		ProducerID:      collectorName,
		ProducerVersion: collectorVersion,
	}
	if !r.cfg.Enabled {
		return disabledPayload(r.cfg, started, configHash), nil
	}

	ctx, cancel := context.WithTimeout(ctx, ScanTimeout(r.cfg))
	defer cancel()

	osInfo, _ := ReadOSRelease(r.cfg.OSReleasePath)
	sourceMTimes := CollectSourceMTimes(r.cfg)
	cache, err := ReadCacheManifest(r.cfg)
	if err != nil {
		return nil, err
	}
	if CacheCanSkipFullScan(r.cfg, identity, cache, sourceMTimes, started) {
		payload := r.unchangedPayload(started, osInfo, cache, "source_mtime_unchanged")
		if err := RecordCachedScan(r.cfg, identity, sourceMTimes, started); err == nil {
			return payload, nil
		} else if !errors.Is(err, ErrCacheRefreshRequired) {
			return nil, err
		}
	}

	packages, sources := r.collectPackages(ctx)
	if len(packages) > r.cfg.MaxPackages {
		return failurePayload(r.cfg, started, osInfo, sources, errPackageLimitExceeded, configHash), nil
	}

	coverage := sourceCoverageState(sources, len(packages))
	state := scanStateScanned
	switch coverage {
	case coverageFailed:
		state = scanStateFailed
	case coveragePartial:
		state = scanStatePartial
	case coverageNoSupportedPackageSource:
		state = scanStateNotSupported
	case coverageUnknown:
		state = scanStateNotScanned
	}
	var (
		sbom             *CycloneDXBOM
		packageSetHash   string
		artifactHash     string
		lastSuccessfulAt *time.Time
	)
	if state == scanStateScanned && coverage == coverageComplete {
		completeSBOM := BuildCycloneDX(r.cfg, started, osInfo, packages)
		sbom = &completeSBOM
		packageSetHash = ComputePackageSetHash(packages)
		artifactHash = ComputeArtifactHash(completeSBOM)
		lastSuccessfulAt = &started
	}
	payload := &ScanPayload{
		SchemaVersion:        SchemaVersion,
		AgentID:              r.cfg.AgentID,
		ScanID:               newScanID(),
		CollectorVersion:     collectorVersion,
		State:                state,
		CoverageState:        coverage,
		ConfigHash:           configHash,
		LastScanAt:           started,
		LastSuccessfulScanAt: lastSuccessfulAt,
		OS:                   osInfo,
		EnabledPlugins:       append([]string(nil), r.cfg.Sources...),
		DetectedPlugins:      detectedSources(sources),
		Diagnostics:          scannerDiagnostics(sources),
		PackageCount:         len(packages),
		PackageSetHash:       packageSetHash,
		ArtifactHash:         artifactHash,
		HashAlgorithm:        HashAlgorithm,
		UploadReason:         UploadReasonChanged,
		DurationMillis:       time.Since(started).Milliseconds(),
		Truncated:            summariesTruncated(sources),
		Metadata:             collectionPolicyMetadata(r.cfg),
		SBOM:                 sbom,
	}

	if state == scanStateScanned && coverage == coverageComplete {
		if err := FinalizeFullScan(r.cfg, identity, payload, packages, sourceMTimes, started); err != nil {
			return nil, err
		}
	}

	return payload, nil
}

// changedScanDelta computes the change-only delta for a changed upload relative
// to the previously uploaded package set. It returns nil (forcing core to
// consume the full SBOM anchor) when there is no trustworthy prior state to diff
// against: a first-ever upload, a server-requested reconcile (which must resync
// from a full anchor), or a missing/empty last-uploaded hash. The delta's base
// hash is the previously uploaded hash so core can verify it still holds that
// exact state before applying.
func changedScanDelta(
	cache *InventoryCacheManifest,
	packages []Package,
	targetHash string,
	serverReconcileRequested bool,
) *PackageSetDelta {
	if cache == nil || serverReconcileRequested {
		return nil
	}
	baseHash := strings.TrimSpace(cache.LastUploadedPackageSetHash)
	if baseHash == "" {
		return nil
	}
	// Guard: the stored package set must actually correspond to the last
	// uploaded hash. fullScanManifest persists the current packages on every
	// full scan, and MarkUploadSucceeded records the hash that was uploaded;
	// they align when the last full scan was the one that got uploaded.
	if strings.TrimSpace(cache.PackageSetHash) != baseHash {
		return nil
	}

	return ComputePackageSetDelta(cache.Packages, packages, baseHash, targetHash)
}

func disabledPayload(cfg Config, scannedAt time.Time, configHash string) *ScanPayload {
	return &ScanPayload{
		SchemaVersion:    SchemaVersion,
		AgentID:          cfg.AgentID,
		ScanID:           "endpoint-inventory-disabled",
		CollectorVersion: collectorVersion,
		State:            scanStateNotScanned,
		CoverageState:    coverageDisabled,
		ConfigHash:       configHash,
		LastScanAt:       scannedAt,
		EnabledPlugins:   append([]string(nil), cfg.Sources...),
		Diagnostics:      []SourceSummary{},
		Metadata:         withMetadataValue(collectionPolicyMetadata(cfg), "reason", "disabled"),
	}
}

func (r *Runner) unchangedPayload(
	scannedAt time.Time,
	osInfo OSInfo,
	cache *InventoryCacheManifest,
	reason string,
) *ScanPayload {
	return &ScanPayload{
		SchemaVersion:        SchemaVersion,
		AgentID:              r.cfg.AgentID,
		ScanID:               newScanID(),
		CollectorVersion:     collectorVersion,
		State:                scanStateUnchanged,
		CoverageState:        coverageUnchanged,
		ConfigHash:           computeConfigHash(r.cfg),
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: cache.LastSuccessfulScanAt,
		OS:                   osInfo,
		EnabledPlugins:       append([]string(nil), r.cfg.Sources...),
		DetectedPlugins:      detectedSources(cache.SourceSummaries),
		Diagnostics:          scannerDiagnostics(cache.SourceSummaries),
		PackageCount:         cache.PackageCount,
		PackageSetHash:       cache.PackageSetHash,
		ArtifactHash:         cache.ArtifactHash,
		HashAlgorithm:        firstNonEmpty(cache.HashAlgorithm, HashAlgorithm),
		UploadReason:         UploadReasonUnchanged,
		Metadata: withMetadataValues(collectionPolicyMetadata(r.cfg), map[string]any{
			"reason":           reason,
			"scans_since_full": cache.ScansSinceFull + 1,
		}),
	}
}

func (r *Runner) collectPackages(ctx context.Context) ([]Package, []SourceSummary) {
	packages := make([]Package, 0, initialPackageCapacity(r.cfg))
	summaries := make([]SourceSummary, 0, len(r.cfg.Sources))

	for _, source := range r.cfg.Sources {
		started := time.Now()
		var (
			collected []Package
			err       error
			path      string
			truncated bool
		)

		switch source {
		case PackageSourceDpkg:
			path = r.cfg.DpkgStatusPath
			collected, err = CollectDpkgPackages(r.cfg.DpkgStatusPath)
		case PackageSourceAPK:
			path = r.cfg.APKInstalledPath
			collected, err = CollectAPKPackages(r.cfg.APKInstalledPath)
		case PackageSourceRPM:
			collected, path, truncated, err = CollectRPMPackages(ctx, r.cfg.RPMPath, r.cfg.MaxOutputBytes)
		default:
			err = fmt.Errorf("%w: %s", ErrUnsupportedSource, source)
		}

		summary := SourceSummary{
			Source:         source,
			Name:           source,
			Type:           "package_source",
			State:          "scanned",
			PackageCount:   len(collected),
			Path:           path,
			Detected:       sourceDetected(source, path, err),
			DurationMillis: time.Since(started).Milliseconds(),
			Truncated:      truncated,
		}
		if err != nil {
			applySourceError(&summary, err)
		}

		summaries = append(summaries, summary)
		packages = append(packages, collected...)
	}

	return packages, summaries
}

func initialPackageCapacity(cfg Config) int {
	if cfg.MaxPackages > 0 && cfg.MaxPackages < 1024 {
		return cfg.MaxPackages
	}

	return 1024
}

func failurePayload(
	cfg Config,
	scannedAt time.Time,
	osInfo OSInfo,
	sources []SourceSummary,
	err error,
	configHash string,
) *ScanPayload {
	return &ScanPayload{
		SchemaVersion:    SchemaVersion,
		AgentID:          cfg.AgentID,
		ScanID:           newScanID(),
		CollectorVersion: collectorVersion,
		State:            scanStateFailed,
		CoverageState:    coverageFailed,
		ConfigHash:       configHash,
		LastScanAt:       scannedAt,
		OS:               osInfo,
		EnabledPlugins:   append([]string(nil), cfg.Sources...),
		DetectedPlugins:  detectedSources(sources),
		Diagnostics:      scannerDiagnostics(sources),
		Truncated:        summariesTruncated(sources),
		Metadata:         withMetadataValue(collectionPolicyMetadata(cfg), "error", err.Error()),
	}
}

func applySourceError(summary *SourceSummary, err error) {
	summary.Reason = sourceErrorReason(err)
	summary.State = "unavailable"

	if sourceErrorIsFailure(err) {
		summary.State = "error"
		summary.Error = err.Error()
	}
}

func sourceErrorReason(err error) string {
	switch {
	case errors.Is(err, errOutputTruncated):
		return "output_truncated"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, os.ErrPermission):
		return "permission_denied"
	case errors.Is(err, exec.ErrNotFound):
		return "command_not_found"
	case errors.Is(err, os.ErrNotExist):
		return "not_found"
	case errors.Is(err, ErrUnsupportedSource):
		return "unsupported_source"
	default:
		return "collector_error"
	}
}

func sourceErrorIsFailure(err error) bool {
	return !errors.Is(err, os.ErrNotExist) && !errors.Is(err, exec.ErrNotFound)
}

func sourceDetected(source, path string, err error) bool {
	if err == nil {
		return true
	}
	if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
		return false
	}
	if source == PackageSourceRPM && path == "" {
		return false
	}

	return true
}

func sourceCoverageState(sources []SourceSummary, packageCount int) string {
	if len(sources) == 0 {
		return coverageUnknown
	}

	failed := false
	supported := false
	for _, source := range sources {
		if source.State == "error" || source.Truncated {
			failed = true
			continue
		}
		if source.Detected && source.State == "scanned" {
			supported = true
		}
	}
	if failed && packageCount == 0 {
		return coverageFailed
	}
	if failed {
		return coveragePartial
	}
	if !supported && packageCount == 0 {
		return coverageNoSupportedPackageSource
	}

	return coverageComplete
}

func detectedSources(sources []SourceSummary) []string {
	detected := make([]string, 0, len(sources))
	for _, source := range sources {
		if source.Detected && source.Source != "" {
			detected = append(detected, source.Source)
		} else if source.Detected && source.Name != "" {
			detected = append(detected, source.Name)
		}
	}

	return detected
}

func scannerDiagnostics(sources []SourceSummary) []SourceSummary {
	diagnostics := make([]SourceSummary, 0, len(sources))
	for _, source := range sources {
		diagnostic := source
		if diagnostic.Name == "" {
			diagnostic.Name = diagnostic.Source
		}
		if diagnostic.Type == "" {
			diagnostic.Type = "package_source"
		}
		diagnostics = append(diagnostics, diagnostic)
	}

	return diagnostics
}

func summariesTruncated(sources []SourceSummary) bool {
	for _, source := range sources {
		if source.Truncated {
			return true
		}
	}

	return false
}

func computeConfigHash(cfg Config) string {
	data, err := json.Marshal(struct {
		Sources           []string `json:"sources"`
		ScanTimeout       string   `json:"scan_timeout"`
		CollectPaths      bool     `json:"collect_paths"`
		CollectFileHashes bool     `json:"collect_file_hashes"`
		MaxPackages       int      `json:"max_packages"`
		MaxOutputBytes    int64    `json:"max_output_bytes"`
		OSReleasePath     string   `json:"os_release_path"`
		DpkgStatusPath    string   `json:"dpkg_status_path"`
		APKInstalledPath  string   `json:"apk_installed_path"`
		RPMDatabasePaths  []string `json:"rpm_database_paths"`
		RPMPath           string   `json:"rpm_path"`
	}{
		Sources:           append([]string(nil), cfg.Sources...),
		ScanTimeout:       cfg.ScanTimeout,
		CollectPaths:      cfg.CollectPaths,
		CollectFileHashes: cfg.CollectFileHashes,
		MaxPackages:       cfg.MaxPackages,
		MaxOutputBytes:    cfg.MaxOutputBytes,
		OSReleasePath:     cfg.OSReleasePath,
		DpkgStatusPath:    cfg.DpkgStatusPath,
		APKInstalledPath:  cfg.APKInstalledPath,
		RPMDatabasePaths:  append([]string(nil), cfg.RPMDatabasePaths...),
		RPMPath:           cfg.RPMPath,
	})
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)

	return hex.EncodeToString(sum[:])
}

func collectionPolicyMetadata(cfg Config) map[string]any {
	return map[string]any{
		"scanner_producer_id": collectorName,
		"enabled_plugins":     append([]string(nil), cfg.Sources...),
		"collection_policy": map[string]any{
			"cadence":             cfg.Cadence,
			"collect_paths":       cfg.CollectPaths,
			"collect_file_hashes": cfg.CollectFileHashes,
		},
		"redaction_policy": map[string]string{
			"paths":       redactionState(cfg.CollectPaths),
			"file_hashes": redactionState(cfg.CollectFileHashes),
		},
	}
}

func redactionState(collect bool) string {
	if collect {
		return redactionStateCollected
	}

	return redactionStateOmitted
}

func withMetadataValue(metadata map[string]any, key string, value any) map[string]any {
	metadata[key] = value

	return metadata
}

func withMetadataValues(metadata map[string]any, values map[string]any) map[string]any {
	for key, value := range values {
		metadata[key] = value
	}

	return metadata
}

func ReadOSRelease(path string) (OSInfo, error) {
	file, err := os.Open(path)
	if err != nil {
		return OSInfo{}, err
	}
	defer func() { _ = file.Close() }()

	values := make(map[string]string)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		values[key] = strings.Trim(strings.TrimSpace(value), `"`)
	}
	if err := scanner.Err(); err != nil {
		return OSInfo{}, err
	}

	return OSInfo{
		Name:       values["NAME"],
		ID:         values["ID"],
		Version:    values["VERSION"],
		VersionID:  values["VERSION_ID"],
		PrettyName: values["PRETTY_NAME"],
	}, nil
}

func newScanID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return fmt.Sprintf("scan-%d", time.Now().UTC().UnixNano())
	}

	return "scan-" + hex.EncodeToString(raw[:])
}
