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

// Package edgev1_test builds canonical fixtures for the producer-neutral edge
// record plane and byte-compares them against the committed testdata so ABI
// drift fails the build. Set EDGE_GOLDEN_UPDATE=1 to regenerate. The Elixir
// binding decodes the same bytes and independently recomputes the semantic /
// plan / recovery / capability-signing digests and verifies the Ed25519
// signatures against the exported issuer keys (cross-language ABI proof).
package edgev1_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const fixedMillis = int64(1_784_000_000_000) // 2026-07-14T00:53:20Z
const fixedNanos = fixedMillis * 1_000_000

// Two deterministic issuer keys exercise key rotation: production/delivery grants
// are signed by key A, source grants by key B. The public keys are exported as
// fixtures so the Elixir binding can verify the signatures independently.
var (
	issuerPrivA = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0xA1}, 32)) //nolint:gochecknoglobals // deterministic test issuer key
	issuerPrivB = ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0xB2}, 32)) //nolint:gochecknoglobals // deterministic test issuer key
)

// Shared plan/range digests bound into both the sweep body and the source grant,
// so the composed ValidateSweepRecord join succeeds.
func sweepPlanSha() []byte  { return digest32(0x9A) }
func sweepRangeSha() []byte { return digest32(0x9B) }

// goldenTrust resolves the exported issuer keys by (issuer_id, issuer_key_id).
type goldenTrust map[string]ed25519.PublicKey

func (m goldenTrust) ResolveKey(issuerID, keyID []byte, ev edgerecord.KeyEvidence) edgerecord.KeyResolution {
	if pub, ok := m[string(issuerID)+"|"+string(keyID)]; ok {
		return edgerecord.KeyResolution{Status: edgerecord.KeyValid, Public: pub, TrustPolicyEpoch: ev.TrustPolicyEpoch}
	}
	return edgerecord.KeyResolution{Status: edgerecord.KeyInvalid, TrustPolicyEpoch: ev.TrustPolicyEpoch}
}

// goldenPolicy accepts the golden record at its fixed event time under the active
// fence (producer authority_epoch 5).
func goldenPolicy() edgerecord.AuthorizationPolicy {
	return edgerecord.AuthorizationPolicy{
		Trust: goldenTrust{
			string(uuidv7(0xC0)) + "|" + string(uuidv7(0xC1)): issuerPrivA.Public().(ed25519.PublicKey),
			string(uuidv7(0xD0)) + "|" + string(uuidv7(0xD1)): issuerPrivB.Public().(ed25519.PublicKey),
		},
		NowUnixNano:      fixedNanos,
		ActiveFence:      edgerecord.ResolvedFence(5),
		TrustPolicyEpoch: 1,
	}
}

func uuidv7(seed byte) []byte {
	out := make([]byte, 16)
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], uint64(fixedMillis)<<16)
	copy(out[0:6], tsb[0:6])
	for i := 6; i < 16; i++ {
		out[i] = seed + byte(i)
	}
	out[6] = (out[6] & 0x0F) | 0x70
	out[8] = (out[8] & 0x3F) | 0x80
	return out
}

func digest32(tag byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = tag + byte(i)
	}
	return b
}

var (
	winNotBefore = fixedNanos - 3_600_000_000_000 //nolint:gochecknoglobals // fixed test window
	winExpires   = fixedNanos + 3_600_000_000_000 //nolint:gochecknoglobals // fixed test window
)

func productionCap(r *edgev1.EdgeRecordV1) *edgev1.EdgeSignedCapabilityV1 {
	p := r.GetProducerContext()
	c := r.GetOutputContract()
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: c.GetContractId(), ContractVersion: c.GetContractVersion(),
			ContractBundleSha256: c.GetContractBundleSha256(), RegistryEpoch: c.GetRegistryEpoch(),
			NetworkScopeId: r.GetNetworkScopeId(), ProducerAssignmentId: p.GetProducerAssignmentId(),
			TrafficClass: r.GetTrafficClass(), RouteProfile: r.GetRouteProfile(),
			OriginKind: p.GetOriginKind(), OriginPrincipalId: p.GetOriginPrincipalId(),
			ProducerInstanceId: p.GetProducerInstanceId(), RunId: p.GetRunId(), RunShard: p.GetRunShard(),
			AuthorityEpoch: p.GetAuthorityEpoch(), ScopeId: p.GetScopeId(), ScopeSha256: p.GetScopeSha256(),
			PackageSha256:          p.GetPackageSha256(),
			RegistrySnapshotSha256: c.GetRegistrySnapshotSha256(),
			EffectiveGrantSha256:   c.GetEffectiveGrantSha256(),
			MaxProjectedRowCount:   r.GetProjectedRowCount(),
			MaxProjectedWriteBytes: r.GetProjectedWriteBytes(),
			CostModelVersion:       r.GetCostModelVersion(),
			PackageId:              p.GetPackageId(),
		}},
	}
	edgerecord.SignCapability(cap, issuerPrivA)
	return cap
}

func sourceCap(r *edgev1.EdgeRecordV1, ctx, scopeID []byte) *edgev1.EdgeSignedCapabilityV1 {
	p := r.GetProducerContext()
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xD0), IssuerKeyId: uuidv7(0xD1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
			Kind:      edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
			ContextId: ctx, ScopeId: scopeID, ScopeSha256: sweepRangeSha(), NetworkScopeId: r.GetNetworkScopeId(),
			CollectionNotBeforeUnixNano: winNotBefore, CollectionExpiresUnixNano: winExpires,
			OriginPrincipalId: p.GetOriginPrincipalId(), ProducerInstanceId: p.GetProducerInstanceId(),
			ProducerAssignmentId: p.GetProducerAssignmentId(), RunId: p.GetRunId(), RunShard: p.GetRunShard(),
			AuthorityEpoch: p.GetAuthorityEpoch(), TrafficClass: r.GetTrafficClass(), RouteProfile: r.GetRouteProfile(),
			ExecutionPlanSha256: sweepPlanSha(), TargetRangeSha256: sweepRangeSha(),
			OriginKind: p.GetOriginKind(),
		}},
	}
	edgerecord.SignCapability(cap, issuerPrivB)
	return cap
}

func deliveryCap(record *edgev1.EdgeRecordV1, spool []byte, seq uint64) *edgev1.EdgeSignedCapabilityV1 {
	sum := sha256.Sum256(mustMarshal(record))
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
			EventId: record.GetEventId(), RecordSha256: sum[:], SpoolId: spool, Sequence: seq,
			Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{
				RecoveryId: uuidv7(0x86), PriorSpoolId: uuidv7(0x87), PriorSequence: 42,
			}},
		}},
	}
	edgerecord.SignCapability(cap, issuerPrivA)
	return cap
}

func mustMarshal(m proto.Message) []byte {
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		panic(err)
	}
	return b
}

func canonicalSweepBatch() *edgev1.SweepObservationBatchV1 {
	return &edgev1.SweepObservationBatchV1{
		ExecutionId: uuidv7(0x20), ExecutionShard: 3, AssignmentEpoch: 5, BatchSequence: 1, ObservedAtUnixNano: fixedNanos,
		ExecutionPlanId: uuidv7(0x21), ExecutionPlanSha256: sweepPlanSha(),
		TargetRangeId: uuidv7(0x22), TargetRangeSha256: sweepRangeSha(),
		AvailabilityPolicyId: []byte("policy-1"),
		Source:               edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		ConfiguredModeBits:   uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR),
		TestedChecks: []*edgev1.SweepTestV1{
			{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
			{Mode: edgev1.SweepMode_SWEEP_MODE_MTR, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		},
		Hosts: []*edgev1.SweepHostObservationV1{{
			Address:        []byte{10, 0, 0, 1},
			ResultModeBits: uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR),
			ModeRevision:   1,
			Icmp:           &edgev1.SweepIcmpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TargetReached: true, RoundTripMicro: proto.Uint64(0), Sent: 1, Received: 1},
			Mtr:            &edgev1.SweepMtrSummaryV1{TraceId: uuidv7(0x30), Outcome: edgev1.MtrOutcome_MTR_OUTCOME_REACHED, TargetReached: true, TotalHops: 4},
		}},
	}
}

func canonicalRecord(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()
	batch := canonicalSweepBatch()
	payload := mustMarshal(batch)
	sum := sha256.Sum256(payload)
	scope := uuidv7(0x11)
	// The source authority context/scope bind the exact sweep execution + range.
	ctx, scopeID := batch.GetExecutionId(), batch.GetTargetRangeId()
	contract := &edgev1.EdgeOutputContractRef{
		ContractId: "serviceradar.sweep.observation", ContractVersion: 1,
		ContractBundleSha256: digest32(0x40), RegistryEpoch: 7, RegistrySnapshotSha256: digest32(0x50), EffectiveGrantSha256: digest32(0x60),
	}
	pctx := &edgev1.EdgeProducerContext{
		OriginKind: edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT, OriginPrincipalId: []byte("agent-0"),
		ProducerInstanceId: uuidv7(0x71), ProducerAssignmentId: uuidv7(0x72), RunId: uuidv7(0x73), RunShard: 3,
		AuthorityEpoch: proto.Uint64(5), ScopeId: uuidv7(0x74), ScopeSha256: digest32(0x75),
		PackageId: "serviceradar.core.sweep", PackageSha256: digest32(0x76),
	}
	r := &edgev1.EdgeRecordV1{
		EventId: uuidv7(0x10), PayloadFamily: edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		Compression: edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
		EncodedSize: uint32(len(payload)), UncompressedSize: uint32(len(payload)), PayloadSha256: sum[:],
		OutputContract:    contract,
		ProducerContext:   pctx,
		RouteProfile:      edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:      edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		NetworkScopeId:    scope,
		ProjectedRowCount: 3, ProjectedWriteBytes: 2048, CostModelVersion: 2, Payload: payload,
	}
	r.ProductionCapability = productionCap(r)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(r, ctx, scopeID), ContextId: ctx, ScopeId: scopeID, ScopeSha256: sweepRangeSha(),
	}
	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
	return r
}

func golden(t *testing.T, name string, m proto.Message) []byte {
	t.Helper()
	return goldenBytes(t, name, mustMarshal(m))
}

func goldenBytes(t *testing.T, name string, b []byte) []byte {
	t.Helper()
	path := filepath.Join("testdata", name)
	if os.Getenv("EDGE_GOLDEN_UPDATE") != "" {
		_ = os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(path, b, 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		return b
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read committed %s (regenerate with EDGE_GOLDEN_UPDATE=1): %v", name, err)
	}
	if !bytes.Equal(want, b) {
		t.Fatalf("%s drifted from committed fixture; regenerate with EDGE_GOLDEN_UPDATE=1", name)
	}
	return want
}

func TestGoldenRecordAndDelivery(t *testing.T) {
	record := canonicalRecord(t)
	if err := edgerecord.ValidateRecord(record); err != nil {
		t.Fatalf("canonical record must validate: %v", err)
	}
	// Composed signed + envelope<->body join must accept the canonical sweep record
	// under its registered contract and current authority.
	if err := edgerecord.ValidateSweepRecord(record, record.GetOutputContract(), goldenPolicy()); err != nil {
		t.Fatalf("canonical sweep record must join: %v", err)
	}
	rb := golden(t, "record.bin", record)

	// Export issuer public keys + verify every capability signature (rotation).
	goldenBytes(t, "issuer_key_a.pub", issuerPrivA.Public().(ed25519.PublicKey))
	goldenBytes(t, "issuer_key_b.pub", issuerPrivB.Public().(ed25519.PublicKey))
	if err := edgerecord.VerifyCapabilitySignature(record.GetProductionCapability(),
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, issuerPrivA.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("production signature: %v", err)
	}
	if err := edgerecord.VerifyCapabilitySignature(record.GetSourceAuthorization().GetCapability(),
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE, issuerPrivB.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("source signature: %v", err)
	}
	// Export the production AND source signing-byte vectors so Elixir can prove
	// signing parity for every claim role (delivery is exported below).
	goldenBytes(t, "production_signing_bytes.bin", edgerecord.CapabilitySigningBytes(record.GetProductionCapability()))
	goldenBytes(t, "source_signing_bytes.bin", edgerecord.CapabilitySigningBytes(record.GetSourceAuthorization().GetCapability()))

	// Record with source authorization ABSENT: a distinct semantic identity (the
	// source_authorization presence marker flips) that Elixir recomputes independently.
	noSrc := proto.Clone(record).(*edgev1.EdgeRecordV1)
	noSrc.SourceAuthorization = nil
	noSrc.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(noSrc)
	golden(t, "record_no_source.bin", noSrc)

	ms, err := edgerecord.UUIDv7Millis(record.GetEventId())
	if err != nil || ms != fixedMillis {
		t.Fatalf("event-id time = %d (%v), want %d", ms, err, fixedMillis)
	}
	sum := sha256.Sum256(rb)
	spool := uuidv7(0x01)
	frame := &edgev1.EdgeDeliveryFrameV1{
		SpoolId: spool, Sequence: 1, RecordSha256: sum[:], RecordBytes: rb,
		DeliveryCapability: deliveryCap(record, spool, 1),
	}
	golden(t, "delivery_frame.bin", frame)
	if err := edgerecord.ValidateDeliveryFrame(frame, true); err != nil {
		t.Fatalf("delivery frame must validate: %v", err)
	}

	// Raw delivery claim frames both peers recompute: the ROLLOVER transition (carried
	// in the frame above) and a RENEWAL transition -- the two delivery-oneof members,
	// where the field-framed grammar is most likely to drift across languages.
	goldenBytes(t, "delivery_signing_bytes.bin", edgerecord.CapabilitySigningBytes(frame.GetDeliveryCapability()))
	renewalCap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
			EventId: record.GetEventId(), RecordSha256: sum[:], SpoolId: spool, Sequence: 1,
			Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
				RenewedNotBeforeUnixNano: winNotBefore, RenewedExpiresUnixNano: winExpires,
			}},
		}},
	}
	edgerecord.SignCapability(renewalCap, issuerPrivA)
	golden(t, "delivery_renewal_cap.bin", renewalCap)
	goldenBytes(t, "delivery_renewal_signing_bytes.bin", edgerecord.CapabilitySigningBytes(renewalCap))
}

func TestGoldenSessionAck(t *testing.T) {
	nonce := uuidv7(0x02)
	golden(t, "client_lane_open.bin", &edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: &edgev1.EdgeRecordLaneOpen{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:      uuidv7(0x01), SequenceBase: 1, FirstUnresolvedSequence: 1, SessionNonce: nonce,
		RequestedByteCredits: 1 << 20, RequestedFrameCredits: 256,
	}}})
	golden(t, "server_lane_open_ack.bin", &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: &edgev1.EdgeRecordLaneOpenAck{
		SpoolId: uuidv7(0x01), SessionNonce: nonce, GrantedByteCredits: 1 << 20, GrantedFrameCredits: 256,
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
	}}})
	ack := &edgev1.EdgeDeliveryAckV1{
		SpoolId: uuidv7(0x01), ResolvedThroughSequence: 1, SessionNonce: nonce,
		Dispositions: []*edgev1.EdgeRecordDisposition{{Sequence: 1, EventId: uuidv7(0x10), Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}},
	}
	golden(t, "server_ack.bin", &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: ack}})
	// The committed ack must validate under the explicit-disposition reclamation
	// model against the session state that produced it.
	sess := edgerecord.Session{
		SpoolID: uuidv7(0x01), Nonce: nonce, NextSequence: 2, HighestSent: 1, ResolvedThrough: 0,
		SentEvents: map[uint64][]byte{1: uuidv7(0x10)},
	}
	if err := edgerecord.ValidateAck(ack, sess, 64, 4096); err != nil {
		t.Fatalf("golden ack must validate: %v", err)
	}

	// A RETRYABLE-TAIL ack: seq 1 resolves (accepted-authoritative), seq 2 is
	// rejected-retryable (WOULD_BLOCK) and does NOT advance resolved_through. Committed
	// so the Elixir peer proves its encoder authors byte-identical wire bytes that Go
	// decodes and validates; the accept-only server_ack.bin no longer covers kind 5.
	e1, e2 := uuidv7(0x10), uuidv7(0x11)
	retryAck := &edgev1.EdgeDeliveryAckV1{
		SpoolId: uuidv7(0x01), ResolvedThroughSequence: 1, SessionNonce: nonce,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 1, EventId: e1, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
			{Sequence: 2, EventId: e2, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: "WOULD_BLOCK"},
		},
	}
	golden(t, "server_ack_retryable.bin", &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: retryAck}})
	retrySess := edgerecord.Session{
		SpoolID: uuidv7(0x01), Nonce: nonce, NextSequence: 3, HighestSent: 2, ResolvedThrough: 0,
		SentEvents: map[uint64][]byte{1: e1, 2: e2},
	}
	if err := edgerecord.ValidateAck(retryAck, retrySess, 64, 4096); err != nil {
		t.Fatalf("golden retryable-tail ack must validate: %v", err)
	}
}

func TestGoldenLifecycleAndRecovery(t *testing.T) {
	// Completed terminal with a COMPUTED O(N) MTR completion root over the full
	// ordinal set {1,2} bound to the plan root.
	planRoot := digest32(0x92)
	leaves := []edgerecord.MtrCompletionLeaf{
		{Ordinal: 1, Disposition: edgerecord.MtrDispositionTraceAllocated, TraceID: uuidv7(0x30), RangeSha256: digest32(0x93)},
		{Ordinal: 2, Disposition: edgerecord.MtrDispositionNotAdmitted, RangeSha256: digest32(0x93)},
	}
	// The plan commits the (ordinal, range) assignment; completion proves membership
	// against it.
	commitment := edgerecord.MtrOrdinalRangeCommitment(leaves)
	completion, err := edgerecord.MtrCompletionRoot(leaves, 2, planRoot, commitment)
	if err != nil {
		t.Fatalf("completion root: %v", err)
	}
	golden(t, "lifecycle.bin", &edgev1.SweepExecutionEventV1{
		ExecutionId: uuidv7(0x20), ExecutionShard: 3, AssignmentEpoch: 5,
		Kind:              edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano: fixedNanos, TerminalBatchSequence: 4, DurableThroughBatchSequence: 4,
		HostsObserved: 100, HostsAvailable: 60,
		ExpectedMtrSummaries: 2, EmittedMtrSummaries: 2, ExpectedMtrTraces: 2, EmittedMtrTraces: 1,
		MtrCompletionDigestVersion: edgerecord.MtrCompletionDigestVersion,
		MtrCompletionDigest:        completion,
		PlanRootSha256:             planRoot, RangeRootSha256: digest32(0x93),
	})

	rid := uuidv7(0x80)
	page := &edgev1.EdgeLossManifestPageV1{
		RecoveryId: rid, PageIndex: 0, PageCount: 1, Terminal: true, DigestVersion: edgerecord.RecoveryDigestVersion,
		LostRanges: []*edgev1.EdgeLostRangeV1{{FromSequence: 10, ThroughSequence: 20}},
		Affected: []*edgev1.EdgeAffectedScopeV1{{
			FromSequence: 10, ThroughSequence: 20, ContractBundleSha256: digest32(0x40),
			ProducerAssignmentId: uuidv7(0x72), RunId: uuidv7(0x73), RunShard: 3, AuthorityEpoch: 5,
			ScopeSha256: digest32(0x84), RangeSha256: digest32(0x85),
		}},
	}
	page.PageSha256 = edgerecord.ManifestPageDigest(page)
	pages := []*edgev1.EdgeLossManifestPageV1{page}
	root := edgerecord.ManifestRoot(pages)
	golden(t, "manifest_page.bin", page)

	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: uuidv7(0x01), NewSpoolId: uuidv7(0x82),
		LostFromSequence: 10, LostThroughSequence: 20, ManifestRootSha256: root, ManifestPageCount: 1,
		DetectedAtUnixNano: fixedNanos, Reason: "torn-tail", DigestVersion: edgerecord.RecoveryDigestVersion,
	}
	golden(t, "tombstone.bin", tomb)
	if err := edgerecord.ValidateTombstone(tomb, pages); err != nil {
		t.Fatalf("tombstone must validate against its pages: %v", err)
	}

	resolved := &edgev1.RecoveryResolvedV1{RecoveryId: rid, ManifestRootSha256: root, AppliedThroughSequence: 20, ResolvedAtUnixNano: fixedNanos}
	golden(t, "recovery_resolved.bin", resolved)

	// Recovery-operation SCOPE digests (a signed recovery source grant's scope_sha256
	// MUST equal one of these). Cross-language vectors: the Elixir peer recomputes each
	// from the decoded body and byte-compares.
	goldenBytes(t, "manifest_page_scope.bin", edgerecord.ManifestPageScopeDigest(page))
	goldenBytes(t, "tombstone_scope.bin", edgerecord.TombstoneScopeDigest(tomb))
	goldenBytes(t, "resolved_scope.bin", edgerecord.ResolvedScopeDigest(resolved))
}

func TestGoldenPlan(t *testing.T) {
	planID := uuidv7(0xA0)
	checkSet := digest32(0x77)
	r := &edgev1.TargetRangeV1{RangeId: uuidv7(0xA1), Cidr: "10.0.0.0/24", TargetCount: 256, CheckSetSha256: checkSet, AvailabilityPolicyId: []byte("policy-1"), MtrAdmissionBudget: 8}
	r.RangeSha256 = edgerecord.RangeDigest(r)
	page := &edgev1.ScheduledPlanPageV1{ExecutionPlanId: planID, PageIndex: 0, PageCount: 1, CheckSetSha256: checkSet, DigestVersion: edgerecord.PlanDigestVersion, Ranges: []*edgev1.TargetRangeV1{r}}
	page.PageSha256 = edgerecord.PlanPageDigest(page)
	pages := []*edgev1.ScheduledPlanPageV1{page}
	h := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: planID, PageCount: 1, TotalTargetCount: 256, PlanRootSha256: edgerecord.PlanRoot(pages),
		DigestVersion: edgerecord.PlanDigestVersion, CheckSetSha256: checkSet, AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: uuidv7(0x11),
	}
	h.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(h)
	golden(t, "plan_header.bin", h)
	golden(t, "plan_page.bin", page)
	if err := edgerecord.ValidatePlanHeader(h); err != nil {
		t.Fatalf("plan header: %v", err)
	}
	if err := edgerecord.ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("plan pages: %v", err)
	}
}

func TestGoldenMtr(t *testing.T) {
	golden(t, "sweep_batch.bin", canonicalSweepBatch())
	batch := &edgev1.MtrTraceBatchV1{
		NetworkScopeId: uuidv7(0x11), AgentId: uuidv7(0x90), Source: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, BatchSequence: 1,
		Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: uuidv7(0x32)}},
		Traces: []*edgev1.MtrTraceEventV1{{
			TraceId: uuidv7(0x30), EventId: uuidv7(0x31), SweepHostAddress: []byte{10, 0, 0, 9}, Outcome: edgev1.MtrOutcome_MTR_OUTCOME_REACHED, Target: "10.0.0.9", Attempted: true, TargetReached: true, TotalHops: 1, ObservedAtUnixNano: fixedNanos, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP, IpVersion: 4,
			Hops: []*edgev1.MtrTraceHopV1{{HopNumber: 1, Address: []byte{10, 0, 0, 254}, Sent: 3, Received: 3, AvgMicro: proto.Uint64(1200), JitterMicro: proto.Uint64(50), JitterWorstMicro: proto.Uint64(180), JitterInterarrivalMicro: proto.Uint64(40)}},
		}},
	}
	golden(t, "mtr_batch.bin", batch)
	if err := edgerecord.ValidateMtrTraceBatch(batch); err != nil {
		t.Fatalf("mtr batch: %v", err)
	}
	if err := edgerecord.ValidateSweepObservationBatch(canonicalSweepBatch()); err != nil {
		t.Fatalf("sweep batch: %v", err)
	}
}

func TestPresenceZeroVersusAbsent(t *testing.T) {
	zero := &edgev1.SweepHostObservationV1{FirstSeenDeltaNano: proto.Int64(0)}
	absent := &edgev1.SweepHostObservationV1{}
	zb, _ := proto.Marshal(zero)
	ab, _ := proto.Marshal(absent)
	var gz, ga edgev1.SweepHostObservationV1
	_ = proto.Unmarshal(zb, &gz)
	_ = proto.Unmarshal(ab, &ga)
	if gz.FirstSeenDeltaNano == nil || *gz.FirstSeenDeltaNano != 0 {
		t.Fatal("present-zero first_seen_delta_nano must survive")
	}
	if ga.FirstSeenDeltaNano != nil {
		t.Fatal("absent first_seen_delta_nano must remain absent")
	}
}
