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
	"errors"
	"fmt"
	"os"
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
	manifest.UpdatedAt = uploadedAt.UTC()

	if err := WriteCacheManifest(cfg, manifest); err != nil {
		return err
	}

	if err := os.Remove(PendingUploadPath(cfg.SpoolDir)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove endpoint inventory pending upload: %w", err)
	}

	return nil
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
