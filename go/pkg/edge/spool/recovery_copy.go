// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// resumeCopy verifies a retained committed mapping or repairs only the final
// allocation. No earlier gap may be rewritten beneath later allocated slots.
func (o *RecoveryOperation) resumeCopy(slot RecoverySlot) (Receipt, error) {
	if o.destination.NextSequence() == slot.Copy.NewSequence+1 {
		if err := o.resumeCopyTail(slot); err != nil {
			return Receipt{}, err
		}
	}
	proof, err := o.destination.CommittedAttribution(slot.Copy.NewSequence)
	if err != nil {
		return Receipt{}, err
	}
	if err = o.checkCopy(slot, proof); err != nil {
		return Receipt{}, err
	}
	return Receipt{Generation: o.destination.Identity(), Sequence: slot.Copy.NewSequence}, nil
}

// resumeCopyTail repairs only the frozen final allocation of a fresh dedicated
// destination. Earlier records are immutable and both holds remain mandatory.
// Counters/offsets follow that destination's sequential append grammar; a valid
// conflicting entry or even a conflicting partial prefix is retained untouched.
func (o *RecoveryOperation) resumeCopyTail(slot RecoverySlot) error {
	if err := o.requireSourceHold(); err != nil {
		return err
	}
	source, err := o.source.spool.retainedCopySource(slot.Sequence)
	if err != nil {
		return err
	}
	if !bytes.Equal(source.entry.digest, slot.Copy.SourceBindingSHA256) || !bytes.Equal(source.record.EventID, slot.Copy.EventID) || !bytes.Equal(source.entry.coordinates.RecordSHA256, slot.Copy.RecordSHA256) {
		return ErrRecoveryPlan
	}
	var previous CommittedAttribution
	if slot.Copy.NewSequence > 1 {
		previous, err = o.destination.CommittedAttribution(slot.Copy.NewSequence - 1)
		if err != nil {
			return err
		}
	}
	g := o.destination
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	if g.shut || g.Closed() {
		return ErrLaneSetClosed
	}
	identity, err := readGenerationIdentity(g.dir)
	if err != nil {
		return err
	}
	if !bytes.Equal(encodeIdentity(identity), encodeIdentity(g.id)) {
		return ErrRecoveryPlan
	}
	recoveryID, attempt, err := readRecoveryDestination(g.dir, g.id)
	if err != nil {
		return err
	}
	if !bytes.Equal(recoveryID, o.plan.RecoveryID) || attempt != 0 {
		return ErrRecoveryPlan
	}
	hold, err := readRecoveryHold(g.spool.recoveryHoldPath())
	if err != nil {
		return err
	}
	if !bytes.Equal(hold, recoveryHoldRecord(g.id, o.frozen)) {
		return ErrRecoveryHeld
	}
	return g.spool.repairCopyTail(slot.Copy, &source, previous, o.grant)
}

type recoveryTailFile struct {
	path     string
	start    int64
	raw      []byte
	artifact Artifact
}

func (s *Spool) repairCopyTail(intent *RecoveryCopyIntent, source *committedAttributionData, previous CommittedAttribution, grant *RecoveryGrant) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	sequence := intent.NewSequence
	if s.failErr != nil {
		return s.failErr
	}
	if s.seg == nil || s.baseSeq != 0 || s.nextSeq != sequence+1 || sequence == 0 || sequence > edgerecord.MaxRecoverySlots || s.resolved != 0 {
		return ErrRecoveryCoverage
	}
	if err := s.requireCurrentLayout(); err != nil {
		return err
	}
	offset, err := s.recoveryPreviousEnd(sequence, previous)
	if err != nil {
		return err
	}
	pending := &pendingAttribution{source: source, grant: grant}
	if err = s.prepareAttribution(sequence, source.record.EventID, source.record.Body, pending); err != nil {
		return err
	}
	if !bytes.Equal(pending.entry.digest, intent.AttributionBindingSHA256) {
		return ErrRecoveryPlan
	}
	record := encodeRecord(sequence, source.record.EventID, source.record.Body)
	entry := evidenceEntry{version: evidenceVersion2, state: statePrepared, flags: flagAttributionBinding | flagRelocationBinding, sequence: sequence, generation: 2*sequence - 1, recordOffset: uint64(offset), recordLen: uint32(len(record)), recordSHA256: sha256.Sum256(source.record.Body)}
	copy(entry.eventID[:], source.record.EventID)
	copy(entry.attributionSHA256[:], pending.entry.digest)
	copy(entry.relocationSHA256[:], pending.relocationDigest)
	files := []recoveryTailFile{
		{s.segmentPath(), offset, record, ArtifactDestinationSegment},
		{filepath.Join(s.dataDir, attributionFile), int64(sequence-1) * sidecarSlotSize, pending.raw, ArtifactAttributionSidecar},
		{filepath.Join(s.dataDir, relocationFile), int64(sequence-1) * sidecarSlotSize, pending.relocationRaw, ArtifactAttributionSidecar},
	}
	for c := range evidenceCopies {
		entry.copyTag = copyTag(c)
		entry.state = statePrepared
		entry.generation = 2*sequence - 1
		raw := entry.encode()
		entry.state = stateCommitted
		entry.generation = 2 * sequence
		raw = append(raw, entry.encode()...)
		files = append(files, recoveryTailFile{s.evidencePath(c), s.evidencePosition(sequence, statePrepared), raw, ArtifactDestinationSegment})
	}
	costs := make([]recoveryAppendCost, 0, len(files))
	for _, file := range files {
		present, err := file.verify()
		if err != nil {
			return err
		}
		missing := uint64(len(file.raw) - present)
		costs = append(costs, recoveryAppendCost{file.artifact, file.path, missing, missing})
	}
	// ResumeRecovery has already restored the unresolved slot's terminal allowance.
	// Recharging it here would reserve the same durable allocation twice.
	charged, err := grant.chargeAppend(s, costs, 0)
	if err != nil {
		return err
	}
	err = s.writeCopyTail(files, grant)
	if err == nil {
		s.segBounds = segmentBounds{limits: s.segBounds.limits}
		err = s.open() // rebuild the bounded generation's former ambiguous-tail state
	}
	if err != nil {
		s.failErr = asFailStop(charged.fail("resume exact recovery copy", err))
		return s.failErr
	}
	return charged.land()
}

func (s *Spool) recoveryPreviousEnd(sequence uint64, previous CommittedAttribution) (int64, error) {
	if sequence == 1 {
		return 0, nil
	}
	if !previous.valid || previous.record.Sequence != sequence-1 {
		return 0, ErrCommittedAttribution
	}
	var agreed evidenceEntry
	for c := range evidenceCopies {
		f, err := os.Open(s.evidencePath(c))
		if err != nil {
			return 0, err
		}
		raw := make([]byte, evidenceEntryLen2)
		_, err = f.ReadAt(raw, s.evidencePosition(sequence-1, stateCommitted))
		closeErr := f.Close()
		if err != nil {
			return 0, err
		}
		if closeErr != nil {
			return 0, closeErr
		}
		entry, status := decodeEvidenceVersion(raw, c, sequence-1, stateCommitted, evidenceVersion2)
		if status != entryValid || entry.generation != 2*(sequence-1) || entry.recordLen != uint32(len(encodeRecord(sequence-1, previous.record.EventID, previous.record.Body))) || !bytes.Equal(entry.recordSHA256[:], previous.entry.coordinates.RecordSHA256) || !bytes.Equal(entry.attributionSHA256[:], previous.entry.digest) {
			return 0, ErrRecoveryCoverage
		}
		entry.copyTag = 0
		if c == 0 {
			agreed = entry
		} else if entry != agreed {
			return 0, ErrRecoveryJournalConflict
		}
	}
	return int64(agreed.recordOffset) + int64(agreed.recordLen), nil
}

// verify permits only a byte-identical prefix at the exact append offset. A hole,
// trailing allocation, substituted file, or mismatching byte is never overwritten.
func (f recoveryTailFile) verify() (int, error) {
	info, err := os.Lstat(f.path)
	if errors.Is(err, os.ErrNotExist) {
		if f.start != 0 {
			return 0, ErrRecoveryJournalConflict
		}
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !info.Mode().IsRegular() || info.Size() < f.start || info.Size() > f.start+int64(len(f.raw)) {
		return 0, ErrRecoveryJournalConflict
	}
	present := int(info.Size() - f.start)
	file, err := os.Open(f.path)
	if err != nil {
		return 0, err
	}
	raw := make([]byte, present)
	_, err = io.ReadFull(io.NewSectionReader(file, f.start, int64(present)), raw)
	closeErr := file.Close()
	if err != nil {
		return 0, err
	}
	if closeErr != nil {
		return 0, closeErr
	}
	if !bytes.Equal(raw, f.raw[:present]) {
		return 0, ErrRecoveryJournalConflict
	}
	return present, nil
}

func (f recoveryTailFile) appendThrough(through int, grant *RecoveryGrant) error {
	present, err := f.verify()
	if err != nil {
		return err
	}
	file, err := grant.alloc.fs.OpenFile(f.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, filePerm)
	if err != nil {
		return err
	}
	if present < through {
		var written int
		written, err = file.Write(f.raw[present:through])
		if err == nil && written != through-present {
			err = io.ErrShortWrite
		}
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func (s *Spool) writeCopyTail(files []recoveryTailFile, grant *RecoveryGrant) error {
	if err := s.ensureEvidence(); err != nil {
		return err
	}
	for c := range evidenceCopies {
		if err := s.cross(prepareBarrier(c)); err != nil {
			return err
		}
		if err := files[3+c].appendThrough(evidenceEntryLen2, grant); err != nil {
			return err
		}
	}
	stages := []struct {
		index              int
		content, directory barrier
	}{{0, barrierRecord, barrierRecord}, {1, barrierAttribution, barrierAttributionDir}, {2, barrierRelocation, barrierRelocationDir}}
	for _, stage := range stages {
		if err := s.cross(stage.content); err != nil {
			return err
		}
		if err := files[stage.index].appendThrough(len(files[stage.index].raw), grant); err != nil {
			return err
		}
		if stage.index > 0 {
			if err := s.cross(stage.directory); err != nil {
				return err
			}
			if err := grant.alloc.fs.SyncDir(s.dataDir); err != nil {
				return err
			}
		}
	}
	for c := range evidenceCopies {
		if err := s.cross(commitBarrier(c)); err != nil {
			return err
		}
		if err := files[3+c].appendThrough(2*evidenceEntryLen2, grant); err != nil {
			return err
		}
	}
	return nil
}
