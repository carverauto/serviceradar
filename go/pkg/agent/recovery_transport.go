// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	gproto "google.golang.org/protobuf/proto"
)

func (c *RecoveryCoordinator) publish(ctx context.Context, run *recoveryRun, progress spool.RecoveryPublicationProgress) error {
	attempt := -1
	for i, bundle := range progress.Bundles {
		if len(bundle) > 0 {
			attempt = i
		}
	}
	refresh := attempt < 0
	replay := false
	if !refresh {
		var err error
		var reason string
		reason, err = c.publicationNeedsRefresh(run, uint32(attempt), progress)
		refresh, replay = reason != "", reason == "interrupted"
		if err != nil {
			return err
		}
	}
	if refresh {
		attempt++
		if attempt >= spool.MaxRecoveryControlAttempts {
			return spool.ErrRecoverySplitRequired
		}

		if replay {
			if err := run.op.ReplayPublications(uint32(attempt-1), uint32(attempt)); err != nil {
				return err
			}
		} else {
			publications, err := c.composePublications(ctx, run)
			if err != nil {
				return err
			}
			if err = run.op.FreezePublications(uint32(attempt), publications); err != nil {
				return err
			}
		}
	}
	control, ok := c.store.lanes.RecoveryDestination(c.controlLane(), run.plan.RecoveryID, uint32(attempt))
	if !ok {
		var err error
		control, err = c.store.lanes.CreateRecoveryControlDestination(c.controlLane(), run.plan.RecoveryID, uint32(attempt), run.grant)
		if err != nil {
			return err
		}
		c.mu.Lock()
		run.handles.Controls = append(run.handles.Controls, control)
		c.mu.Unlock()
	}
	if err := run.op.BeginControlAttempt(control); err != nil {
		return err
	}
	for index := range progress.Acknowledged {
		// Accepted immutable page receipts survive ordinary terminal resolution.
		// Reopening their already-resolved public commit witness is intentionally refused.
		if progress.Acknowledged[index] && control.NextSequence() > uint64(index+1) {
			continue
		}
		if _, err := run.op.Publish(control, index); err != nil {
			return err
		}
	}
	return control.SealRecoveryDestination()
}

func (c *RecoveryCoordinator) publicationNeedsRefresh(run *recoveryRun, attempt uint32, progress spool.RecoveryPublicationProgress) (string, error) {
	if c.store.trust == nil {
		return "", edgerecord.ErrTrustMissing
	}
	snapshot := c.store.trust()
	if snapshot == nil {
		return "", edgerecord.ErrTrustMissing
	}
	for _, record := range progress.Bundles[attempt] {
		policy, err := snapshot.PolicyFor(record, time.Now().UnixNano())
		if err != nil {
			return "", err
		}
		if err = edgerecord.ValidateRecordSigned(record, policy); err != nil {
			return "authority", nil
		}
	}
	if control, ok := c.store.lanes.RecoveryDestination(c.controlLane(), run.plan.RecoveryID, attempt); ok {
		for index, accepted := range progress.Acknowledged {
			if accepted {
				continue
			}
			sequence := uint64(index + 1)
			if sequence <= control.Resolved() {
				return "not_authoritative", nil
			}
			if _, gap := control.CoverageGap(sequence); gap {
				return "interrupted", nil
			}
		}
	}
	return "", nil
}

func (c *RecoveryCoordinator) composePublications(ctx context.Context, run *recoveryRun) ([]spool.AttributedAppend, error) {
	if c.store.recoveryGrant == nil {
		return nil, edgerecord.ErrTrustMissing
	}
	capability := c.store.recoveryGrant(time.Now())
	if capability == nil || !bytes.Equal(capability.GetProduction().GetNetworkScopeId(), run.plan.Source.Identity.NetworkScopeID) || !bytes.Equal(capability.GetProduction().GetOriginPrincipalId(), run.plan.Source.Identity.AgentID) {
		return nil, edgerecord.ErrTrustMissing
	}
	wrappers, spanCount, err := recoveryControlPayloads(run.manifest)
	if err != nil {
		return nil, err
	}
	var publications []spool.AttributedAppend
	for _, payload := range wrappers {
		authorization, err := c.client.AuthorizeEdgeRecovery(ctx, &proto.EdgeRecoveryAuthorizationRequest{Recovery: recoveryQuery(run), ControlPayload: payload, ProductionCapability: capability})
		if err != nil {
			return nil, err
		}
		// Every control may complete consumer repair. Its logical cost covers the
		// complete manifest under RecoveryProjectionCost's version-one contract.
		record, err := newEdgeRecord(capability, authorization.GetSourceAuthorization(), payload, uint32(16+6*spanCount), uint64((1<<20)+32768*spanCount))
		if err != nil {
			return nil, err
		}
		record.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
		record.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE
		record.Payload = bytes.Clone(payload)
		record.EncodedSize = uint32(len(payload))
		record.UncompressedSize = uint32(len(payload))
		digest := sha256.Sum256(payload)
		record.PayloadSha256 = digest[:]
		record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(record)
		raw, err := gproto.MarshalOptions{Deterministic: true}.Marshal(record)
		if err != nil {
			return nil, err
		}
		prepared, err := c.store.PrepareRecord(raw)
		if err != nil {
			return nil, err
		}
		publications = append(publications, *prepared)
	}
	return publications, nil
}

func recoveryControlPayloads(manifest spool.RecoveryManifest) ([][]byte, int, error) {
	var wrappers [][]byte
	spans := 0
	for _, raw := range manifest.Pages {
		page := new(edgev1.EdgeLossManifestPageV1)
		if err := gproto.Unmarshal(raw, page); err != nil {
			return nil, 0, err
		}
		spans += len(page.ClassificationSpans)
		encoded, err := gproto.MarshalOptions{Deterministic: true}.Marshal(&edgev1.EdgeRecoveryControlPayloadV1{Body: &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page}})
		if err != nil {
			return nil, 0, err
		}
		wrappers = append(wrappers, encoded)
	}
	tombstone := new(edgev1.SpoolLossTombstoneV1)
	if err := gproto.Unmarshal(manifest.Tombstone, tombstone); err != nil {
		return nil, 0, err
	}
	encoded, err := gproto.MarshalOptions{Deterministic: true}.Marshal(&edgev1.EdgeRecoveryControlPayloadV1{Body: &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tombstone}})
	if err != nil {
		return nil, 0, err
	}
	wrappers = append(wrappers, encoded)
	return wrappers, spans, nil
}

// RecoveryDelivery binds a sender session to its registered immutable operation.
// It never falls back to ordinary delivery renewal for recovered records.
type RecoveryDelivery struct {
	coordinator *RecoveryCoordinator
	run         *recoveryRun
	generation  *spool.Generation
	control     bool
}

func (c *RecoveryCoordinator) Delivery(generation *spool.Generation) (*RecoveryDelivery, error) {
	if len(generation.RecoveryID()) == 0 {
		return nil, nil
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	run := c.active
	if !c.ready || run == nil || !run.registered || run.op == nil || !bytes.Equal(run.handles.Destination.RecoveryID(), generation.RecoveryID()) {
		return nil, ErrRecoveryPending
	}
	return &RecoveryDelivery{coordinator: c, run: run, generation: generation, control: generation.Identity().Lane == c.controlLane()}, nil
}

func (d *RecoveryDelivery) RequiresCopyGrant() bool { return !d.control }

func (d *RecoveryDelivery) BeforeResolve(validated *edgerecord.ValidatedAck) error {
	if !d.control {
		return nil
	}
	ack, _, err := validated.Snapshot()
	if err != nil {
		return err
	}
	for _, disposition := range ack.GetDispositions() {
		if disposition.GetSequence() > ack.GetResolvedThroughSequence() || disposition.GetKind() != edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE {
			continue
		}
		if disposition.GetSequence() == 0 || disposition.GetSequence() > uint64(len(d.run.manifest.Pages)+1) {
			return spool.ErrRecoveryPlan
		}
		if err = d.run.op.CapturePublicationAck(d.generation, int(disposition.Sequence-1), validated); err != nil {
			return err
		}
	}
	return nil
}

func (d *RecoveryDelivery) RenewDeliveryGrants(ctx context.Context, spoolID []byte, records []spool.Record) (map[uint64]*edgev1.EdgeSignedCapabilityV1, error) {
	if d.control || !bytes.Equal(spoolID, d.run.plan.NewSpoolID) {
		return nil, spool.ErrRecoveryPlan
	}
	request := &proto.EdgeRecoveryCopyGrantRequest{Recovery: recoveryQuery(d.run)}
	for _, record := range records {
		var prior uint64
		for _, slot := range d.run.plan.Slots {
			if slot.Copy != nil && slot.Copy.NewSequence == record.Sequence {
				digest := sha256.Sum256(record.Body)
				if !bytes.Equal(slot.Copy.EventID, record.EventID) || !bytes.Equal(slot.Copy.RecordSHA256, digest[:]) {
					return nil, spool.ErrRecoveryPlan
				}
				prior = slot.Sequence
				break
			}
		}
		if prior == 0 {
			return nil, spool.ErrRecoveryPlan
		}
		request.Records = append(request.Records, &proto.EdgeRecoveryCopyGrantItem{PriorSequence: prior, NewSequence: record.Sequence, RecordBytes: record.Body})
	}
	response, err := d.coordinator.client.RenewEdgeRecoveryCopies(ctx, request)
	if err != nil {
		return nil, err
	}
	granted := make(map[uint64]*edgev1.EdgeSignedCapabilityV1)
	for _, result := range response.GetResults() {
		if capability := result.GetDeliveryCapability(); capability != nil {
			granted[result.GetSequence()] = capability
		}
	}
	if len(granted) == 0 {
		return nil, errors.Join(ErrRecoveryPending, errors.New("copy authority unavailable"))
	}
	return granted, nil
}
