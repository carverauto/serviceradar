// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"os"

	"google.golang.org/protobuf/proto"
)

const recoveryCoverageMagic = "SRRCOV01"
const recoveryCoverageHeader = 8 + 8*4 + 32

// RecoveryCoverage is a storage-issued interval certificate, never a caller
// assertion. Reclamation reopens its paired record and every prerequisite.
type RecoveryCoverage struct {
	frozen      [32]byte
	first, last uint64
	digest      [32]byte
}

func (c *RecoveryCoverage) Interval() (uint64, uint64) {
	if c == nil {
		return 0, 0
	}
	return c.first, c.last
}

// SealCoverage accounts for every allocated slot using fresh destination commit
// observations or the complete frozen per-sequence loss body and authoritative
// publication receipts. Only both certificate barriers permit the destination
// hold to be removed; source data is not deleted here.
func (o *RecoveryOperation) SealCoverage() (*RecoveryCoverage, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	pending, err := o.pendingPhase("coverage")
	if err != nil {
		return nil, err
	}
	if pending {
		if err = o.requireSourceHold(); err != nil {
			return nil, err
		}
		hold, err := readRecoveryHold(o.destination.spool.recoveryHoldPath())
		if err != nil {
			return nil, err
		}
		if !bytes.Equal(hold, recoveryHoldRecord(o.destination.id, o.frozen)) {
			return nil, ErrRecoveryHeld
		}
		receipts, err := o.publicationReceiptDigest()
		if err != nil {
			return nil, err
		}
		raw := []byte(recoveryCoverageMagic)
		for _, n := range []uint64{o.plan.First, o.plan.Last, o.plan.ReclaimThrough, o.plan.HighWater} {
			raw = binary.BigEndian.AppendUint64(raw, n)
		}
		raw = append(raw, receipts[:]...)
		for _, slot := range o.plan.Slots {
			if slot.Loss != nil {
				if err = o.verifySourceLoss(slot); err != nil {
					return nil, err
				}
				body, err := proto.MarshalOptions{Deterministic: true}.Marshal(slot.Loss)
				if err != nil {
					return nil, err
				}
				digest := sha256.Sum256(body)
				raw = append(raw, 0)
				raw = binary.BigEndian.AppendUint64(raw, slot.Sequence)
				raw = append(raw, digest[:]...)
			} else {
				proof, err := o.destination.CommittedAttribution(slot.Copy.NewSequence)
				if err != nil {
					return nil, err
				}
				if err = o.checkCopy(slot, proof); err != nil {
					return nil, err
				}
				raw = append(raw, 1)
				raw = binary.BigEndian.AppendUint64(raw, slot.Sequence)
				raw = appendRecoveryCopyCertificate(raw, slot.Copy, proof.mappingDigest, proof.highWater)
			}
		}
		if err = writeRecoveryPhase(o.dir, "coverage", o.frozen, raw, o.grant); err != nil {
			return nil, err
		}
	}
	certificate, err := o.readCoverage()
	if err != nil {
		return nil, err
	}
	err = o.destination.withOpen(func(s *Spool) error { return s.releaseRecoveryHold(o.frozen, o.grant) })
	if err != nil {
		return nil, err
	}
	return certificate, nil
}

func (o *RecoveryOperation) verifySourceLoss(slot RecoverySlot) error {
	observed, err := o.source.spool.observeAttribution(slot.Sequence)
	if err != nil {
		return err
	}
	if observed.highWater != o.plan.HighWater {
		return ErrRecoveryCoverage
	}
	resolution := ResolveSlot(observed.observation)
	if !resolution.EntersCoverage() {
		return ErrRecoveryCoverage
	}
	span := resolution.Coverage
	if span.Attributed {
		if !proto.Equal(attributionSpan(slot.Sequence, observed.entry.attribution), slot.Loss) {
			return ErrRecoveryCoverage
		}
	} else {
		body := slot.Loss.GetUnattributable()
		if body == nil || body.Reason != span.Reason {
			return ErrRecoveryCoverage
		}
	}
	return nil
}

func appendRecoveryCopyCertificate(raw []byte, c *RecoveryCopyIntent, mapping []byte, high uint64) []byte {
	raw = binary.BigEndian.AppendUint64(raw, c.NewSequence)
	raw = append(raw, c.EventID...)
	raw = append(raw, c.RecordSHA256...)
	raw = append(raw, c.SourceBindingSHA256...)
	raw = append(raw, c.AttributionBindingSHA256...)
	raw = append(raw, mapping...)
	return binary.BigEndian.AppendUint64(raw, high)
}

func (o *RecoveryOperation) publicationReceiptDigest() ([32]byte, error) {
	var out [32]byte
	h := sha256.New()
	_, _ = h.Write([]byte("serviceradar.recovery.publication_receipts.v1"))
	for i := 0; i <= len(o.manifest.Pages); i++ {
		raw, err := o.readPublicationReceipt(i)
		if err != nil {
			return out, err
		}
		digest := sha256.Sum256(raw)
		_, _ = h.Write(digest[:])
	}
	copy(out[:], h.Sum(nil))
	return out, nil
}

func (o *RecoveryOperation) readCoverage() (*RecoveryCoverage, error) {
	raw, err := readRecoveryPhase(o.dir, "coverage", o.frozen)
	if err != nil {
		return nil, err
	}
	if len(raw) < recoveryCoverageHeader || string(raw[:8]) != recoveryCoverageMagic {
		return nil, ErrRecoveryCoverage
	}
	for i, n := range []uint64{o.plan.First, o.plan.Last, o.plan.ReclaimThrough, o.plan.HighWater} {
		if binary.BigEndian.Uint64(raw[8+8*i:]) != n {
			return nil, ErrRecoveryCoverage
		}
	}
	receipts, err := o.publicationReceiptDigest()
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(raw[40:72], receipts[:]) {
		return nil, ErrRecoveryCoverage
	}
	remaining := raw[recoveryCoverageHeader:]
	for _, slot := range o.plan.Slots {
		if len(remaining) < 9 || binary.BigEndian.Uint64(remaining[1:9]) != slot.Sequence {
			return nil, ErrRecoveryCoverage
		}
		kind := remaining[0]
		remaining = remaining[9:]
		if slot.Loss != nil {
			if kind != 0 || len(remaining) < 32 {
				return nil, ErrRecoveryCoverage
			}
			body, err := proto.MarshalOptions{Deterministic: true}.Marshal(slot.Loss)
			if err != nil {
				return nil, err
			}
			digest := sha256.Sum256(body)
			if !bytes.Equal(remaining[:32], digest[:]) {
				return nil, ErrRecoveryCoverage
			}
			remaining = remaining[32:]
		} else {
			const copyBytes = 8 + 16 + 4*32 + 8
			if kind != 1 || len(remaining) < copyBytes {
				return nil, ErrRecoveryCoverage
			}
			mapping := remaining[copyBytes-40 : copyBytes-8]
			high := binary.BigEndian.Uint64(remaining[copyBytes-8 : copyBytes])
			expected := appendRecoveryCopyCertificate(nil, slot.Copy, mapping, high)
			if high < slot.Copy.NewSequence || !bytes.Equal(expected, remaining[:copyBytes]) {
				return nil, ErrRecoveryCoverage
			}
			remaining = remaining[copyBytes:]
		}
	}
	if len(remaining) != 0 {
		return nil, ErrRecoveryCoverage
	}
	return &RecoveryCoverage{frozen: o.frozen, first: o.plan.First, last: o.plan.Last, digest: sha256.Sum256(raw)}, nil
}

// resumeDestinationHold never recreates a hold after a paired certificate was
// released. It verifies every prerequisite before retrying interrupted release.
func (o *RecoveryOperation) resumeDestinationHold() error {
	pending, err := o.pendingPhase("coverage")
	if err != nil {
		return err
	}
	if pending {
		return o.destination.withOpen(func(s *Spool) error { return s.beginRecoveryHold(o.frozen, o.grant, true) })
	}
	if _, err = o.readCoverage(); err != nil {
		return err
	}
	return o.destination.withOpen(func(s *Spool) error { return s.releaseRecoveryHold(o.frozen, o.grant) })
}

func (o *RecoveryOperation) requireSourceHold() error {
	raw, err := readRecoveryHold(o.source.spool.recoverySourceHoldPath())
	if errors.Is(err, os.ErrNotExist) {
		return ErrRecoveryHeld
	}
	if err != nil {
		return err
	}
	if !bytes.Equal(raw, recoveryHoldRecord(o.source.id, o.sourceHold)) {
		return ErrRecoveryHeld
	}
	return nil
}
