// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

type recoveryControlAttempt struct {
	Generation   GenerationIdentity
	Count        uint32
	BundleSHA256 []byte
}

func recoveryAttemptKey(attempt uint32) string { return fmt.Sprintf("attempt-%03d", attempt) }

// BeginControlAttempt freezes the exact publication slot mapping before append.
// A failed attempt is retained; a new dedicated generation can reconstruct the
// same publication bytes under this grant without acquiring another slot.
func (o *RecoveryOperation) BeginControlAttempt(control *Generation) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if control == nil || !bytes.Equal(control.RecoveryID(), o.plan.RecoveryID) || control.RecoveryAttempt() >= MaxRecoveryControlAttempts {
		return ErrRecoveryPlan
	}
	bundle, records, err := o.publicationBundle(control.RecoveryAttempt())
	if err != nil {
		return err
	}
	if !control.id.Identity.equal(o.plan.Source.Identity) || control.id.Lane.RouteProfile != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 {
		return ErrRecoveryPlan
	}
	key := recoveryAttemptKey(control.RecoveryAttempt())
	pending, err := o.pendingPhase(key)
	if err != nil {
		return err
	}
	if pending {
		if control.NextSequence() != 1 {
			return ErrRecoveryCoverage
		}
		needed := uint64(len(records) * (minRecordLen + 4*evidenceEntryLen2 + sidecarSlotSize + terminalEvidenceAllowance))
		for _, p := range records {
			needed += uint64(len(p.Body))
		}
		if needed > o.grant.Remaining(ArtifactManifestPages) {
			return &ReserveExhaustedError{Artifact: ArtifactManifestPages, Requested: needed, Remaining: o.grant.Remaining(ArtifactManifestPages)}
		}
	}
	if err = o.grant.AttachControlLane(control); err != nil {
		return err
	}
	digest := sha256.Sum256(bundle)
	payload, err := json.Marshal(recoveryControlAttempt{Generation: control.Identity(), Count: uint32(len(records)), BundleSHA256: digest[:]})
	if err != nil {
		return err
	}
	return writeRecoveryPhase(o.dir, key, o.frozen, payload, o.grant)
}

func (o *RecoveryOperation) controlAttemptPublications(control *Generation) ([]frozenRecoveryPublication, error) {
	if control == nil || !bytes.Equal(control.RecoveryID(), o.plan.RecoveryID) {
		return nil, ErrRecoveryPlan
	}
	attempt, records, err := o.readControlAttempt(control.RecoveryAttempt())
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(encodeIdentity(attempt.Generation), encodeIdentity(control.id)) {
		return nil, ErrRecoveryPlan
	}
	return records, nil
}

func (o *RecoveryOperation) readControlAttempt(ordinal uint32) (recoveryControlAttempt, []frozenRecoveryPublication, error) {
	var attempt recoveryControlAttempt
	if ordinal >= MaxRecoveryControlAttempts {
		return attempt, nil, ErrRecoverySplitRequired
	}
	raw, err := readRecoveryPhase(o.dir, recoveryAttemptKey(ordinal), o.frozen)
	if err != nil {
		return attempt, nil, err
	}
	if err = decodeRecoveryJSON(raw, &attempt); err != nil {
		return attempt, nil, err
	}
	bundle, records, err := o.publicationBundle(ordinal)
	if err != nil {
		return attempt, nil, err
	}
	digest := sha256.Sum256(bundle)
	if attempt.Count != uint32(len(records)) || !bytes.Equal(attempt.BundleSHA256, digest[:]) {
		return attempt, nil, ErrRecoveryPlan
	}
	return attempt, records, nil
}

// Publish appends an originally authorized, paired frozen publication. Replay
// never mints a public validated-attribution carrier or changes signed bytes;
// the ordinary sender still obtains current delivery authority before sending.
func (o *RecoveryOperation) Publish(control *Generation, index int) (Receipt, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	records, err := o.controlAttemptPublications(control)
	if err != nil {
		return Receipt{}, err
	}
	if index < 0 || index >= len(records) {
		return Receipt{}, ErrRecoveryPlan
	}
	publication := records[index]
	if err = o.validateFrozenPublication(index, publication); err != nil {
		return Receipt{}, err
	}
	sequence := uint64(index + 1)
	if control.NextSequence() > sequence {
		witness, err := control.CommittedAttribution(sequence)
		if err != nil {
			return Receipt{}, err
		}
		if !bytes.Equal(witness.record.Body, publication.Body) || !bytes.Equal(witness.record.EventID, publication.EventID) {
			return Receipt{}, ErrRecoveryCoverage
		}
		return Receipt{Generation: control.Identity(), Sequence: sequence}, nil
	}
	if control.NextSequence() != sequence {
		return Receipt{}, ErrRecoveryCoverage
	}
	control.lifecycle.Lock()
	defer control.lifecycle.Unlock()
	if control.shut || control.Closed() {
		return Receipt{}, ErrLaneSetClosed
	}
	receipt, err := control.spool.commit("", publication.EventID, publication.Body, Bindings{}, &pendingAttribution{frozen: &publication, grant: o.grant})
	return Receipt{Generation: control.Identity(), Sequence: receipt.Sequence}, err
}

func (o *RecoveryOperation) validateFrozenPublication(index int, p frozenRecoveryPublication) error {
	record, err := edgerecord.DecodeRecord(p.Body)
	if err != nil {
		return err
	}
	if err = o.checkPublicationBody(index, record); err != nil {
		return err
	}
	if !bytes.Equal(p.EventID, record.EventId) || !bytes.Equal(record.NetworkScopeId, o.plan.Source.Identity.NetworkScopeID) || !bytes.Equal(record.ProducerContext.OriginPrincipalId, o.plan.Source.Identity.AgentID) {
		return ErrRecoveryJournalCorrupt
	}
	span := new(edgev1.EdgeClassificationSpanV1)
	if err = proto.Unmarshal(p.Attribution, span); err != nil {
		return err
	}
	if span.GetFromSequence() != uint64(index+1) || span.GetThroughSequence() != uint64(index+1) {
		return ErrRecoveryJournalCorrupt
	}
	_, err = spanAttribution(span)
	return err
}

type recoveryPublicationReceipt struct {
	Control                              GenerationIdentity
	Attempt                              uint32
	Sequence                             uint64
	EventID, RecordSHA256, BindingSHA256 []byte
	SessionNonce                         []byte
	PriorResolved, AcknowledgedThrough   uint64
	Disposition, ResponseSHA256          []byte
}

// CapturePublicationAck must run on the authenticated sender's sealed response
// BEFORE ordinary recovery-lane resolution. A PubAck-derived authoritative accept
// is required for the exact planned event, slot, body and committed binding.
func (o *RecoveryOperation) CapturePublicationAck(control *Generation, index int, validated *edgerecord.ValidatedAck) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	records, err := o.controlAttemptPublications(control)
	if err != nil {
		return err
	}
	if index < 0 || index >= len(records) {
		return ErrRecoveryPlan
	}
	pending, err := o.pendingPhase(recoveryAckKey(index))
	if err != nil {
		return err
	}
	if !pending {
		_, err = o.readPublicationReceipt(index)
		return err
	}
	ack, session, err := validated.Snapshot()
	if err != nil {
		return err
	}
	sequence := uint64(index + 1)
	if !bytes.Equal(session.SpoolID, control.id.SpoolID) || session.RouteProfile != control.id.Lane.RouteProfile || session.TrafficClass != control.id.Lane.TrafficClass ||
		sequence <= session.ResolvedThrough || sequence > ack.ResolvedThroughSequence || len(session.Nonce) < edgerecord.MinNonceBytes || len(session.Nonce) > edgerecord.MaxNonceBytes {
		return ErrRecoveryCoverage
	}
	var selected *edgev1.EdgeRecordDisposition
	for _, disposition := range ack.Dispositions {
		if disposition.Sequence == sequence {
			selected = disposition
			break
		}
	}
	publication := records[index]
	if selected == nil || selected.Kind != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE || !bytes.Equal(selected.EventId, publication.EventID) {
		return ErrRecoveryCoverage
	}
	witness, err := control.CommittedAttribution(sequence)
	if err != nil {
		return err
	}
	if !bytes.Equal(witness.record.Body, publication.Body) || !bytes.Equal(witness.record.EventID, publication.EventID) {
		return ErrRecoveryCoverage
	}
	disposition, err := proto.MarshalOptions{Deterministic: true}.Marshal(selected)
	if err != nil {
		return err
	}
	response, err := proto.MarshalOptions{Deterministic: true}.Marshal(ack)
	if err != nil {
		return err
	}
	responseHash := sha256.Sum256(response)
	receipt := recoveryPublicationReceipt{Control: control.Identity(), Attempt: control.RecoveryAttempt(), Sequence: sequence,
		EventID: bytes.Clone(publication.EventID), RecordSHA256: bytes.Clone(witness.entry.coordinates.RecordSHA256), BindingSHA256: witness.BindingDigest(), SessionNonce: bytes.Clone(session.Nonce),
		PriorResolved: session.ResolvedThrough, AcknowledgedThrough: ack.ResolvedThroughSequence, Disposition: disposition, ResponseSHA256: responseHash[:]}
	payload, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	return writeRecoveryPhase(o.dir, recoveryAckKey(index), o.frozen, payload, o.grant)
}

func (o *RecoveryOperation) readPublicationReceipt(index int) ([]byte, error) {
	raw, err := readRecoveryPhase(o.dir, recoveryAckKey(index), o.frozen)
	if err != nil {
		return nil, err
	}
	var receipt recoveryPublicationReceipt
	if err = decodeRecoveryJSON(raw, &receipt); err != nil {
		return nil, err
	}
	attempt, records, err := o.readControlAttempt(receipt.Attempt)
	if err != nil {
		return nil, err
	}
	if index < 0 || index >= len(records) {
		return nil, ErrRecoveryPlan
	}
	publication := records[index]
	hash := sha256.Sum256(publication.Body)
	if receipt.Sequence != uint64(index+1) || receipt.PriorResolved >= receipt.Sequence || receipt.AcknowledgedThrough < receipt.Sequence ||
		!receipt.Control.Identity.equal(o.plan.Source.Identity) || receipt.Control.Lane.RouteProfile != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 ||
		!bytes.Equal(receipt.EventID, publication.EventID) || !bytes.Equal(receipt.RecordSHA256, hash[:]) || len(receipt.BindingSHA256) != 32 || len(receipt.ResponseSHA256) != 32 ||
		len(receipt.SessionNonce) < edgerecord.MinNonceBytes || len(receipt.SessionNonce) > edgerecord.MaxNonceBytes {
		return nil, ErrRecoveryCoverage
	}
	if !bytes.Equal(encodeIdentity(attempt.Generation), encodeIdentity(receipt.Control)) || attempt.Count != uint32(len(o.manifest.Pages)+1) {
		return nil, ErrRecoveryCoverage
	}
	span := new(edgev1.EdgeClassificationSpanV1)
	if err = proto.Unmarshal(publication.Attribution, span); err != nil {
		return nil, err
	}
	attribution, err := spanAttribution(span)
	if err != nil {
		return nil, err
	}
	binding, err := edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, bindingCoordinates(receipt.Control, receipt.Sequence, receipt.EventID, hash[:]), attribution)
	if err != nil || !bytes.Equal(binding, receipt.BindingSHA256) {
		return nil, ErrRecoveryCoverage
	}
	var disposition edgev1.EdgeRecordDisposition
	if err = proto.Unmarshal(receipt.Disposition, &disposition); err != nil {
		return nil, err
	}
	if disposition.Sequence != receipt.Sequence || disposition.Kind != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE || disposition.RejectionCode != "" || len(disposition.ProtoReflect().GetUnknown()) != 0 || !bytes.Equal(disposition.EventId, publication.EventID) {
		return nil, ErrRecoveryCoverage
	}
	return raw, nil
}

// bind is private to replay of a pair that originally accepted sealed typed
// authority. It cannot manufacture a public ValidatedAttribution capability.
func (p frozenRecoveryPublication) bind(c edgerecord.LocalBindingCoordinates, eventID, body []byte) (edgerecord.RecoveryAttribution, []byte, error) {
	var a edgerecord.RecoveryAttribution
	if !bytes.Equal(p.Body, body) || !bytes.Equal(p.EventID, eventID) {
		return a, nil, ErrAttributionRequired
	}
	span := new(edgev1.EdgeClassificationSpanV1)
	if err := proto.Unmarshal(p.Attribution, span); err != nil {
		return a, nil, err
	}
	a, err := spanAttribution(span)
	if err != nil {
		return a, nil, err
	}
	digest, err := edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, c, a)
	return a, digest, err
}

// RecoveryPublicationProgress is a detached view of paired immutable transport
// attempts and authoritative publication receipts. It is scheduling information,
// never deletion authority; SealCoverage reopens and validates the proof itself.
type RecoveryPublicationProgress struct {
	Bundles         [MaxRecoveryControlAttempts][]*edgev1.EdgeRecordV1
	Acknowledged    []bool
	SourceReclaimed bool
	CoverageSealed  bool
}

func (o *RecoveryOperation) PublicationProgress() (RecoveryPublicationProgress, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	state := RecoveryPublicationProgress{Acknowledged: make([]bool, len(o.manifest.Pages)+1)}
	for attempt := range uint32(MaxRecoveryControlAttempts) {
		_, bundle, err := o.publicationBundle(attempt)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return state, err
		}
		for _, publication := range bundle {
			record, err := edgerecord.DecodeRecord(publication.Body)
			if err != nil {
				return state, err
			}
			state.Bundles[attempt] = append(state.Bundles[attempt], record)
		}
	}
	for index := range state.Acknowledged {
		_, err := o.readPublicationReceipt(index)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return state, err
		}
		state.Acknowledged[index] = true
	}
	pending, err := o.pendingPhase("coverage")
	if err != nil {
		return state, err
	}
	state.CoverageSealed = !pending
	pending, err = o.pendingPhase("reclaimed")
	state.SourceReclaimed = !pending
	return state, err
}
