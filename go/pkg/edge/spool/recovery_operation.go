// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

var ErrRecoveryCoverage = errors.New("recovery: allocated coverage is incomplete")

// RecoveryOperation owns the storage proof boundary for one frozen interval.
// It cannot sign authority or infer a JetStream acknowledgement. The coordinator
// supplies typed producer authority and authenticated sender acknowledgements.
type RecoveryOperation struct {
	mu                  sync.Mutex
	dir                 string
	source, destination *Generation
	grant               *RecoveryGrant
	frozen              [32]byte
	sourceHold          [32]byte
	plan                RecoveryPlan
	manifest            RecoveryManifest
}

// OpenRecoveryOperation binds a paired freeze to actual generation ownership and
// durably holds the source and empty copy destination against early resolution.
// Reopening an existing hold is idempotent; a conflicting owner remains blocked.
func OpenRecoveryOperation(dir string, source, destination *Generation, grant *RecoveryGrant) (*RecoveryOperation, error) {
	if source == nil || destination == nil || grant == nil {
		return nil, ErrRecoveryGrantRequired
	}
	if err := usableRecoveryGrant(grant); err != nil {
		return nil, err
	}
	footprint := Footprint{DestinationSegment: grant.alloc.budgets[ArtifactDestinationSegment], AttributionSidecar: grant.alloc.budgets[ArtifactAttributionSidecar], JournalCopy: grant.alloc.budgets[ArtifactJournalA], ManifestPages: grant.alloc.budgets[ArtifactManifestPages], Mapping: grant.alloc.budgets[ArtifactMapping], FilesystemMetadata: grant.alloc.budgets[ArtifactFilesystemMetadata]}
	if err := footprint.ValidateCoordinator(); err != nil {
		return nil, err
	}
	journal, err := OpenRecoveryJournal(dir)
	if err != nil {
		return nil, err
	}
	plan, err := journal.FrozenPlan()
	if err != nil {
		return nil, err
	}
	if !source.Closed() || source.spool.alloc != grant.alloc || destination.spool.alloc != grant.alloc || destination.dir != grant.lane ||
		!bytes.Equal(encodeIdentity(source.id), encodeIdentity(plan.Source)) || !bytes.Equal(destination.id.SpoolID, plan.NewSpoolID) ||
		destination.id.Lane != plan.Source.Lane || !destination.id.Identity.equal(plan.Source.Identity) || !bytes.Equal(destination.RecoveryID(), plan.RecoveryID) {
		return nil, ErrRecoveryPlan
	}
	boundSource, err := destination.RecoverySourceIdentity()
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(encodeIdentity(boundSource), encodeIdentity(plan.Source)) {
		return nil, ErrRecoveryPlan
	}
	manifest, err := journal.BuildManifest()
	if err != nil {
		return nil, err
	}
	op := &RecoveryOperation{dir: dir, source: source, destination: destination, grant: grant, frozen: sha256.Sum256(journal.raw), plan: plan, manifest: manifest}
	hold := append([]byte("serviceradar.recovery.source_hold.v1"), encodeIdentity(plan.Source)...)
	hold = binary.BigEndian.AppendUint64(hold, plan.ReclaimThrough)
	hold = binary.BigEndian.AppendUint64(hold, plan.HighWater)
	op.sourceHold = sha256.Sum256(hold)
	err = source.withOpen(func(s *Spool) error {
		s.mu.Lock()
		bounds := s.baseSeq == plan.ReclaimThrough && s.nextSeq-1 == plan.HighWater
		s.mu.Unlock()
		if !bounds {
			return ErrRecoveryPlan
		}
		return s.beginRecoverySourceHold(op.sourceHold, grant)
	})
	if err != nil {
		return nil, err
	}
	if err = op.resumeDestinationHold(); err != nil {
		return nil, err
	}
	return op, nil
}

// Copy commits the frozen copy intent, or verifies its already committed exact
// destination on restart. The destination hold exists before this call.
func (o *RecoveryOperation) Copy(sequence uint64) (Receipt, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if sequence < o.plan.First || sequence > o.plan.Last {
		return Receipt{}, ErrRecoveryPlan
	}
	slot := o.plan.Slots[sequence-o.plan.First]
	if slot.Copy == nil {
		return Receipt{}, ErrRecoveryPlan
	}
	if o.destination.NextSequence() > slot.Copy.NewSequence {
		return o.resumeCopy(slot)
	}
	if o.destination.NextSequence() != slot.Copy.NewSequence {
		return Receipt{}, ErrRecoveryCoverage
	}
	source, err := o.source.spool.retainedCopySource(sequence)
	if err != nil {
		return Receipt{}, err
	}
	if !bytes.Equal(source.entry.digest, slot.Copy.SourceBindingSHA256) || !bytes.Equal(source.record.EventID, slot.Copy.EventID) || !bytes.Equal(source.entry.coordinates.RecordSHA256, slot.Copy.RecordSHA256) {
		return Receipt{}, ErrRecoveryPlan
	}
	receipt, err := o.commitRetained(source)
	if err != nil {
		return Receipt{}, err
	}
	proof, err := o.destination.CommittedAttribution(receipt.Sequence)
	if err != nil {
		return Receipt{}, err
	}
	return receipt, o.checkCopy(slot, proof)
}

func (o *RecoveryOperation) checkCopy(slot RecoverySlot, proof CommittedAttribution) error {
	c := slot.Copy
	if c == nil || !proof.valid || proof.mapping == nil || !bytes.Equal(proof.generation.SpoolID, o.plan.NewSpoolID) || proof.record.Sequence != c.NewSequence || proof.highWater < c.NewSequence {
		return ErrRecoveryCoverage
	}
	m := proof.mapping
	if !bytes.Equal(encodeIdentity(m.source), encodeIdentity(o.plan.Source)) || m.sourceSequence != slot.Sequence || m.destinationSequence != c.NewSequence ||
		!bytes.Equal(proof.record.EventID, c.EventID) || !bytes.Equal(proof.entry.coordinates.RecordSHA256, c.RecordSHA256) ||
		!bytes.Equal(m.sourceBinding, c.SourceBindingSHA256) || !bytes.Equal(proof.entry.digest, c.AttributionBindingSHA256) || len(proof.mappingDigest) != sha256.Size {
		return ErrRecoveryCoverage
	}
	return nil
}

type frozenRecoveryPublication struct{ EventID, Body, Attribution []byte }

// FreezePublications saves one authority attempt before enqueue. A later attempt
// may have new event IDs and capabilities, but every semantic page and tombstone
// must still match the original registered manifest. Existing attempts never change.
func (o *RecoveryOperation) FreezePublications(attempt uint32, records []AttributedAppend) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if attempt >= MaxRecoveryControlAttempts {
		return ErrRecoverySplitRequired
	}
	if len(records) != len(o.manifest.Pages)+1 {
		return ErrRecoveryPlan
	}
	publications := make([]frozenRecoveryPublication, len(records))
	seen := map[string]bool{}
	total := 0
	for i, a := range records {
		total += len(a.Body)
		if total > MaxRecoveryPublicationBytes || seen[string(a.EventID)] {
			return ErrRecoverySplitRequired
		}
		seen[string(a.EventID)] = true
		record, err := edgerecord.DecodeRecord(a.Body)
		if err != nil {
			return err
		}
		if err = o.checkPublicationBody(i, record); err != nil {
			return err
		}
		hash := sha256.Sum256(a.Body)
		coordinates := bindingCoordinates(GenerationIdentity{Identity: o.plan.Source.Identity, Lane: LaneKey{RouteProfile: record.RouteProfile, TrafficClass: record.TrafficClass}, SpoolID: o.plan.RecoveryID}, uint64(i+1), a.EventID, hash[:])
		attribution := a.Validated.Attribution()
		if _, err = a.Validated.Bind(coordinates, attribution); err != nil {
			return err
		}
		span, err := proto.MarshalOptions{Deterministic: true}.Marshal(attributionSpan(uint64(i+1), attribution))
		if err != nil {
			return err
		}
		if len(span) > maxFrozenRecoveryAttributionBytes {
			return ErrRecoverySplitRequired
		}
		publications[i] = frozenRecoveryPublication{EventID: bytes.Clone(a.EventID), Body: bytes.Clone(a.Body), Attribution: span}
	}
	payload, err := json.Marshal(publications)
	if err != nil {
		return err
	}
	return writeRecoveryPhase(o.dir, recoveryPublicationsKey(attempt), o.frozen, payload, o.grant)
}

func (o *RecoveryOperation) checkPublicationBody(index int, r *edgev1.EdgeRecordV1) error {
	// Coordinator output uses NONE: exact frozen bytes are never recompressed or
	// re-marshalled during replay, even if another producer supports compression.
	if r.GetRouteProfile() != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 || r.GetCompression() != edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE {
		return ErrRecoveryPlan
	}
	wrapper := &edgev1.EdgeRecoveryControlPayloadV1{}
	if index < len(o.manifest.Pages) {
		page := new(edgev1.EdgeLossManifestPageV1)
		if err := proto.Unmarshal(o.manifest.Pages[index], page); err != nil {
			return err
		}
		wrapper.Body = &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page}
	} else if index == len(o.manifest.Pages) {
		tomb := new(edgev1.SpoolLossTombstoneV1)
		if err := proto.Unmarshal(o.manifest.Tombstone, tomb); err != nil {
			return err
		}
		wrapper.Body = &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb}
	} else {
		return ErrRecoveryPlan
	}
	expected, err := proto.MarshalOptions{Deterministic: true}.Marshal(wrapper)
	if err != nil {
		return err
	}
	if !bytes.Equal(r.Payload, expected) {
		return ErrRecoveryPlan
	}
	return nil
}

func recoveryPublicationsKey(attempt uint32) string { return fmt.Sprintf("publications-%03d", attempt) }

// ReplayPublications freezes another transport attempt with the exact original
// signed bytes after an interrupted control append. It cannot mint new authority.
func (o *RecoveryOperation) ReplayPublications(from, to uint32) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if to >= MaxRecoveryControlAttempts || from >= to {
		return ErrRecoverySplitRequired
	}
	raw, _, err := o.publicationBundle(from)
	if err != nil {
		return err
	}
	return writeRecoveryPhase(o.dir, recoveryPublicationsKey(to), o.frozen, raw, o.grant)
}

func (o *RecoveryOperation) publicationBundle(attempt uint32) ([]byte, []frozenRecoveryPublication, error) {
	if attempt >= MaxRecoveryControlAttempts {
		return nil, nil, ErrRecoverySplitRequired
	}
	raw, err := readRecoveryPhase(o.dir, recoveryPublicationsKey(attempt), o.frozen)
	if err != nil {
		return nil, nil, err
	}
	var records []frozenRecoveryPublication
	if err = decodeRecoveryJSON(raw, &records); err != nil {
		return nil, nil, err
	}
	if len(records) != len(o.manifest.Pages)+1 {
		return nil, nil, ErrRecoveryJournalCorrupt
	}
	total := 0
	for i, record := range records {
		total += len(record.Body)
		if total > MaxRecoveryPublicationBytes || len(record.Attribution) > maxFrozenRecoveryAttributionBytes {
			return nil, nil, ErrRecoveryJournalCorrupt
		}
		if err := o.validateFrozenPublication(i, record); err != nil {
			return nil, nil, err
		}
	}
	return raw, records, nil
}

// pendingPhase distinguishes a wholly absent future step from a torn pair.
func (o *RecoveryOperation) pendingPhase(key string) (bool, error) {
	a := readRecoveryPhaseCopy(recoveryPhasePath(o.dir, key, 0), o.frozen, key)
	b := readRecoveryPhaseCopy(recoveryPhasePath(o.dir, key, 1), o.frozen, key)
	if errors.Is(a.err, os.ErrNotExist) && errors.Is(b.err, os.ErrNotExist) {
		return true, nil
	}
	_, err := readRecoveryPhase(o.dir, key, o.frozen)
	return false, err
}

func recoveryAckKey(index int) string { return fmt.Sprintf("ack-%03d", index) }

func (o *RecoveryOperation) commitRetained(source committedAttributionData) (Receipt, error) {
	g := o.destination
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	if g.shut {
		return Receipt{}, ErrLaneSetClosed
	}
	if g.Closed() || !bytes.Equal(g.recoveryID, o.plan.RecoveryID) {
		return Receipt{}, ErrRecoveryPlan
	}
	receipt, err := g.spool.commit("", source.record.EventID, source.record.Body, Bindings{}, &pendingAttribution{source: &source, grant: o.grant})
	return Receipt{Generation: g.Identity(), Sequence: receipt.Sequence}, err
}
