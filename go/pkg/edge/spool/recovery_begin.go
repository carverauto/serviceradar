// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// BeginRecoveryOperation captures the entire bounded physical source, including
// its retained resolved prefix. The source lifecycle lock excludes resolution
// until the durable hold exists. Neither classification nor copy coordinates
// come from the coordinator, and no current assignment reconstructs old bytes.
func BeginRecoveryOperation(dir string, source, destination *Generation, grant *RecoveryGrant, detectedAt int64, reason string) (*RecoveryOperation, error) {
	if source == nil || destination == nil || grant == nil {
		return nil, ErrRecoveryGrantRequired
	}
	if err := usableRecoveryGrant(grant); err != nil {
		return nil, err
	}
	if err := validateRecoveryCoordinator(grant); err != nil {
		return nil, err
	}
	if !source.Closed() || source.spool.alloc != grant.alloc || destination.spool.alloc != grant.alloc || destination.dir != grant.lane || destination.RecoveryAttempt() != 0 {
		return nil, ErrRecoveryPlan
	}
	bound, err := destination.RecoverySourceIdentity()
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(encodeIdentity(bound), encodeIdentity(source.id)) {
		return nil, ErrRecoveryPlan
	}
	// A retained freeze owns its original timestamp/reason, regardless of the
	// values supplied by a later coordinator invocation.
	if _, err = OpenRecoveryJournal(dir); err == nil {
		return OpenRecoveryOperation(dir, source, destination, grant)
	}
	copies := readRecoveryJournalCopies(dir)
	if !errors.Is(copies[0].err, os.ErrNotExist) || !errors.Is(copies[1].err, os.ErrNotExist) {
		return nil, err
	}
	err = source.withOpen(func(s *Spool) error {
		s.mu.Lock()
		base, high := s.baseSeq, s.nextSeq-1
		s.mu.Unlock()
		if high <= base || high-base > edgerecord.MaxRecoverySlots {
			return ErrRecoverySplitRequired
		}
		if destination.NextSequence() != 1 {
			return ErrRecoveryPlan
		}
		plan := RecoveryPlan{RecoveryID: destination.RecoveryID(), Source: source.Identity(), NewSpoolID: destination.Identity().SpoolID, ReclaimThrough: base, First: base + 1, Last: high, HighWater: high, DetectedAtUnixNano: detectedAt, Reason: reason}
		next := uint64(1)
		for seq := base + 1; seq <= high; seq++ {
			slot, err := captureRecoverySlot(s, destination.id, seq, next)
			if err != nil {
				return err
			}
			if slot.Copy != nil {
				next++
			}
			plan.Slots = append(plan.Slots, slot)
		}
		// Refuse copy-only, unsupported sizes and malformed detection evidence before
		// holding a healthy source or publishing any recovery journal bytes.
		if _, err := encodeRecoveryJournal(plan); err != nil {
			return err
		}
		if err := s.beginRecoverySourceHold(recoverySourceOwner(plan), grant); err != nil {
			return err
		}
		if err := ensureRecoveryOperationDirectory(dir, grant); err != nil {
			return err
		}
		_, err := FreezeRecovery(dir, grant, plan)
		return err
	})
	if err != nil {
		return nil, err
	}
	return OpenRecoveryOperation(dir, source, destination, grant)
}

func captureRecoverySlot(source *Spool, destination GenerationIdentity, sequence, next uint64) (RecoverySlot, error) {
	slot := RecoverySlot{Sequence: sequence}
	witness, err := source.retainedCopySource(sequence)
	if errors.Is(err, ErrCommittedAttribution) {
		slot.Loss, err = source.RecoveryClassification(sequence)
		return slot, err
	}
	if err != nil {
		return slot, err
	}
	binding, err := edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, bindingCoordinates(destination, next, witness.record.EventID, witness.entry.coordinates.RecordSHA256), witness.Attribution())
	if err != nil {
		return slot, err
	}
	slot.Copy = &RecoveryCopyIntent{NewSequence: next, EventID: witness.record.EventID, RecordSHA256: witness.entry.coordinates.RecordSHA256, SourceBindingSHA256: witness.entry.digest, AttributionBindingSHA256: binding}
	return slot, nil
}

func ensureRecoveryOperationDirectory(dir string, grant *RecoveryGrant) error {
	info, err := os.Lstat(dir)
	if err == nil {
		if !info.IsDir() {
			return ErrRecoveryJournalConflict
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	metadata := uint64(4096)
	for parent := filepath.Dir(dir); ; parent = filepath.Dir(parent) {
		info, err := os.Stat(parent)
		if err == nil {
			if !info.IsDir() {
				return ErrRecoveryJournalConflict
			}
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		metadata += 4096
		if metadata > 64*4096 {
			return ErrRecoverySplitRequired
		}
	}
	if err = grant.Charge(ArtifactFilesystemMetadata, metadata); err != nil {
		return err
	}
	if err = durablefs.MkdirAll(dir, dirPerm); err != nil {
		return grant.FailStop("create recovery operation directory", err)
	}
	return grant.Landed(ArtifactFilesystemMetadata, dir, metadata)
}

func validateRecoveryCoordinator(grant *RecoveryGrant) error {
	footprint := Footprint{DestinationSegment: grant.alloc.budgets[ArtifactDestinationSegment], AttributionSidecar: grant.alloc.budgets[ArtifactAttributionSidecar], JournalCopy: grant.alloc.budgets[ArtifactJournalA], ManifestPages: grant.alloc.budgets[ArtifactManifestPages], Mapping: grant.alloc.budgets[ArtifactMapping], FilesystemMetadata: grant.alloc.budgets[ArtifactFilesystemMetadata]}
	return footprint.ValidateCoordinator()
}
