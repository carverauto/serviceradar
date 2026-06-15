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

func PayloadRequiresFullUpload(payload *ScanPayload) bool {
	return payload != nil &&
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
	if cfg.UploadRetryMaxAttempts > 0 && pending.Attempts >= cfg.UploadRetryMaxAttempts {
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
		(pending.Exhausted || (cfg.UploadRetryMaxAttempts > 0 && pending.Attempts >= cfg.UploadRetryMaxAttempts))
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

	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		return err
	}
	if !pendingMatchesPayload(manifest, payload) {
		return ErrNoPendingUpload
	}

	manifest.LastUploadedPackageSetHash = payload.PackageSetHash
	manifest.LastUploadedArtifactHash = payload.ArtifactHash
	manifest.PendingUpload = nil
	manifest.ServerReconcileRequestedAt = nil
	manifest.ServerReconcileReason = ""
	manifest.UpdatedAt = uploadedAt.UTC()

	if err := WriteCacheManifest(cfg, manifest); err != nil {
		return err
	}

	if err := os.Remove(PendingUploadPath(cfg.SpoolDir)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove endpoint inventory pending upload: %w", err)
	}

	return nil
}

func MarkServerReconcileRequested(cfg Config, requestedAt time.Time, reason string) error {
	manifest, err := ReadCacheManifest(cfg)
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

	requested := requestedAt.UTC()
	if requested.IsZero() {
		requested = time.Now().UTC()
	}

	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = metadataReasonServerReconcileFloor
	}

	manifest.SchemaVersion = CacheVersion
	manifest.AgentID = cfg.AgentID
	manifest.ServerReconcileRequestedAt = &requested
	manifest.ServerReconcileReason = reason
	manifest.UpdatedAt = requested

	return WriteCacheManifest(cfg, manifest)
}

func MarkUploadFailed(cfg Config, payload *ScanPayload, failedAt time.Time, cause error) error {
	if !PayloadRequiresFullUpload(payload) {
		return nil
	}

	manifest, err := ReadCacheManifest(cfg)
	if err != nil {
		return err
	}
	if !pendingMatchesPayload(manifest, payload) {
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
	if cfg.UploadRetryMaxAttempts > 0 && pending.Attempts >= cfg.UploadRetryMaxAttempts {
		pending.Exhausted = true
		pending.NextAttemptAt = nil
	} else {
		next := failed.Add(retryDelay(cfg, pending.Attempts))
		pending.NextAttemptAt = &next
	}

	return WriteCacheManifest(cfg, manifest)
}

func pendingUpload(manifest *InventoryCacheManifest) *PendingUploadState {
	if manifest == nil || manifest.PendingUpload == nil || manifest.PendingUpload.PackageSetHash == "" {
		return nil
	}

	return manifest.PendingUpload
}

func pendingMatchesPayload(manifest *InventoryCacheManifest, payload *ScanPayload) bool {
	pending := pendingUpload(manifest)
	return pending != nil &&
		payload != nil &&
		pending.PackageSetHash == payload.PackageSetHash &&
		pending.ArtifactHash == payload.ArtifactHash &&
		pending.ScanID == payload.ScanID
}

func retryDelay(cfg Config, attempt int) time.Duration {
	initial, err := time.ParseDuration(cfg.UploadRetryInitial)
	if err != nil || initial <= 0 {
		initial = 5 * time.Minute
	}
	maxDelay, err := time.ParseDuration(cfg.UploadRetryMax)
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
