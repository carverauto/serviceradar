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
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

var ErrNoPendingUpload = errors.New("endpoint inventory upload is not pending")

const (
	MetadataReasonKey                   = "reason"
	MetadataReasonFullScanHashUnchanged = "full_scan_hash_unchanged"
)

func PayloadRequiresFullUpload(payload *ScanPayload) bool {
	return payload != nil &&
		payload.State == scanStateScanned &&
		payload.CoverageState == coverageComplete &&
		payload.UploadReason == UploadReasonChanged &&
		payload.PackageSetHash != "" &&
		payload.ArtifactHash != "" &&
		payload.SBOM != nil
}

// stableUnchangedScanIDPrefix prefixes the deterministic scan id minted for an
// already-acknowledged unchanged status so the value is identical across scans.
const stableUnchangedScanIDPrefix = "unchanged-"

// IsUploadedUnchangedScan reports whether a status payload represents a scan
// whose package set is unchanged and has already been acknowledged upstream
// (the manifest's last-uploaded hashes match the payload). Such a payload
// carries no new information for core and must not generate fresh ingest rows
// on every heartbeat.
func IsUploadedUnchangedScan(payload *ScanPayload, manifest *InventoryCacheManifest) bool {
	if payload == nil || manifest == nil {
		return false
	}
	if payload.SBOM != nil || PayloadRequiresFullUpload(payload) {
		return false
	}
	if manifest.PendingUpload != nil {
		return false
	}
	if payload.PackageSetHash == "" || payload.ArtifactHash == "" {
		return false
	}

	return manifest.LastUploadedPackageSetHash == payload.PackageSetHash &&
		manifest.LastUploadedArtifactHash == payload.ArtifactHash
}

// UploadAcknowledged reports whether the cache contains positive hash evidence
// that the exact payload was acknowledged upstream and no retry remains.
func UploadAcknowledged(payload *ScanPayload, manifest *InventoryCacheManifest) bool {
	if payload == nil || manifest == nil || manifest.PendingUpload != nil {
		return false
	}
	if payload.PackageSetHash == "" || payload.ArtifactHash == "" {
		return false
	}

	return manifest.LastUploadedPackageSetHash == payload.PackageSetHash &&
		manifest.LastUploadedArtifactHash == payload.ArtifactHash
}

// ShouldStabilizeUnchangedScan keeps cached timer wakeups byte-stable while
// allowing a completed unchanged full scan to carry one real freshness update.
func ShouldStabilizeUnchangedScan(payload *ScanPayload, manifest *InventoryCacheManifest) bool {
	if !IsUploadedUnchangedScan(payload, manifest) {
		return false
	}

	reason, _ := payload.Metadata[MetadataReasonKey].(string)
	return reason != MetadataReasonFullScanHashUnchanged
}

// StabilizeUnchangedScanPayload normalizes the volatile fields of an
// already-acknowledged unchanged status so repeated emissions produce a
// byte-identical payload. The scan id is replaced with a deterministic value
// derived from the package-set hash, per-scan timestamps and durations are
// cleared, and the upload reason is pinned to unchanged. The package-set and
// artifact hashes (the identity-bearing fields core reconciles against) are
// preserved.
func StabilizeUnchangedScanPayload(payload *ScanPayload) {
	if payload == nil {
		return
	}

	payload.ScanID = StableUnchangedScanID(payload.PackageSetHash)
	payload.UploadReason = UploadReasonUnchanged
	payload.SBOM = nil
	payload.State = scanStateUnchanged
	payload.CoverageState = coverageUnchanged
	payload.LastScanAt = time.Time{}
	payload.LastSuccessfulScanAt = nil
	payload.DurationMillis = 0

	if payload.Metadata == nil {
		payload.Metadata = map[string]any{}
	}
	payload.Metadata["reason"] = "upload_already_acknowledged"
	// Drop volatile counters that change every scan but carry no ingest value.
	delete(payload.Metadata, "scans_since_full")
	delete(payload.Metadata, "server_reconcile_requested_at")
	// Cached timer wakeups are not scanner runs. ScaLibR metadata embeds another
	// scan id and timestamps, so retaining it would defeat heartbeat dedup and
	// create hourly scanner-activity signals.
	delete(payload.Metadata, "scanner_activity")
	delete(payload.Metadata, "scanner_findings")
	delete(payload.Metadata, "scanner_findings_count")
}

// StableUnchangedScanID derives a deterministic scan id for an unchanged
// status from the package-set hash so the value is stable across scans. Falling
// back to a fixed sentinel keeps the signature stable even when the hash is
// somehow empty (which IsUploadedUnchangedScan already guards against).
func StableUnchangedScanID(packageSetHash string) string {
	hash := strings.TrimSpace(packageSetHash)
	if hash == "" {
		return stableUnchangedScanIDPrefix + "unknown"
	}

	sum := sha256.Sum256([]byte(hash))

	return stableUnchangedScanIDPrefix + hex.EncodeToString(sum[:16])
}

func PendingUploadDue(cfg Config, manifest *InventoryCacheManifest, now time.Time) bool {
	pending := pendingUpload(manifest)
	if pending == nil {
		return false
	}
	if pending.Exhausted {
		return false
	}
	if maxAttempts := pendingRetryMaxAttempts(cfg, pending); maxAttempts > 0 && pending.Attempts >= maxAttempts {
		return false
	}

	dueAt := pending.AvailableAfter
	if pending.NextAttemptAt != nil && pending.NextAttemptAt.After(dueAt) {
		dueAt = *pending.NextAttemptAt
	}

	return !now.UTC().Before(dueAt.UTC())
}

func PendingUploadExhausted(cfg Config, manifest *InventoryCacheManifest) bool {
	pending := pendingUpload(manifest)
	return pending != nil &&
		(pending.Exhausted ||
			(pendingRetryMaxAttempts(cfg, pending) > 0 && pending.Attempts >= pendingRetryMaxAttempts(cfg, pending)))
}

func PendingUploadDelay(cfg Config, payload *ScanPayload) time.Duration {
	jitter, err := time.ParseDuration(cfg.UploadJitter)
	if err != nil || jitter <= 0 || payload == nil {
		return 0
	}

	sum := sha256.Sum256([]byte(cfg.AgentID + "\x00" + payload.PackageSetHash + "\x00" + payload.ArtifactHash))
	bucket := binary.BigEndian.Uint64(sum[:8])
	window := uint64(jitter.Nanoseconds())
	if window == 0 {
		return 0
	}

	return time.Duration(bucket % (window + 1))
}

func MarkUploadSucceeded(cfg Config, payload *ScanPayload, uploadedAt time.Time) error {
	if !PayloadRequiresFullUpload(payload) {
		return nil
	}

	return withCacheManifestLock(cfg, func() error {
		manifest, err := readCacheManifestUnlocked(cfg)
		if err != nil {
			return err
		}
		if !ensurePendingIdentity(cfg, manifest, payload) {
			return ErrNoPendingUpload
		}

		pending := *manifest.PendingUpload
		manifest.LastUploadedPackageSetHash = payload.PackageSetHash
		manifest.LastUploadedArtifactHash = payload.ArtifactHash
		manifest.PendingUpload = nil
		if sameReconcileRequest(manifest.ServerReconcileRequestedAt, pending.ReconcileRequestedAt) {
			manifest.ServerReconcileRequestedAt = nil
			manifest.ServerReconcileReason = ""
		}
		manifest.UpdatedAt = uploadedAt.UTC()

		if err := writeCacheManifestUnlocked(cfg, manifest); err != nil {
			return err
		}
		if err := os.Remove(PendingUploadPath(cfg.SpoolDir)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove endpoint inventory pending upload: %w", err)
		}

		return nil
	})
}

func MarkServerReconcileRequested(cfg Config, requestedAt time.Time, reason string) error {
	requested := requestedAt.UTC()
	if requested.IsZero() {
		requested = time.Now().UTC()
	}

	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = metadataReasonServerReconcileFloor
	}

	return withCacheManifestLock(cfg, func() error {
		manifest, err := readCacheManifestUnlocked(cfg)
		if err != nil {
			return err
		}
		if manifest == nil {
			manifest = &InventoryCacheManifest{
				SchemaVersion:   CacheVersion,
				AgentID:         cfg.AgentID,
				Packages:        []Package{},
				SourceSummaries: []SourceSummary{},
				SourceMTimes:    map[string]SourceMTime{},
			}
		}
		if manifest.ServerReconcileRequestedAt != nil && !requested.After(*manifest.ServerReconcileRequestedAt) {
			return nil
		}

		manifest.SchemaVersion = CacheVersion
		manifest.AgentID = cfg.AgentID
		manifest.ServerReconcileRequestedAt = &requested
		manifest.ServerReconcileReason = reason
		manifest.UpdatedAt = requested

		return writeCacheManifestUnlocked(cfg, manifest)
	})
}

func MarkUploadFailed(cfg Config, payload *ScanPayload, failedAt time.Time, cause error) error {
	if !PayloadRequiresFullUpload(payload) {
		return nil
	}

	return withCacheManifestLock(cfg, func() error {
		manifest, err := readCacheManifestUnlocked(cfg)
		if err != nil {
			return err
		}
		if !ensurePendingIdentity(cfg, manifest, payload) {
			return ErrNoPendingUpload
		}

		pending := manifest.PendingUpload
		failed := failedAt.UTC()
		pending.Attempts++
		pending.LastAttemptAt = &failed
		pending.UpdatedAt = failed
		if cause != nil {
			pending.LastError = cause.Error()
		}
		maxAttempts := pendingRetryMaxAttempts(cfg, pending)
		if maxAttempts > 0 && pending.Attempts >= maxAttempts {
			pending.Exhausted = true
			pending.NextAttemptAt = nil
		} else {
			next := failed.Add(retryDelay(cfg, pending, pending.Attempts))
			pending.NextAttemptAt = &next
		}

		return writeCacheManifestUnlocked(cfg, manifest)
	})
}

func pendingUpload(manifest *InventoryCacheManifest) *PendingUploadState {
	if manifest == nil || manifest.PendingUpload == nil || manifest.PendingUpload.PackageSetHash == "" {
		return nil
	}

	return manifest.PendingUpload
}

func pendingMatchesPayload(manifest *InventoryCacheManifest, payload *ScanPayload) bool {
	pending := pendingUpload(manifest)
	producerID := ""
	if payload != nil {
		producerID = scannerProducerID(payload.Metadata)
	}
	return pendingCoreMatchesPayload(manifest, payload) &&
		pending.AgentID == payload.AgentID &&
		pending.ConfigHash == payload.ConfigHash &&
		pending.ProducerID == producerID &&
		pending.ProducerVersion == payload.CollectorVersion
}

func pendingCoreMatchesPayload(manifest *InventoryCacheManifest, payload *ScanPayload) bool {
	pending := pendingUpload(manifest)
	return pending != nil &&
		payload != nil &&
		PayloadRequiresFullUpload(payload) &&
		pending.PackageSetHash == payload.PackageSetHash &&
		pending.ArtifactHash == payload.ArtifactHash &&
		pending.ScanID == payload.ScanID
}

func legacyPendingPayloadMatchesConfig(cfg Config, manifest *InventoryCacheManifest, payload *ScanPayload) bool {
	pending := pendingUpload(manifest)
	if !pendingCoreMatchesPayload(manifest, payload) || pending == nil ||
		!pendingIdentityEmpty(pending) || manifest == nil ||
		strings.TrimSpace(manifest.ConfigHash) != "" ||
		strings.TrimSpace(manifest.ProducerID) != "" ||
		strings.TrimSpace(manifest.ProducerVersion) != "" {
		return false
	}

	return payload.AgentID == cfg.AgentID &&
		(manifest.AgentID == "" || manifest.AgentID == payload.AgentID) &&
		strings.TrimSpace(payload.ConfigHash) != "" &&
		strings.TrimSpace(scannerProducerID(payload.Metadata)) != "" &&
		strings.TrimSpace(payload.CollectorVersion) != ""
}

func pendingIdentityEmpty(pending *PendingUploadState) bool {
	return pending != nil &&
		strings.TrimSpace(pending.AgentID) == "" &&
		strings.TrimSpace(pending.ConfigHash) == "" &&
		strings.TrimSpace(pending.ProducerID) == "" &&
		strings.TrimSpace(pending.ProducerVersion) == ""
}

func ensurePendingIdentity(cfg Config, manifest *InventoryCacheManifest, payload *ScanPayload) bool {
	if pendingMatchesPayload(manifest, payload) {
		return true
	}
	if !legacyPendingPayloadMatchesConfig(cfg, manifest, payload) {
		return false
	}

	pending := manifest.PendingUpload
	producerID := scannerProducerID(payload.Metadata)
	pending.AgentID = payload.AgentID
	pending.ConfigHash = payload.ConfigHash
	pending.ProducerID = producerID
	pending.ProducerVersion = payload.CollectorVersion
	manifest.AgentID = payload.AgentID
	manifest.ConfigHash = payload.ConfigHash
	manifest.ProducerID = producerID
	manifest.ProducerVersion = payload.CollectorVersion

	return true
}

func sameReconcileRequest(current *time.Time, captured *time.Time) bool {
	if current == nil || captured == nil {
		return current == nil && captured == nil
	}

	return current.Equal(*captured)
}

func pendingRetryMaxAttempts(cfg Config, pending *PendingUploadState) int {
	if pending != nil && pending.RetryMaxAttempts > 0 {
		return pending.RetryMaxAttempts
	}

	return cfg.UploadRetryMaxAttempts
}

func retryDelay(cfg Config, pending *PendingUploadState, attempt int) time.Duration {
	initialSetting := cfg.UploadRetryInitial
	maxSetting := cfg.UploadRetryMax
	if pending != nil {
		if strings.TrimSpace(pending.RetryInitial) != "" {
			initialSetting = pending.RetryInitial
		}
		if strings.TrimSpace(pending.RetryMax) != "" {
			maxSetting = pending.RetryMax
		}
	}

	initial, err := time.ParseDuration(initialSetting)
	if err != nil || initial <= 0 {
		initial = 5 * time.Minute
	}
	maxDelay, err := time.ParseDuration(maxSetting)
	if err != nil || maxDelay <= 0 {
		maxDelay = time.Hour
	}
	if attempt <= 1 {
		return minDuration(initial, maxDelay)
	}

	delay := initial
	for i := 1; i < attempt; i++ {
		if delay >= maxDelay/2 {
			return maxDelay
		}
		delay *= 2
	}

	return minDuration(delay, maxDelay)
}

func minDuration(left, right time.Duration) time.Duration {
	if left < right {
		return left
	}

	return right
}
