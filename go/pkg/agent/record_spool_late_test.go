/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// All fixtures here are invented: a synthetic agent id, scope and assignment, and
// an OTLP relay frame whose bytes mean nothing.

const lateTestIssuer, lateTestIssuerKey = "late-test-issuer", "late-test-key-1"

// uuidV7At builds an RFC 9562 UUIDv7 for an instant, the way an agent stamped the
// event id when it produced the record.
func uuidV7At(t *testing.T, at time.Time) []byte {
	t.Helper()
	id := make([]byte, 16)
	binary.BigEndian.PutUint64(id[:8], uint64(at.UnixMilli())<<16)
	id[6], id[7] = 0x70, 0x01
	id[8] = 0x80
	copy(id[9:], []byte{1, 2, 3, 4, 5, 6, 7})
	require.NoError(t, edgerecord.ValidateUUIDv7(id))
	return id
}

// daysOldRelayRecord is an OTLP relay record produced at producedAt under a standing
// grant that was valid then and has since expired, at authority epoch 1.
func daysOldRelayRecord(t *testing.T, producedAt time.Time) []byte {
	t.Helper()
	return daysOldRelayRecordFrom(t, producedAt, sysmonEdgeAgentID)
}

// daysOldRelayRecordFrom is daysOldRelayRecord produced by origin.
func daysOldRelayRecordFrom(t *testing.T, producedAt time.Time, origin string) []byte {
	t.Helper()
	digest := sha256.Sum256([]byte("synthetic-otlp-relay-contract"))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte(lateTestIssuer), IssuerKeyId: []byte(lateTestIssuerKey), Algorithm: "ed25519",
		NotBeforeUnixNano: producedAt.Add(-24 * time.Hour).UnixNano(), ExpiresAtUnixNano: producedAt.Add(24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: edgerecord.OtlpRelayContractID, ContractVersion: edgerecord.OtlpRelayContractVersion,
			ContractBundleSha256: digest[:], RegistryEpoch: 1, RegistrySnapshotSha256: digest[:], EffectiveGrantSha256: digest[:],
			NetworkScopeId: testNetworkScopeID[:], ProducerAssignmentId: testAssignmentID[:], RunId: testAssignmentID[:],
			AuthorityEpoch: 1, ScopeId: testAssignmentID[:], ScopeSha256: digest[:],
			OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte(origin),
			ProducerInstanceId: []byte(origin),
			RouteProfile:       edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:       edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:          "serviceradar.agent.otlp_relay", PackageSha256: digest[:], CostModelVersion: 1,
			MaxProjectedRowCount: 1024, MaxProjectedWriteBytes: uint64(edgerecord.MaxRecordBytes),
		}},
	}
	edgerecord.SignCapability(capability, testIssuerPrivateKey())
	frame := &addonpb.OtlpRelayFrame{RelayId: 42, Batch: &addonpb.TelemetryBatch{
		Counters: &addonpb.TelemetryCounters{Received: 1, Emitted: 1},
		Records: []*addonpb.TelemetryRecord{{
			EventId:     "01950000-0000-7000-8000-000000000001",
			PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
			Payload:     []byte{0x0a, 0x04, 's', 'p', 'a', 'n'},
		}},
	}}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(frame)
	require.NoError(t, err)
	record, err := newEdgeRecord(capability, nil, payload, 1, uint64(len(payload)))
	require.NoError(t, err)
	record.EventId = uuidV7At(t, producedAt)
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(record)
	raw, err := edgerecord.CanonicalRecordBytes(record)
	require.NoError(t, err)
	return raw
}

// lateTrust is the agent's installed trust document: the issuer key with the given
// status, a fence that has since moved to epoch 2, and the agent's scope binding.
func lateTrust(t *testing.T, keyStatus string) *edgerecord.TrustSnapshot {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"keys": []any{map[string]any{
			"issuer_id": []byte(lateTestIssuer), "issuer_key_id": []byte(lateTestIssuerKey),
			"public_key": []byte(testIssuerPrivateKey().Public().(ed25519.PublicKey)),
			"purposes":   []string{"production", "source", "delivery"}, "status": keyStatus,
		}},
		"fences": []any{map[string]any{"network_scope_id": testNetworkScopeID[:], "producer_assignment_id": testAssignmentID[:], "run_shard": 0, "authority_epoch": 2}},
		"scopes": []any{map[string]any{"agent_id": sysmonEdgeAgentID, "network_scope_ids": [][]byte{testNetworkScopeID[:]}}},
	})
	require.NoError(t, err)
	snapshot, err := edgerecord.ParseTrustDocument(raw, []byte(sysmonEdgeAgentID), 1)
	require.NoError(t, err)
	return snapshot
}

// writeFlatSpoolTail lays out what a pre-lane agent left behind when an upgrade
// stopped it right after it committed records: a flat spool holding them unresolved.
func writeFlatSpoolTail(t *testing.T, root string, records ...[]byte) {
	t.Helper()
	flat, err := spool.Open(root)
	require.NoError(t, err)
	for _, raw := range records {
		record, decodeErr := edgerecord.DecodeRecord(raw)
		require.NoError(t, decodeErr)
		_, err = flat.Append(record.GetEventId(), raw)
		require.NoError(t, err)
	}
	require.NoError(t, flat.Close())
}

// coreLateDecisions stands in for core's IssueEdgeLateAdmissionGrants: it signs the
// production-time decision core's authority history would reach for each record.
type coreLateDecisions struct{ publication edgev1.EdgeLatePublication }

func (c coreLateDecisions) RenewDeliveryGrants(_ context.Context, spoolID []byte, records []spool.Record) (map[uint64]*edgev1.EdgeSignedCapabilityV1, error) {
	reason := edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_ADMITTED
	if c.publication == edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_AUDIT {
		reason = edgev1.EdgeLateDecisionReason_EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION
	}
	now := time.Now()
	out := make(map[uint64]*edgev1.EdgeSignedCapabilityV1, len(records))
	for _, rec := range records {
		record, err := edgerecord.DecodeRecord(rec.Body)
		if err != nil {
			return nil, err
		}
		producedAt, err := edgerecord.ProducedAtUnixNano(record)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(rec.Body)
		grant := &edgev1.EdgeSignedCapabilityV1{
			CapabilityVersion: 1, IssuerId: []byte(lateTestIssuer), IssuerKeyId: []byte(lateTestIssuerKey), Algorithm: "ed25519",
			NotBeforeUnixNano: now.Add(-time.Minute).UnixNano(), ExpiresAtUnixNano: now.Add(15 * time.Minute).UnixNano(),
			Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
				EventId: record.GetEventId(), RecordSha256: sum[:], SpoolId: spoolID, Sequence: rec.Sequence,
				Transition: &edgev1.EdgeDeliveryClaimsV1_LateAdmission{LateAdmission: &edgev1.EdgeDeliveryLateAdmissionV1{
					ProducedAtUnixNano: producedAt, AuthorityEpoch: record.GetProducerContext().GetAuthorityEpoch(),
					Publication: c.publication, Reason: reason,
				}},
			}},
		}
		edgerecord.SignCapability(grant, testIssuerPrivateKey())
		out[rec.Sequence] = grant
	}
	return out, nil
}

// lateGateway is a LATE-session gateway whose every decision is the Go oracle of
// the gateway late path (edgerecord.ValidateLateFrameSigned) over its trust snapshot.
type lateGateway struct {
	trust *edgerecord.TrustSnapshot

	mu        sync.Mutex
	open      *edgev1.EdgeRecordLaneOpen
	decisions []edgerecord.FrameDecision
	pending   []*edgev1.EdgeRecordDisposition
	out       chan *edgev1.EdgeRecordServerMessage
}

func (g *lateGateway) Stream(ctx context.Context, _ ...grpc.CallOption) (grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage], error) {
	g.out = make(chan *edgev1.EdgeRecordServerMessage, 4)
	return &lateGatewayStream{gateway: g, ctx: ctx}, nil
}

type lateGatewayStream struct {
	grpc.ClientStream
	gateway *lateGateway
	ctx     context.Context
}

func (s *lateGatewayStream) Context() context.Context { return s.ctx }

func (s *lateGatewayStream) Send(msg *edgev1.EdgeRecordClientMessage) error {
	g := s.gateway
	g.mu.Lock()
	defer g.mu.Unlock()
	if open := msg.GetLaneOpen(); open != nil {
		g.open = open
		g.out <- &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: &edgev1.EdgeRecordLaneOpenAck{
			SpoolId: open.GetSpoolId(), SessionNonce: open.GetSessionNonce(),
			GrantedByteCredits: open.GetRequestedByteCredits(), GrantedFrameCredits: open.GetRequestedFrameCredits(),
			RouteProfile: open.GetRouteProfile(), TrafficClass: open.GetTrafficClass(),
		}}}
		return nil
	}
	frame := msg.GetDeliveryFrame()
	record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
	if err != nil {
		return err
	}
	policy, err := g.trust.LatePolicyFor(record, time.Now().UnixNano())
	if err != nil {
		return err
	}
	decision, err := edgerecord.ValidateLateFrameSigned(frame, []byte(sysmonEdgeAgentID), policy)
	kind := edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
	switch {
	case err != nil:
	case decision.Publication == edgerecord.FramePublicationPrimary:
		kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
	case decision.Publication == edgerecord.FramePublicationAudit:
		kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY
	case decision.Publication == edgerecord.FramePublicationSecurityQuarantine:
		kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE
	}
	g.decisions = append(g.decisions, decision)
	g.pending = append(g.pending, &edgev1.EdgeRecordDisposition{Sequence: frame.GetSequence(), EventId: record.GetEventId(), Kind: kind})
	return nil
}

func (s *lateGatewayStream) CloseSend() error {
	g := s.gateway
	g.mu.Lock()
	defer g.mu.Unlock()
	through := g.open.GetFirstUnresolvedSequence() - 1
	for _, d := range g.pending {
		if d.GetKind() == edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE {
			break
		}
		through = d.GetSequence()
	}
	g.out <- &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: &edgev1.EdgeDeliveryAckV1{
		SpoolId: g.open.GetSpoolId(), ResolvedThroughSequence: through, Dispositions: g.pending, SessionNonce: g.open.GetSessionNonce(),
	}}}
	return nil
}

func (s *lateGatewayStream) Recv() (*edgev1.EdgeRecordServerMessage, error) {
	select {
	case msg := <-s.gateway.out:
		return msg, nil
	case <-s.ctx.Done():
		return nil, s.ctx.Err()
	}
}

// handOffAndDeliver opens the agent's spool over a flat tail, hands it off, and
// delivers the late generation on a LATE session.
func handOffAndDeliver(t *testing.T, root string, trust *edgerecord.TrustSnapshot, core coreLateDecisions) (*RecordSpool, *lateGateway, LegacyHandoff) {
	t.Helper()
	sp, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })

	report, err := sp.HandOffLegacy()
	require.NoError(t, err)
	sources := sp.LateSources()
	require.Len(t, sources, 1)

	gateway := &lateGateway{trust: trust}
	source := sources[0]
	run, err := sender.New(source.Source, gateway, sender.Config{
		SpoolID: source.Identity.SpoolID, RouteProfile: source.Identity.Lane.RouteProfile, TrafficClass: source.Identity.Lane.TrafficClass,
		RequestedByteCredits: 1 << 20, RequestedFrameCredits: 64, PersistAcknowledgements: true,
		LateAdmission: true, LateAdmissionProtocolVersion: edgerecord.LateAdmissionProtocolVersion,
		Grants: core,
	})
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_, err = run.RunOnce(ctx)
	require.NoError(t, err)
	return sp, gateway, report
}

// The 1.5.1 -> 1.5.2 upgrade left records in the pre-lane flat spool that lane
// admission refuses for good, because their production grant expired and their
// fence moved on. Under the production-time rule the new agent hands that tail to
// a late generation, the flat spool is retired, and the record is delivered on a
// LATE session where core's history decides it PRIMARY.
func TestDaysOldFlatSpoolRecordIsRedeliveredThroughTheLateLane(t *testing.T) {
	root := t.TempDir()
	raw := daysOldRelayRecord(t, time.Now().Add(-6*24*time.Hour))
	writeFlatSpoolTail(t, root, raw)
	trust := lateTrust(t, "valid")

	// The dead end this change removes: live admission refuses the record.
	probe, err := openTestRecordSpool(t, t.TempDir())
	require.NoError(t, err)
	probe.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	_, err = probe.PrepareRecord(raw)
	require.ErrorIs(t, err, edgerecord.ErrAuthorityExpired)
	require.NoError(t, probe.Close())

	sp, gateway, report := handOffAndDeliver(t, root, trust, coreLateDecisions{publication: edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY})

	require.Equal(t, 1, report.HandedOff)
	require.Zero(t, report.Rejected)
	require.Zero(t, sp.RetainedLegacyBytes(), "the flat spool is retired once its tail is handed off")
	_, statErr := os.Lstat(filepath.Join(root, "lane.seg"))
	require.ErrorIs(t, statErr, os.ErrNotExist)

	require.Len(t, gateway.decisions, 1)
	require.Equal(t, edgerecord.FramePublicationPrimary, gateway.decisions[0].Publication)
	require.Equal(t, edgerecord.FrameDeliveryModeLateAdmission, gateway.decisions[0].DeliveryMode)
	require.True(t, gateway.open.GetLateAdmission())
	require.Zero(t, sp.LatePending(), "the late record is resolved by the gateway's acknowledgement")
}

// A record signed by a compromise-revoked key still leaves the edge -- nothing is
// stranded -- but only to security quarantine, even though core would grant PRIMARY
// for its interval: a revoked key can never backfill.
func TestRevokedKeyFlatSpoolRecordIsQuarantinedNeverProjected(t *testing.T) {
	root := t.TempDir()
	raw := daysOldRelayRecord(t, time.Now().Add(-6*24*time.Hour))
	writeFlatSpoolTail(t, root, raw)
	trust := lateTrust(t, "historically_revoked")

	sp, gateway, report := handOffAndDeliver(t, root, trust, coreLateDecisions{publication: edgev1.EdgeLatePublication_EDGE_LATE_PUBLICATION_PRIMARY})

	require.Equal(t, 1, report.HandedOff)
	require.Len(t, gateway.decisions, 1)
	require.Equal(t, edgerecord.FramePublicationSecurityQuarantine, gateway.decisions[0].Publication)
	require.NotEqual(t, edgerecord.FramePublicationPrimary, gateway.decisions[0].Publication)
	require.Zero(t, sp.LatePending())
}

// A missing trust snapshot is the one condition that pauses the handoff: nothing is
// appended, resolved or retired, and the next pass picks the tail up in order.
func TestLegacyHandoffWaitsForTrustWithoutTouchingTheTail(t *testing.T) {
	root := t.TempDir()
	raw := daysOldRelayRecord(t, time.Now().Add(-6*24*time.Hour))
	writeFlatSpoolTail(t, root, raw)
	before, err := os.ReadFile(filepath.Join(root, "lane.seg"))
	require.NoError(t, err)

	sp, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return nil })

	report, err := sp.HandOffLegacy()
	require.ErrorIs(t, err, edgerecord.ErrTrustMissing)
	require.Equal(t, uint64(1), report.Pending)
	require.Empty(t, sp.LateSources())
	after, err := os.ReadFile(filepath.Join(root, "lane.seg"))
	require.NoError(t, err)
	require.Equal(t, before, after)

	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return lateTrust(t, "valid") })
	report, err = sp.HandOffLegacy()
	require.NoError(t, err)
	require.Equal(t, 1, report.HandedOff)
}

// The producer admission gate pauses new live records while the bulk backlog
// sits above its low water. Handing off the flat tail is that backlog draining,
// so a paused gate must not hold it: the tail moves to late storage, the flat
// spool is retired, and its retained charge is released.
func TestLegacyHandoffDrainsWhileTheAdmissionGateIsPaused(t *testing.T) {
	root := t.TempDir()
	raws := [][]byte{
		daysOldRelayRecord(t, time.Now().Add(-6*24*time.Hour)),
		daysOldRelayRecord(t, time.Now().Add(-5*24*time.Hour)),
	}
	writeFlatSpoolTail(t, root, raws...)

	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	require.NoError(t, err)
	paused := func(string, uint64) bool { return false }
	sp, err := OpenRecordSpool(root, allocator, spool.WithAdmissionGate(paused))
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	trust := lateTrust(t, "valid")
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	require.NotZero(t, sp.RetainedLegacyBytes())

	report, err := sp.HandOffLegacy()
	require.NoError(t, err)
	require.Equal(t, len(raws), report.HandedOff)
	require.Zero(t, report.Pending)
	require.Equal(t, uint64(len(raws)), sp.LatePending())
	require.Zero(t, sp.RetainedLegacyBytes())
	_, statErr := os.Lstat(filepath.Join(root, "lane.seg"))
	require.ErrorIs(t, statErr, os.ErrNotExist)
}

// leaveOrdinaryRoom applies a spool budget, through the runtime path core's
// edge_spool_max_bytes takes, that leaves exactly free ordinary bytes.
func leaveOrdinaryRoom(t *testing.T, allocator *spool.Allocator, free uint64) {
	t.Helper()
	usage := allocator.Usage()
	require.NoError(t, allocator.SetCapacity(usage.Floor+usage.OrdinaryUsed+free))
	usage = allocator.Usage()
	require.Equal(t, free, usage.OrdinaryCeiling-usage.OrdinaryUsed)
}

func lateTail(t *testing.T, n int) ([][]byte, uint64) {
	t.Helper()
	var raws [][]byte
	needed := uint64(spool.GenerationMetadataCharge)
	for i := range n {
		raw := daysOldRelayRecord(t, time.Now().Add(-time.Duration(6*24-i)*time.Hour))
		raws = append(raws, raw)
		needed += spool.AttributedAppendCharge(len(raw))
	}
	return raws, needed
}

// A flat tail is reclaimed only after every record is resolved, so a pass must
// hold two copies at once. When the budget cannot, the pass copies nothing and
// says how much room it needs; once core raises the budget the next pass hands
// the whole tail off.
func TestLegacyHandoffWaitsForCapacityWithoutAPartialCopy(t *testing.T) {
	root := t.TempDir()
	raws, needed := lateTail(t, 3)
	var bodies uint64
	for _, raw := range raws {
		bodies += uint64(len(raw))
	}
	require.Greater(t, needed, bodies, "a copy charges more than its bodies")
	writeFlatSpoolTail(t, root, raws...)
	segment := filepath.Join(root, "lane.seg")
	before, err := os.ReadFile(segment)
	require.NoError(t, err)

	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	require.NoError(t, err)
	sp, err := OpenRecordSpool(root, allocator)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	trust := lateTrust(t, "valid")
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	leaveOrdinaryRoom(t, allocator, needed-1)

	report, err := sp.HandOffLegacy()
	require.ErrorIs(t, err, ErrLegacyHandoffInsufficientCapacity)
	require.Equal(t, "insufficient_capacity", report.Reason)
	require.Equal(t, needed, report.CapacityNeeded)
	require.Equal(t, uint64(len(raws)), report.Pending)
	require.Zero(t, report.HandedOff)
	require.Empty(t, sp.LateSources(), "no partial copy")
	after, err := os.ReadFile(segment)
	require.NoError(t, err)
	require.Equal(t, before, after)
	status, ok := sp.LegacyHandoffStatus()
	require.True(t, ok)
	require.Equal(t, "insufficient_capacity", status.Reason)

	leaveOrdinaryRoom(t, allocator, needed)
	report, err = sp.HandOffLegacy()
	require.NoError(t, err)
	require.Equal(t, len(raws), report.HandedOff)
	require.Equal(t, uint64(len(raws)), sp.LatePending())
	require.Zero(t, sp.RetainedLegacyBytes())
	_, statErr := os.Lstat(segment)
	require.ErrorIs(t, statErr, os.ErrNotExist)
}

// A pass that stopped part-way resumes in the room the rest of the tail still
// needs. Here a crash left three records in late storage, across the host's own
// lane and another principal's hold, before the flat spool resolved any of them:
// they need only their flat resolution, the hold's generation is not billed
// again, and only the last record is appended.
func TestLegacyHandoffResumesInTheRoomTheSuffixNeeds(t *testing.T) {
	root := t.TempDir()
	const otherPrincipal = "agent-superseded-0001"
	base := time.Now().Add(-6 * 24 * time.Hour)
	raws := [][]byte{
		daysOldRelayRecord(t, base),
		daysOldRelayRecord(t, base.Add(time.Hour)),
		daysOldRelayRecordFrom(t, base.Add(2*time.Hour), otherPrincipal),
		daysOldRelayRecordFrom(t, base.Add(3*time.Hour), otherPrincipal),
	}
	writeFlatSpoolTail(t, root, raws...)

	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	require.NoError(t, err)
	sp, err := OpenRecordSpool(root, allocator)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	trust := lateTrust(t, "valid")
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })

	for _, raw := range raws[:3] {
		_, err = sp.AdmitLate(raw)
		require.NoError(t, err)
	}
	held := sp.LatePending()
	require.Equal(t, uint64(3), held)

	leaveOrdinaryRoom(t, allocator, spool.AttributedAppendCharge(len(raws[3])))
	report, err := sp.HandOffLegacy()
	require.NoError(t, err)
	require.Equal(t, len(raws), report.HandedOff)
	require.Equal(t, uint64(len(raws)), sp.LatePending(), "one late copy of each record")
	require.Zero(t, sp.RetainedLegacyBytes())
	_, statErr := os.Lstat(filepath.Join(root, "lane.seg"))
	require.ErrorIs(t, statErr, os.ErrNotExist)
}

// A LATE_ADMISSION_REQUIRED acknowledgement relocates at most one credit window
// of records, each charged no more than spool.AttributedAppendCharge (plus the
// late generation they open), so a window relocates into exactly that much room
// and charges no more.
func TestRelocatingACreditWindowStaysWithinItsBound(t *testing.T) {
	raws, needed := lateTail(t, 4)
	allocator, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 1 << 30, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: spool.DefaultRecoveryFootprint()})
	require.NoError(t, err)
	sp, err := OpenRecordSpool(t.TempDir(), allocator)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	trust := lateTrust(t, "valid")
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	leaveOrdinaryRoom(t, allocator, needed)
	used := allocator.Usage().OrdinaryUsed

	for i, raw := range raws {
		record, decodeErr := edgerecord.DecodeRecord(raw)
		require.NoError(t, decodeErr)
		require.NoError(t, sp.RelocateLate(spool.Record{Sequence: uint64(i + 1), EventID: record.GetEventId(), Body: raw}))
	}
	require.Equal(t, uint64(len(raws)), sp.LatePending())
	require.LessOrEqual(t, allocator.Usage().OrdinaryUsed-used, needed)
}

// A crash after the late append and before the flat spool recorded the handoff
// leaves the record in both; the next pass recognizes it and keeps one copy.
func TestLegacyHandoffAfterACrashKeepsOneCopy(t *testing.T) {
	root := t.TempDir()
	raw := daysOldRelayRecord(t, time.Now().Add(-6*24*time.Hour))
	writeFlatSpoolTail(t, root, raw)
	trust := lateTrust(t, "valid")

	sp, err := openTestRecordSpool(t, root)
	require.NoError(t, err)
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })
	landed, err := sp.AdmitLate(raw) // the append that landed before the crash
	require.NoError(t, err)
	require.NotEmpty(t, landed.Receipt.Generation.SpoolID)
	require.NoError(t, sp.Close())

	sp, err = openTestRecordSpool(t, root)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	sp.SetTrustProvider(func() *edgerecord.TrustSnapshot { return trust })

	// The recognized copy is the custody the flat spool records: its own
	// generation and slot, never an empty spool id.
	existing, err := sp.admitLate(raw, true)
	require.NoError(t, err)
	require.Equal(t, landed.Receipt.Generation.SpoolID, existing.Receipt.Generation.SpoolID)
	require.Equal(t, landed.Receipt.Sequence, existing.Receipt.Sequence)
	require.Equal(t, uint64(1), sp.LatePending())

	report, err := sp.HandOffLegacy()
	require.NoError(t, err)
	require.Equal(t, 1, report.HandedOff)
	require.Equal(t, uint64(1), sp.LatePending())
}
