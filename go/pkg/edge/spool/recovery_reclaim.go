// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

type recoveryDeleteIntent struct {
	ReclaimThrough, HighWater, NextGeneration uint64
	CoverageSHA256, ArchiveSHA256             []byte
}

// ReclaimSource is the only recovery deletion owner. It takes no caller-supplied
// coverage claim or byte count, and refuses partial operations over a physical
// source. Unsupported larger sources remain retained for intervention.
func (o *RecoveryOperation) ReclaimSource() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.plan.First != o.plan.ReclaimThrough+1 || o.plan.Last != o.plan.HighWater {
		return ErrRecoverySplitRequired
	}
	coverage, err := o.readCoverage()
	if err != nil {
		return err
	}
	archive, err := o.readArchive()
	if err != nil {
		return err
	}
	pending, err := o.pendingPhase("delete")
	if err != nil {
		return err
	}
	if pending {
		if err = o.requireSourceHold(); err != nil {
			return err
		}
		intent := recoveryDeleteIntent{o.plan.ReclaimThrough, o.plan.HighWater, o.source.spool.nextGen, coverage.digest[:], archive.SHA256}
		payload, err := json.Marshal(intent)
		if err != nil {
			return err
		}
		if err = writeRecoveryPhase(o.dir, "delete", o.frozen, payload, o.grant); err != nil {
			return err
		}
	}
	intent, raw, err := o.readDeleteIntent()
	if err != nil {
		return err
	}
	err = o.source.withOpen(func(s *Spool) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.baseSeq == o.plan.HighWater {
			if err := o.verifyReclaimedCheckpoint(intent, raw); err != nil {
				return err
			}
			return o.grant.RunDestructive("finish covered source cleanup", s.cleanupReclaimed)
		}
		if s.baseSeq != o.plan.ReclaimThrough || s.nextSeq-1 != o.plan.HighWater {
			return ErrRecoveryCoverage
		}
		if err := o.requireSourceHold(); err != nil {
			return err
		}
		// The local watermark is a storage checkpoint after complete physical
		// coverage, never an invented wire disposition or consumer applied prefix.
		const metadata = 2*4096 + checkpointSize + 8
		if err := o.grant.Charge(ArtifactFilesystemMetadata, metadata); err != nil {
			return err
		}
		if err := s.writeResolved(o.plan.HighWater); err != nil {
			return o.grant.FailStop("checkpoint covered source watermark", err)
		}
		s.resolved = o.plan.HighWater
		checkpoint := recoveryCheckpoint(intent, raw)
		if err := o.grant.WriteBarrier(ArtifactFilesystemMetadata, filepath.Join(s.dir, dataName(o.plan.HighWater)+checkpointSuffix), checkpoint); err != nil {
			return err
		}
		if err := o.grant.RunDestructive("publish covered source layout", func() error { return s.publishReclaimed(dataName(o.plan.HighWater)) }); err != nil {
			return err
		}
		return o.grant.Landed(ArtifactFilesystemMetadata, s.dir, metadata)
	})
	if err != nil {
		return err
	}
	if err = writeRecoveryPhase(o.dir, "reclaimed", o.frozen, raw, o.grant); err != nil {
		return err
	}
	after, err := o.source.spool.laneBytes()
	if err != nil {
		return err
	}
	if err = o.grant.checkpointSourceReleased(o.source.dir, after); err != nil {
		return err
	}
	return o.source.withOpen(func(s *Spool) error { return s.releaseRecoverySourceHold(o.sourceHold, o.grant) })
}

func (o *RecoveryOperation) readDeleteIntent() (recoveryDeleteIntent, []byte, error) {
	var intent recoveryDeleteIntent
	raw, err := readRecoveryPhase(o.dir, "delete", o.frozen)
	if err != nil {
		return intent, nil, err
	}
	if err = decodeRecoveryJSON(raw, &intent); err != nil {
		return intent, nil, err
	}
	coverage, err := o.readCoverage()
	if err != nil {
		return intent, nil, err
	}
	archive, err := o.readArchive()
	if err != nil {
		return intent, nil, err
	}
	if o.plan.First != o.plan.ReclaimThrough+1 || o.plan.Last != o.plan.HighWater || intent.ReclaimThrough != o.plan.ReclaimThrough || intent.HighWater != o.plan.HighWater || intent.NextGeneration == 0 || !bytes.Equal(intent.CoverageSHA256, coverage.digest[:]) || !bytes.Equal(intent.ArchiveSHA256, archive.SHA256) {
		return intent, nil, ErrRecoveryCoverage
	}
	return intent, raw, nil
}

func recoveryCheckpoint(intent recoveryDeleteIntent, raw []byte) []byte {
	checkpoint := make([]byte, checkpointSize)
	copy(checkpoint, "SRRECL01")
	binary.LittleEndian.PutUint64(checkpoint[8:], intent.HighWater)
	binary.LittleEndian.PutUint64(checkpoint[16:], intent.NextGeneration)
	proof := sha256.Sum256(append([]byte("serviceradar.recovery.delete.v1"), raw...))
	copy(checkpoint[24:], proof[:])
	sum := sha256.Sum256(checkpoint[:56])
	copy(checkpoint[56:], sum[:])
	return checkpoint
}

func (o *RecoveryOperation) verifyReclaimedCheckpoint(intent recoveryDeleteIntent, raw []byte) error {
	checkpoint, err := os.ReadFile(filepath.Join(o.source.dir, dataName(intent.HighWater)+checkpointSuffix))
	if err != nil {
		return err
	}
	if !bytes.Equal(checkpoint, recoveryCheckpoint(intent, raw)) {
		return ErrRecoveryCoverage
	}
	return nil
}

// checkpointSourceReleased transfers only after the proof owner has reopened the
// reclaimed physical layout. Phase/completion writes remain possible; ordinary
// public Finish/ReleaseSource retains its existing sealed-grant contract.
func (g *RecoveryGrant) checkpointSourceReleased(source string, retained uint64) error {
	g.step.Lock()
	defer g.step.Unlock()
	a := g.alloc
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := g.healthyLocked(); err != nil {
		return err
	}
	if g.sourceReleased {
		return nil
	}
	if g.finished {
		return ErrRecoveryFinished
	}
	source = filepath.Clean(source)
	if retained > a.ordinary[source] {
		return ErrReleaseExceedsCharge
	}
	a.ordinary[source] = retained
	a.addOrdinaryLocked(g.lane, g.laneHeldLocked())
	g.sourceReleased = true
	g.releaseStageLocked()
	return nil
}

type recoveryResolutionRecord struct{ Resolved, Capability []byte }

// RecordResolution durably saves the original verified consumer receipt. The
// grant remains active until the same owner has drained destinations and safely
// collected transient proofs; a second acquisition at the full floor can fail.
func (o *RecoveryOperation) RecordResolution(validated *edgerecord.ValidatedRecoveryResolution) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	resolved, capability, err := validated.Snapshot()
	if err != nil {
		return err
	}
	tombstone := new(edgev1.SpoolLossTombstoneV1)
	if err = proto.Unmarshal(o.manifest.Tombstone, tombstone); err != nil {
		return err
	}
	claims := capability.GetSource()
	if !bytes.Equal(claims.GetNetworkScopeId(), o.plan.Source.Identity.NetworkScopeID) || !bytes.Equal(claims.GetOriginPrincipalId(), o.plan.Source.Identity.AgentID) || !bytes.Equal(resolved.RecoveryId, o.plan.RecoveryID) || !bytes.Equal(resolved.ManifestRootSha256, tombstone.ManifestRootSha256) || resolved.AppliedThroughSequence < o.plan.Last {
		return edgerecord.ErrRecoveryResolution
	}
	intent, deleteRaw, err := o.readDeleteIntent()
	if err != nil {
		return err
	}
	reclaimed, err := readRecoveryPhase(o.dir, "reclaimed", o.frozen)
	if err != nil {
		return err
	}
	if !bytes.Equal(reclaimed, deleteRaw) {
		return ErrRecoveryCoverage
	}
	if err = o.verifyReclaimedCheckpoint(intent, deleteRaw); err != nil {
		return err
	}
	body, err := proto.MarshalOptions{Deterministic: true}.Marshal(resolved)
	if err != nil {
		return err
	}
	signed, err := proto.MarshalOptions{Deterministic: true}.Marshal(capability)
	if err != nil {
		return err
	}
	payload, err := json.Marshal(recoveryResolutionRecord{body, signed})
	if err != nil {
		return err
	}
	pending, err := o.pendingPhase("resolved")
	if err != nil {
		return err
	}
	if pending {
		if err = writeRecoveryPhase(o.dir, "resolved", o.frozen, payload, o.grant); err != nil {
			return err
		}
	} else {
		stored, err := readRecoveryPhase(o.dir, "resolved", o.frozen)
		if err != nil {
			return err
		}
		if !bytes.Equal(stored, payload) {
			return ErrRecoveryJournalConflict
		}
	}
	return nil
}

// resumeSource distinguishes retained original bytes from an already published
// reclaim pointer. A pointer alone cannot authorize retry cleanup or release.
func (o *RecoveryOperation) resumeSource() error {
	return o.source.withOpen(func(s *Spool) error {
		s.mu.Lock()
		original := s.baseSeq == o.plan.ReclaimThrough && s.nextSeq-1 == o.plan.HighWater
		reclaimed := s.baseSeq == o.plan.HighWater && s.nextSeq-1 == o.plan.HighWater
		s.mu.Unlock()
		if original {
			return s.beginRecoverySourceHold(o.sourceHold, o.grant)
		}
		if !reclaimed {
			return ErrRecoveryPlan
		}
		intent, raw, err := o.readDeleteIntent()
		if err != nil {
			return err
		}
		return o.verifyReclaimedCheckpoint(intent, raw)
	})
}

// ReadSignedResolution is retained for completion inventory without treating a
// durable old validation as current trust policy. Callers must revalidate its
// exact originals through edgerecord.ValidateRecoveryResolution before RecordResolution.
func (o *RecoveryOperation) ReadSignedResolution() (*edgev1.RecoveryResolvedV1, *edgev1.EdgeSignedCapabilityV1, error) {
	raw, err := readRecoveryPhase(o.dir, "resolved", o.frozen)
	if err != nil {
		return nil, nil, err
	}
	var record recoveryResolutionRecord
	if err = decodeRecoveryJSON(raw, &record); err != nil {
		return nil, nil, err
	}
	body := new(edgev1.RecoveryResolvedV1)
	capability := new(edgev1.EdgeSignedCapabilityV1)
	if err = proto.Unmarshal(record.Resolved, body); err != nil {
		return nil, nil, err
	}
	if err = proto.Unmarshal(record.Capability, capability); err != nil {
		return nil, nil, err
	}
	return body, capability, nil
}
