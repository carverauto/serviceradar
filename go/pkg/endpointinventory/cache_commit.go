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
	"errors"
	"fmt"
	"os"
	"time"
)

func unchangedManifest(
	identity CacheIdentity,
	previous *InventoryCacheManifest,
	current map[string]SourceMTime,
	scannedAt time.Time,
	pendingPayload *ScanPayload,
) *InventoryCacheManifest {
	manifest := copyCacheManifest(previous)
	manifest.SchemaVersion = CacheVersion
	manifest.AgentID = identity.AgentID
	manifest.ConfigHash = identity.ConfigHash
	manifest.ProducerID = identity.ProducerID
	manifest.ProducerVersion = identity.ProducerVersion
	if manifest.PendingUpload != nil && pendingIdentityEmpty(manifest.PendingUpload) {
		manifest.PendingUpload.AgentID = identity.AgentID
		manifest.PendingUpload.ConfigHash = identity.ConfigHash
		manifest.PendingUpload.ProducerID = identity.ProducerID
		manifest.PendingUpload.ProducerVersion = identity.ProducerVersion
	}
	manifest.SourceMTimes = copySourceMTimes(current)
	manifest.LastScanAt = scannedAt
	if manifest.LastFullScanAt == nil {
		anchor := cadenceAnchor(previous, pendingPayload)
		if !anchor.IsZero() {
			manifest.LastFullScanAt = &anchor
		}
	}
	manifest.ScansSinceFull++
	manifest.UnchangedScanCount++
	manifest.UpdatedAt = scannedAt

	return manifest
}

// RecordCachedScan persists the lightweight source check performed when a full
// scan is not yet due. It deliberately leaves LastFullScanAt unchanged.
func RecordCachedScan(
	cfg Config,
	identity CacheIdentity,
	current map[string]SourceMTime,
	scannedAt time.Time,
) error {
	return withCacheManifestLock(cfg, func() error {
		latest, err := readCacheManifestUnlocked(cfg)
		if err != nil {
			return err
		}
		if !CacheCanSkipFullScan(cfg, identity, latest, current, scannedAt) {
			return ErrCacheRefreshRequired
		}

		var pendingPayload *ScanPayload
		if latest.PendingUpload != nil {
			pendingPayload, _, err = readMatchingPendingPayloadUnlocked(cfg, latest)
			if err != nil {
				return err
			}
		}

		return writeCacheManifestUnlocked(
			cfg,
			unchangedManifest(identity, latest, current, scannedAt, pendingPayload),
		)
	})
}

func fullScanManifest(
	cfg Config,
	identity CacheIdentity,
	previous *InventoryCacheManifest,
	payload *ScanPayload,
	packages []Package,
	current map[string]SourceMTime,
	scannedAt time.Time,
) *InventoryCacheManifest {
	manifest := copyCacheManifest(previous)
	manifest.SchemaVersion = CacheVersion
	manifest.AgentID = identity.AgentID
	manifest.ConfigHash = identity.ConfigHash
	manifest.ProducerID = identity.ProducerID
	manifest.ProducerVersion = identity.ProducerVersion
	manifest.PackageSetHash = payload.PackageSetHash
	manifest.ArtifactHash = payload.ArtifactHash
	manifest.HashAlgorithm = payload.HashAlgorithm
	manifest.PackageCount = payload.PackageCount
	manifest.Packages = append([]Package(nil), packages...)
	manifest.SourceSummaries = append([]SourceSummary(nil), payload.Diagnostics...)
	manifest.SourceMTimes = copySourceMTimes(current)
	manifest.StandingQuestionResultCounts = copyStandingQuestionResultCounts(payload.StandingQuestionResultCounts)
	manifest.LastScanAt = scannedAt
	manifest.LastSuccessfulScanAt = payload.LastSuccessfulScanAt
	fullScanAt := scannedAt.UTC()
	manifest.LastFullScanAt = &fullScanAt
	manifest.ScansSinceFull = 0
	manifest.FullScanCount++
	manifest.UpdatedAt = scannedAt

	if payload.UploadReason == UploadReasonChanged {
		manifest.LastChangedScanAt = payload.LastSuccessfulScanAt
		manifest.UnchangedScanCount = 0
		manifest.PendingUpload = pendingUploadState(cfg, previous, payload, scannedAt)
	} else {
		manifest.UnchangedScanCount++
	}

	return manifest
}

// FinalizeFullScan applies the shared upload/reconcile policy and persists the
// cache manifest before the caller publishes the payload to the spool.
func FinalizeFullScan(
	cfg Config,
	identity CacheIdentity,
	payload *ScanPayload,
	packages []Package,
	current map[string]SourceMTime,
	scannedAt time.Time,
) error {
	if payload == nil {
		return nil
	}
	if !PayloadRequiresFullUpload(payload) {
		return ErrIncompleteFullScan
	}

	return withCacheManifestLock(cfg, func() error {
		latest, err := readCacheManifestUnlocked(cfg)
		if err != nil {
			return err
		}
		if latest != nil && latest.LastFullScanAt != nil && latest.LastFullScanAt.After(scannedAt.UTC()) {
			return ErrStaleFullScan
		}

		base := manifestForIdentity(cfg, latest, identity)
		serverReconcileRequested := base != nil && base.ServerReconcileRequestedAt != nil
		uploadedUnchanged := base != nil &&
			base.PendingUpload == nil &&
			base.LastUploadedPackageSetHash == payload.PackageSetHash &&
			base.LastUploadedArtifactHash == payload.ArtifactHash &&
			!serverReconcileRequested

		if uploadedUnchanged {
			payload.UploadReason = UploadReasonUnchanged
			payload.State = scanStateUnchanged
			payload.CoverageState = coverageUnchanged
			payload.SBOM = nil
			payload.PackageDelta = nil
			payload.Metadata = withMetadataValue(payload.Metadata, MetadataReasonKey, MetadataReasonFullScanHashUnchanged)
		} else {
			payload.UploadReason = UploadReasonChanged
			payload.PackageDelta = changedScanDelta(base, packages, payload.PackageSetHash, serverReconcileRequested)
			if serverReconcileRequested {
				payload.Metadata = withMetadataValues(payload.Metadata, map[string]any{
					MetadataReasonKey:               metadataReasonServerReconcileFloor,
					"server_reconcile_requested_at": base.ServerReconcileRequestedAt,
					"server_reconcile_reason":       base.ServerReconcileReason,
				})
			}
		}

		manifest := fullScanManifest(cfg, identity, base, payload, packages, current, scannedAt)
		if manifest.PendingUpload != nil {
			if err := writePendingUploadUnlocked(cfg, payload); err != nil {
				return err
			}
		}
		if err := writeCacheManifestUnlocked(cfg, manifest); err != nil {
			return err
		}
		if manifest.PendingUpload == nil {
			if err := os.Remove(PendingUploadPath(cfg.SpoolDir)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("remove stale endpoint inventory pending upload: %w", err)
			}
		}

		return nil
	})
}

func manifestForIdentity(
	cfg Config,
	latest *InventoryCacheManifest,
	identity CacheIdentity,
) *InventoryCacheManifest {
	if cacheIdentityMatches(latest, identity) {
		return latest
	}
	if latest != nil && latest.PendingUpload != nil {
		pendingPayload, _, err := readMatchingPendingPayloadUnlocked(cfg, latest)
		if err == nil && legacyPendingProvesIdentity(latest, pendingPayload, identity) {
			return latest
		}
	}

	fresh := copyCacheManifest(nil)
	if latest != nil {
		fresh.ServerReconcileRequestedAt = latest.ServerReconcileRequestedAt
		fresh.ServerReconcileReason = latest.ServerReconcileReason
	}

	return fresh
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
		ScanID:               payload.ScanID,
		AgentID:              payload.AgentID,
		ConfigHash:           payload.ConfigHash,
		ProducerID:           scannerProducerID(payload.Metadata),
		ProducerVersion:      payload.CollectorVersion,
		PackageSetHash:       payload.PackageSetHash,
		ArtifactHash:         payload.ArtifactHash,
		UploadReason:         payload.UploadReason,
		RetryInitial:         cfg.UploadRetryInitial,
		RetryMax:             cfg.UploadRetryMax,
		RetryMaxAttempts:     cfg.UploadRetryMaxAttempts,
		ReconcileRequestedAt: reconcileRequestedAt(previous),
		AvailableAfter:       availableAfter,
		CreatedAt:            scannedAt,
		UpdatedAt:            scannedAt,
	}
}

func scannerProducerID(metadata map[string]any) string {
	value, _ := metadata["scanner_producer_id"].(string)
	return value
}

func reconcileRequestedAt(manifest *InventoryCacheManifest) *time.Time {
	if manifest == nil || manifest.ServerReconcileRequestedAt == nil {
		return nil
	}
	requested := manifest.ServerReconcileRequestedAt.UTC()
	return &requested
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
	if previous.PendingUpload != nil {
		pending := *previous.PendingUpload
		manifest.PendingUpload = &pending
	}

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
