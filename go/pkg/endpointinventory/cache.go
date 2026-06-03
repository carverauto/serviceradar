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
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const CacheManifestFileName = "manifest.json"

func CacheManifestPath(cacheDir string) string {
	return filepath.Join(cacheDir, CacheManifestFileName)
}

func ReadCacheManifest(cfg Config) (*InventoryCacheManifest, error) {
	data, err := os.ReadFile(CacheManifestPath(cfg.CacheDir))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}

		return nil, fmt.Errorf("read endpoint inventory cache manifest: %w", err)
	}

	var manifest InventoryCacheManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("decode endpoint inventory cache manifest: %w", err)
	}

	return &manifest, nil
}

func WriteCacheManifest(cfg Config, manifest *InventoryCacheManifest) error {
	if manifest == nil {
		return nil
	}

	if err := os.MkdirAll(cfg.CacheDir, 0750); err != nil {
		return fmt.Errorf("create endpoint inventory cache dir: %w", err)
	}
	if err := os.MkdirAll(cfg.TmpDir, 0750); err != nil {
		return fmt.Errorf("create tmp dir: %w", err)
	}

	if err := writeJSONAtomic(CacheManifestPath(cfg.CacheDir), cfg.TmpDir, cfg.MaxOutputBytes, manifest); err != nil {
		return fmt.Errorf("write endpoint inventory cache manifest: %w", err)
	}

	return nil
}

func CollectSourceMTimes(cfg Config) map[string]SourceMTime {
	mtimes := make(map[string]SourceMTime, len(cfg.Sources))

	for _, source := range cfg.Sources {
		mtimes[source] = sourceMTime(source, sourceMTimeCandidatePaths(cfg, source))
	}

	return mtimes
}

func cacheCanSkipFullScan(cfg Config, manifest *InventoryCacheManifest, current map[string]SourceMTime) bool {
	if manifest == nil || manifest.PackageSetHash == "" || manifest.ArtifactHash == "" {
		return false
	}
	if manifest.ServerReconcileRequestedAt != nil {
		return false
	}
	if cfg.ForceFullScanInterval <= 1 {
		return false
	}
	if manifest.ScansSinceFull >= cfg.ForceFullScanInterval-1 {
		return false
	}

	return sourceMTimesEqual(cfg.Sources, manifest.SourceMTimes, current)
}

func sourceMTimesEqual(sources []string, previous map[string]SourceMTime, current map[string]SourceMTime) bool {
	for _, source := range sources {
		if previous[source] != current[source] {
			return false
		}
	}

	return true
}

func sourceMTime(source string, paths []string) SourceMTime {
	if len(paths) == 0 {
		return SourceMTime{Source: source}
	}

	fallback := SourceMTime{Source: source, Path: paths[0]}
	for _, path := range paths {
		trimmed := strings.TrimSpace(path)
		if trimmed == "" {
			continue
		}

		info, err := os.Stat(trimmed)
		if err != nil {
			if fallback.Path == "" {
				fallback.Path = trimmed
			}
			continue
		}

		return SourceMTime{
			Source:        source,
			Path:          trimmed,
			Exists:        true,
			MTimeUnixNano: info.ModTime().UnixNano(),
			Size:          info.Size(),
		}
	}

	return fallback
}

func sourceMTimeCandidatePaths(cfg Config, source string) []string {
	switch source {
	case PackageSourceDpkg:
		return []string{cfg.DpkgStatusPath}
	case PackageSourceAPK:
		return []string{cfg.APKInstalledPath}
	case PackageSourceRPM:
		return append([]string(nil), cfg.RPMDatabasePaths...)
	default:
		return nil
	}
}

func unchangedManifest(cfg Config, previous *InventoryCacheManifest, current map[string]SourceMTime, scannedAt time.Time) *InventoryCacheManifest {
	manifest := copyCacheManifest(previous)
	manifest.SchemaVersion = CacheVersion
	manifest.AgentID = cfg.AgentID
	manifest.SourceMTimes = copySourceMTimes(current)
	manifest.LastScanAt = scannedAt
	manifest.LastSuccessfulScanAt = &scannedAt
	manifest.ScansSinceFull++
	manifest.UnchangedScanCount++
	manifest.UpdatedAt = scannedAt

	return manifest
}

func fullScanManifest(
	cfg Config,
	previous *InventoryCacheManifest,
	payload *ScanPayload,
	packages []Package,
	current map[string]SourceMTime,
	scannedAt time.Time,
) *InventoryCacheManifest {
	manifest := copyCacheManifest(previous)
	manifest.SchemaVersion = CacheVersion
	manifest.AgentID = cfg.AgentID
	manifest.PackageSetHash = payload.PackageSetHash
	manifest.ArtifactHash = payload.ArtifactHash
	manifest.HashAlgorithm = payload.HashAlgorithm
	manifest.PackageCount = payload.PackageCount
	manifest.Packages = append([]Package(nil), packages...)
	manifest.SourceSummaries = append([]SourceSummary(nil), payload.Sources...)
	manifest.SourceMTimes = copySourceMTimes(current)
	manifest.StandingQuestionResultCounts = copyStandingQuestionResultCounts(payload.StandingQuestionResultCounts)
	manifest.LastScanAt = scannedAt
	manifest.LastSuccessfulScanAt = payload.LastSuccessfulScanAt
	manifest.ScansSinceFull = 0
	manifest.FullScanCount++
	manifest.UpdatedAt = scannedAt

	if payload.UploadReason == UploadReasonChanged {
		manifest.LastChangedScanAt = payload.LastSuccessfulScanAt
		manifest.UnchangedScanCount = 0
		manifest.ServerReconcileRequestedAt = nil
		manifest.ServerReconcileReason = ""
		manifest.PendingUpload = pendingUploadState(cfg, previous, payload, scannedAt)
	} else {
		manifest.UnchangedScanCount++
	}

	return manifest
}

func pendingUploadState(
	cfg Config,
	previous *InventoryCacheManifest,
	payload *ScanPayload,
	scannedAt time.Time,
) *PendingUploadState {
	if !PayloadRequiresFullUpload(payload) {
		return nil
	}

	if pendingMatchesPayload(previous, payload) {
		pending := *previous.PendingUpload
		pending.UpdatedAt = scannedAt
		return &pending
	}

	availableAfter := scannedAt.Add(PendingUploadDelay(cfg, payload)).UTC()

	return &PendingUploadState{
		ScanID:         payload.ScanID,
		PackageSetHash: payload.PackageSetHash,
		ArtifactHash:   payload.ArtifactHash,
		UploadReason:   payload.UploadReason,
		AvailableAfter: availableAfter,
		CreatedAt:      scannedAt,
		UpdatedAt:      scannedAt,
	}
}

func copyCacheManifest(previous *InventoryCacheManifest) *InventoryCacheManifest {
	if previous == nil {
		return &InventoryCacheManifest{
			Packages:        []Package{},
			SourceSummaries: []SourceSummary{},
			SourceMTimes:    map[string]SourceMTime{},
		}
	}

	manifest := *previous
	manifest.Packages = append([]Package(nil), previous.Packages...)
	manifest.SourceSummaries = append([]SourceSummary(nil), previous.SourceSummaries...)
	manifest.SourceMTimes = copySourceMTimes(previous.SourceMTimes)
	manifest.StandingQuestionResultCounts = copyStandingQuestionResultCounts(previous.StandingQuestionResultCounts)

	return &manifest
}

func copySourceMTimes(sourceMTimes map[string]SourceMTime) map[string]SourceMTime {
	copied := make(map[string]SourceMTime, len(sourceMTimes))
	for source, sourceMTime := range sourceMTimes {
		copied[source] = sourceMTime
	}

	return copied
}

func copyStandingQuestionResultCounts(counts []StandingQuestionResultCount) []StandingQuestionResultCount {
	copied := make([]StandingQuestionResultCount, 0, len(counts))
	for _, count := range counts {
		next := count
		if count.Labels != nil {
			next.Labels = make(map[string]string, len(count.Labels))
			for key, value := range count.Labels {
				next.Labels[key] = value
			}
		}
		if count.Metadata != nil {
			next.Metadata = make(map[string]string, len(count.Metadata))
			for key, value := range count.Metadata {
				next.Metadata[key] = value
			}
		}
		copied = append(copied, next)
	}

	return copied
}
