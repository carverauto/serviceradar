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

package endpointinventory

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

func CollectSourceMTimes(cfg Config) map[string]SourceMTime {
	mtimes := make(map[string]SourceMTime, len(cfg.Sources))

	for _, source := range cfg.Sources {
		mtimes[source] = sourceMTime(source, sourceMTimeCandidatePaths(cfg, source))
	}

	return mtimes
}

// CacheCanSkipFullScan reports whether a producer can use its cached package set
// instead of performing an expensive full collection. Cadence is the single
// time-based owner: timer units may wake the producer more frequently, but an
// unchanged source set is fully rescanned once the configured cadence elapses.
func CacheCanSkipFullScan(
	cfg Config,
	identity CacheIdentity,
	manifest *InventoryCacheManifest,
	current map[string]SourceMTime,
	now time.Time,
) bool {
	if manifest == nil || manifest.PackageSetHash == "" || manifest.ArtifactHash == "" {
		return false
	}
	if cfg.ForceFreshScan {
		return false
	}
	var pendingPayload *ScanPayload
	if manifest.PendingUpload != nil {
		var err error
		pendingPayload, _, err = readMatchingPendingPayloadUnlocked(cfg, manifest)
		if err != nil {
			return false
		}
	}
	if !cacheIdentityMatches(manifest, identity) &&
		!legacyPendingProvesIdentity(manifest, pendingPayload, identity) {
		return false
	}
	if manifest.ServerReconcileRequestedAt != nil && manifest.PendingUpload == nil {
		return false
	}
	if !sourceMTimesEqual(cfg.Sources, manifest.SourceMTimes, current) {
		return false
	}
	if cadence, ok := configuredCadence(cfg); ok {
		anchor := cadenceAnchor(manifest, pendingPayload)
		return !anchor.IsZero() && now.UTC().Before(anchor.Add(cadence))
	}

	// Older/custom configurations with no usable cadence retain the bounded
	// scan-count fallback instead of scanning on every timer wakeup.
	if cfg.ForceFullScanInterval <= 1 {
		return false
	}
	if manifest.ScansSinceFull >= cfg.ForceFullScanInterval-1 {
		return false
	}

	return true
}

func readMatchingPendingPayloadUnlocked(
	cfg Config,
	manifest *InventoryCacheManifest,
) (*ScanPayload, []byte, error) {
	data, err := os.ReadFile(PendingUploadPath(cfg.SpoolDir))
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %w", ErrPendingUploadUnavailable, err)
	}

	var payload ScanPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, nil, fmt.Errorf("%w: decode payload: %w", ErrPendingUploadUnavailable, err)
	}
	if !pendingCoreMatchesPayload(manifest, &payload) ||
		(!pendingMatchesPayload(manifest, &payload) && !legacyPendingPayloadMatchesConfig(cfg, manifest, &payload)) {
		return nil, nil, fmt.Errorf("%w: payload identity does not match manifest", ErrPendingUploadUnavailable)
	}

	return &payload, data, nil
}

func cacheIdentityMatches(manifest *InventoryCacheManifest, identity CacheIdentity) bool {
	return manifest != nil &&
		strings.TrimSpace(identity.AgentID) != "" &&
		strings.TrimSpace(identity.ConfigHash) != "" &&
		strings.TrimSpace(identity.ProducerID) != "" &&
		strings.TrimSpace(identity.ProducerVersion) != "" &&
		manifest.AgentID == identity.AgentID &&
		manifest.ConfigHash == identity.ConfigHash &&
		manifest.ProducerID == identity.ProducerID &&
		manifest.ProducerVersion == identity.ProducerVersion
}

func legacyPendingProvesIdentity(
	manifest *InventoryCacheManifest,
	payload *ScanPayload,
	identity CacheIdentity,
) bool {
	if manifest == nil || payload == nil ||
		strings.TrimSpace(manifest.ConfigHash) != "" ||
		strings.TrimSpace(manifest.ProducerID) != "" ||
		strings.TrimSpace(manifest.ProducerVersion) != "" {
		return false
	}

	producerID, _ := payload.Metadata["scanner_producer_id"].(string)
	return (manifest.AgentID == "" || manifest.AgentID == payload.AgentID) &&
		payload.AgentID == identity.AgentID &&
		payload.ConfigHash == identity.ConfigHash &&
		producerID == identity.ProducerID &&
		payload.CollectorVersion == identity.ProducerVersion
}

func cadenceAnchor(manifest *InventoryCacheManifest, pendingPayload *ScanPayload) time.Time {
	if manifest == nil {
		return time.Time{}
	}
	if manifest.LastFullScanAt != nil && !manifest.LastFullScanAt.IsZero() {
		return manifest.LastFullScanAt.UTC()
	}
	if pendingPayload != nil && !pendingPayload.LastScanAt.IsZero() {
		return pendingPayload.LastScanAt.UTC()
	}
	if manifest.PendingUpload != nil && !manifest.PendingUpload.CreatedAt.IsZero() {
		return manifest.PendingUpload.CreatedAt.UTC()
	}

	return time.Time{}
}

func configuredCadence(cfg Config) (time.Duration, bool) {
	cadence, err := time.ParseDuration(cfg.Cadence)
	if err != nil || cadence <= 0 {
		return 0, false
	}

	return cadence, true
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
