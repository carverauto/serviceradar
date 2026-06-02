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
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const collectorName = "serviceradar-endpoint-inventory"

const (
	scanStateFailed       = "scan_failed"
	scanStateNotScanned   = "not_scanned"
	scanStateNotSupported = "not_supported"
	scanStateScanned      = "scanned"
	scanStateUnchanged    = "unchanged"

	coverageComplete                 = "complete"
	coverageDisabled                 = "disabled"
	coverageFailed                   = "failed"
	coverageNoSupportedPackageSource = "no_supported_package_source"
	coverageUnchanged                = "unchanged"
)

var errPackageLimitExceeded = errors.New("endpoint inventory package limit exceeded")

type Runner struct {
	cfg Config
}

func NewRunner(cfg Config) *Runner {
	return &Runner{cfg: cfg}
}

func (r *Runner) Run(ctx context.Context) (*ScanPayload, error) {
	started := time.Now().UTC()
	if !r.cfg.Enabled {
		return disabledPayload(r.cfg, started), nil
	}

	ctx, cancel := context.WithTimeout(ctx, ScanTimeout(r.cfg))
	defer cancel()

	osInfo, _ := ReadOSRelease(r.cfg.OSReleasePath)
	sourceMTimes := CollectSourceMTimes(r.cfg)
	cache, err := ReadCacheManifest(r.cfg)
	if err != nil {
		return nil, err
	}
	if cacheCanSkipFullScan(r.cfg, cache, sourceMTimes) {
		payload := r.unchangedPayload(started, osInfo, cache, "source_mtime_unchanged")
		if err := WriteCacheManifest(r.cfg, unchangedManifest(r.cfg, cache, sourceMTimes, started)); err != nil {
			return nil, err
		}

		return payload, nil
	}

	packages, sources := r.collectPackages(ctx)
	if len(packages) > r.cfg.MaxPackages {
		return failurePayload(r.cfg, started, osInfo, sources, errPackageLimitExceeded), nil
	}

	state := scanStateScanned
	coverage := coverageComplete
	if len(packages) == 0 {
		state = scanStateNotSupported
		coverage = coverageNoSupportedPackageSource
	}
	sbom := BuildCycloneDX(r.cfg, started, osInfo, packages)
	packageSetHash := ComputePackageSetHash(packages)
	artifactHash := ComputeArtifactHash(sbom)
	uploadReason := UploadReasonChanged
	if cache != nil && cache.PackageSetHash == packageSetHash && cache.ArtifactHash == artifactHash {
		uploadReason = UploadReasonUnchanged
	}

	payload := &ScanPayload{
		SchemaVersion:        SchemaVersion,
		AgentID:              r.cfg.AgentID,
		ScanID:               newScanID(),
		State:                state,
		CoverageState:        coverage,
		LastScanAt:           started,
		LastSuccessfulScanAt: &started,
		OS:                   osInfo,
		Sources:              sources,
		PackageCount:         len(packages),
		PackageSetHash:       packageSetHash,
		ArtifactHash:         artifactHash,
		HashAlgorithm:        HashAlgorithm,
		UploadReason:         uploadReason,
		Metadata: map[string]any{
			"sources_enabled": append([]string(nil), r.cfg.Sources...),
		},
	}
	if uploadReason == UploadReasonChanged {
		payload.SBOM = &sbom
	} else {
		payload.State = scanStateUnchanged
		payload.CoverageState = coverageUnchanged
		payload.Metadata["reason"] = "full_scan_hash_unchanged"
	}

	if err := WriteCacheManifest(r.cfg, fullScanManifest(r.cfg, cache, payload, sourceMTimes, started)); err != nil {
		return nil, err
	}

	return payload, nil
}

func disabledPayload(cfg Config, scannedAt time.Time) *ScanPayload {
	return &ScanPayload{
		SchemaVersion: SchemaVersion,
		AgentID:       cfg.AgentID,
		ScanID:        "endpoint-inventory-disabled",
		State:         scanStateNotScanned,
		CoverageState: coverageDisabled,
		LastScanAt:    scannedAt,
		Sources:       []SourceSummary{},
		Metadata: map[string]any{
			"reason": "disabled",
		},
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
		State:                scanStateUnchanged,
		CoverageState:        coverageUnchanged,
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: &scannedAt,
		OS:                   osInfo,
		Sources:              append([]SourceSummary(nil), cache.SourceSummaries...),
		PackageCount:         cache.PackageCount,
		PackageSetHash:       cache.PackageSetHash,
		ArtifactHash:         cache.ArtifactHash,
		HashAlgorithm:        firstNonEmpty(cache.HashAlgorithm, HashAlgorithm),
		UploadReason:         UploadReasonUnchanged,
		Metadata: map[string]any{
			"reason":           reason,
			"sources_enabled":  append([]string(nil), r.cfg.Sources...),
			"scans_since_full": cache.ScansSinceFull + 1,
		},
	}
}

func (r *Runner) collectPackages(ctx context.Context) ([]Package, []SourceSummary) {
	packages := make([]Package, 0, initialPackageCapacity(r.cfg))
	summaries := make([]SourceSummary, 0, len(r.cfg.Sources))

	for _, source := range r.cfg.Sources {
		var (
			collected []Package
			err       error
		)

		switch source {
		case PackageSourceDpkg:
			collected, err = CollectDpkgPackages(r.cfg.DpkgStatusPath)
		case PackageSourceAPK:
			collected, err = CollectAPKPackages(r.cfg.APKInstalledPath)
		case PackageSourceRPM:
			collected, err = CollectRPMPackages(ctx, r.cfg.RPMPath)
		default:
			err = fmt.Errorf("%w: %s", ErrUnsupportedSource, source)
		}

		summary := SourceSummary{Source: source, State: "scanned", PackageCount: len(collected)}
		if err != nil {
			summary.State = "unavailable"
			if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, exec.ErrNotFound) {
				summary.State = "error"
				summary.Error = err.Error()
			}
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

func failurePayload(cfg Config, scannedAt time.Time, osInfo OSInfo, sources []SourceSummary, err error) *ScanPayload {
	return &ScanPayload{
		SchemaVersion: SchemaVersion,
		AgentID:       cfg.AgentID,
		ScanID:        newScanID(),
		State:         scanStateFailed,
		CoverageState: coverageFailed,
		LastScanAt:    scannedAt,
		OS:            osInfo,
		Sources:       sources,
		Metadata: map[string]any{
			"error": err.Error(),
		},
	}
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
