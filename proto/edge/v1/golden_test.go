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
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
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
	// PURPOSE-SCOPED: an entry may name the role it is authorized for as "issuer|key|purpose".
	// A bare "issuer|key" entry stays role-agnostic for the record-plane fixtures that predate
	// role separation; the assignment fixtures use the scoped form so a scheduler key cannot
	// mint a host execution grant.
	if pub, ok := m[string(issuerID)+"|"+string(keyID)+"|"+ev.Purpose.String()]; ok {
		return edgerecord.KeyResolution{Status: edgerecord.KeyValid, Public: pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
	}
	if pub, ok := m[string(issuerID)+"|"+string(keyID)]; ok {
		return edgerecord.KeyResolution{Status: edgerecord.KeyValid, Public: pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
	}
	return edgerecord.KeyResolution{Status: edgerecord.KeyInvalid, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
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

// uuidv7At builds a canonical UUIDv7 carrying an EXPLICIT millisecond timestamp, so a
// vector can place a trace time outside the signed window or above the ns-conversion
// ceiling. `uuidv7` always carries `fixedMillis` and cannot express either case.
func uuidv7At(millis int64) []byte {
	// The tail seed is fixed: these vectors vary the TIMESTAMP, and a second varying input
	// would make a failure ambiguous about which one moved.
	const seed = 0x30

	out := make([]byte, 16)
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], uint64(millis)<<16)
	copy(out[0:6], tsb[0:6])
	for i := 6; i < 16; i++ {
		out[i] = seed + byte(i)
	}
	out[6] = (out[6] & 0x0F) | 0x70
	out[8] = (out[8] & 0x3F) | 0x80

	return out
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

// renewalDeliveryCap builds a DELIVERY capability whose transition is a RENEWAL (not the
// ROLLOVER that deliveryCap builds). A RENEWAL transport-provenance proof MUST hash a renewal
// capability, so the two builders are kept distinct.
func renewalDeliveryCap(record *edgev1.EdgeRecordV1, spool []byte, seq uint64) *edgev1.EdgeSignedCapabilityV1 {
	sum := sha256.Sum256(mustMarshal(record))
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
			EventId: record.GetEventId(), RecordSha256: sum[:], SpoolId: spool, Sequence: seq,
			Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
				RenewedNotBeforeUnixNano: winNotBefore, RenewedExpiresUnixNano: winExpires,
			}},
		}},
	}
	edgerecord.SignCapability(cap, issuerPrivA)
	return cap
}

// signDeliveryCap builds + signs a DELIVERY capability with the given (possibly malformed)
// transition, binding valid base claim fields, so tests can exercise the delivery-claim validator.
func signDeliveryCap(record *edgev1.EdgeRecordV1, spool []byte, seq uint64, claims *edgev1.EdgeDeliveryClaimsV1) *edgev1.EdgeSignedCapabilityV1 {
	sum := sha256.Sum256(mustMarshal(record))
	claims.EventId, claims.RecordSha256, claims.SpoolId, claims.Sequence = record.GetEventId(), sum[:], spool, seq
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: claims},
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
		// SCHEDULED_CHECK REQUIRES source_run_id and selects it as the signed
		// context operand. It is deliberately DIFFERENT from execution_id (0x20):
		// were the two equal, this fixture would pass under either operand rule
		// and prove nothing about which one the join selected.
		SourceRunId:        uuidv7(0x23),
		ConfiguredModeBits: uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR),
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
	// The context operand is the one THIS SOURCE selects: SCHEDULED_CHECK selects
	// source_run_id, not execution_id.
	ctx, scopeID := batch.GetSourceRunId(), batch.GetTargetRangeId()
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

// goldenText is `golden` for a TEXT manifest: the shared corpus carries its expectations
// beside the bytes so the other runtime derives them instead of restating them.
func goldenText(t *testing.T, name, body string) {
	t.Helper()
	goldenBytes(t, name, []byte(body))
}

// mustStr unwraps a validated (string, error) encoder in a golden context. A validated encoder
// rejecting known-good golden input is a test bug, so it panics (aborting the golden run).
func mustStr(s string, err error) string {
	if err != nil {
		panic("publication-identity encoder rejected valid golden input: " + err.Error())
	}
	return s
}

// mustBytes unwraps a validated ([]byte, error) preimage in a golden context.
func mustBytes(b []byte, err error) []byte {
	if err != nil {
		panic("publication-identity preimage rejected valid golden input: " + err.Error())
	}
	return b
}

// padToLen pads encoded page bytes to exactly target with DECODABLE filler: repeated
// copies of the singular digest_version field (tag 8, varint), which protobuf resolves
// last-one-wins to the value already present. An ODD byte count uses one 3-byte
// NON-MINIMAL varint. Trailing zero bytes do NOT work -- protobuf rejects tag 0, so a
// zero-padded page fails to decode and never reaches the budget check at all.
func padToLen(t *testing.T, b []byte, target int) []byte {
	t.Helper()
	need := target - len(b)
	if need < 0 {
		t.Fatalf("page is already %d bytes, over target %d", len(b), target)
	}
	out := append([]byte{}, b...)
	if need%2 == 1 {
		if need < 3 {
			t.Fatalf("cannot pad %d bytes", need)
		}
		out = append(out, 0x40, 0x81, 0x00)
		need -= 3
	}
	for ; need > 0; need -= 2 {
		out = append(out, 0x40, 0x01)
	}
	return out
}

// mustValidateLifecycleBytes decodes the EXACT committed fixture bytes and runs the
// real validator over them. Building a message in memory and validating THAT proves
// nothing about what is on disk; a fixture the validator rejects is dead weight,
// because every consumer validates before it reaches the completion proof.
func mustValidateLifecycleBytes(t *testing.T, name string, b []byte) {
	t.Helper()
	var ev edgev1.SweepExecutionEventV1
	if err := proto.Unmarshal(b, &ev); err != nil {
		t.Fatalf("%s: decode: %v", name, err)
	}
	if err := edgerecord.ValidateSweepExecutionEvent(&ev); err != nil {
		t.Fatalf("%s: committed bytes must be a VALID event: %v", name, err)
	}
}

// padWithDuplicateKnownField grows a marshalled page to an exact size by repeating a
// KNOWN field whose value is unchanged by last-one-wins -- `page_index = 0` on page 0.
// Padding with unknown fields would be rejected as retained unknowns and would prove
// nothing about the SIZE boundary; duplicates of a known field are exactly the shape
// that collapses on a re-marshal, which is why the received-bytes rule exists.
func padWithDuplicateKnownField(t *testing.T, b []byte, target int) []byte {
	t.Helper()
	out := append([]byte(nil), b...)
	// tag 2 (page_index), varint wire type: 0x10 0x00 is the minimal encoding of 0.
	minimal := []byte{0x10, 0x00}
	// A NON-MINIMAL encoding of the same 0, one byte longer, for odd remainders.
	nonMinimal := []byte{0x10, 0x80, 0x00}
	for target-len(out) >= 2 {
		if (target-len(out))%2 == 1 {
			out = append(out, nonMinimal...)
			continue
		}
		out = append(out, minimal...)
	}
	if len(out) != target {
		t.Fatalf("could not pad to %d, reached %d", target, len(out))
	}
	return out
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

// TestGoldenPoisonNegativeEnum exports a protobuf-valid capability carrying an UNMAPPED negative
// enum (production traffic_class = -1). Go marshals it and RETAINS the unknown value on decode,
// rejecting it later in the explicit semantic validator. The Elixir generated enums are patched
// (scripts/patch_edge_enum_negatives.exs) to retain it the same way instead of raising, so the two
// runtimes now agree: the value DECODES and `ServiceRadar.Edge.SemanticValidate` rejects it as a
// permanent rejection with the stage-correct disposition -- not a decode-time poison/quarantine.
// (The fixture name predates that change; it is kept so the committed vector stays stable.)
func TestGoldenPoisonNegativeEnum(t *testing.T) {
	poison := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: uuidv7(0xC0), IssuerKeyId: uuidv7(0xC1), Algorithm: "ed25519",
		NotBeforeUnixNano: winNotBefore, ExpiresAtUnixNano: winExpires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			TrafficClass: edgev1.EdgeRecordTrafficClass(-1),
		}},
	}
	raw := goldenBytes(t, "poison_negative_enum.bin", mustMarshal(poison))
	// Go retains the unknown enum: the bytes round-trip without error and the value is preserved.
	var rt edgev1.EdgeSignedCapabilityV1
	if err := proto.Unmarshal(raw, &rt); err != nil {
		t.Fatalf("Go must retain the unknown enum, not reject it: %v", err)
	}
	if rt.GetProduction().GetTrafficClass() != edgev1.EdgeRecordTrafficClass(-1) {
		t.Fatalf("Go dropped the unknown enum value: %v", rt.GetProduction().GetTrafficClass())
	}

	// P0-faithful variant: the ACTUAL gRPC request type on EdgeRecordIngestService.Stream is
	// EdgeRecordClientMessage (a lane_open / delivery_frame oneof). gRPC's generated codec decodes
	// the WHOLE client message -- including lane_open.traffic_class -- BEFORE any application handler
	// runs, so a negative enum here crashes the transport unless a pre-handler raw codec routes the
	// raw bytes through WireDecode.decode_client_message first. Go retains it; Elixir must quarantine.
	poisonMsg := &edgev1.EdgeRecordClientMessage{
		Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: &edgev1.EdgeRecordLaneOpen{
			TrafficClass: edgev1.EdgeRecordTrafficClass(-1),
		}},
	}
	rawMsg := goldenBytes(t, "poison_client_message_negative_enum.bin", mustMarshal(poisonMsg))
	var rtMsg edgev1.EdgeRecordClientMessage
	if err := proto.Unmarshal(rawMsg, &rtMsg); err != nil {
		t.Fatalf("Go must retain the unknown enum in the client message: %v", err)
	}
	if rtMsg.GetLaneOpen().GetTrafficClass() != edgev1.EdgeRecordTrafficClass(-1) {
		t.Fatalf("Go dropped the client-message enum value: %v", rtMsg.GetLaneOpen().GetTrafficClass())
	}
}

// TestGoldenPublicationIdentity exports the grammar 6-8 publication-identity headers
// (Nats-Msg-Id, Sr-Edge-Delivery-Id, Sr-Edge-Transport-Provenance -- edge and
// service-ingress variants, delivery-proof present and absent) so the Elixir peer
// (ServiceRadar.Edge.PublicationIdentity) can prove byte-identical header derivation.
func TestGoldenPublicationIdentity(t *testing.T) {
	record := canonicalRecord(t)
	rb := mustMarshal(record)
	sum := sha256.Sum256(rb)
	recordSha := sum[:]
	sed := record.GetSemanticEnvelopeSha256()

	// The authenticated principal is the record's OWN producer_context.origin_principal_id --
	// a case-sensitive ASCII component-id ([A-Za-z0-9_-], 1..128), the ONLY origin input.
	// There is no separate origin-principal argument and no lane_id: the spool_id is the
	// persistent UUIDv7 for one delivery lane. Sourcing it from the record proves the frozen
	// equality (decision 5) instead of re-inventing a value.
	agent := record.GetProducerContext().GetOriginPrincipalId()
	if err := edgerecord.ValidateAuthenticatedPrincipal(agent); err != nil {
		t.Fatalf("record origin principal must be a valid authenticated principal: %v", err)
	}
	slot := edgerecord.EdgeSlot{
		NetworkScopeID: record.GetNetworkScopeId(), AuthenticatedAgentID: agent,
		SpoolID: uuidv7(0x01), Sequence: 1,
	}
	msgID := mustStr(edgerecord.NatsMsgID(slot, sed, recordSha))
	delID := mustStr(edgerecord.DeliveryID(slot))
	goldenBytes(t, "nats_msg_id.txt", []byte(msgID))
	goldenBytes(t, "delivery_id.txt", []byte(delID))
	// Raw grammar preimages (the framed transcript, pre-SHA-256) so Elixir proves the framed
	// bytes match, not merely the resulting digest.
	goldenBytes(t, "nats_msg_id_preimage.bin", mustBytes(edgerecord.NatsMsgIDPreimage(slot, sed, recordSha)))
	goldenBytes(t, "delivery_id_preimage.bin", mustBytes(edgerecord.DeliveryIDPreimage(slot)))

	// Transport provenance for a RENEWAL: exactly one 32-byte delivery proof present, hashing
	// a RENEWAL delivery capability whose transition matches the claimed mode.
	renewalProof, err := edgerecord.DeliveryProofDigest(renewalDeliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeRenewal)
	if err != nil {
		t.Fatalf("renewal delivery proof: %v", err)
	}
	// A RENEWAL proof that hashes a ROLLOVER capability MUST be rejected (mode/transition mismatch).
	if _, err := edgerecord.DeliveryProofDigest(deliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeRenewal); err == nil {
		t.Fatal("RENEWAL proof over a ROLLOVER capability must be rejected")
	}
	// Malformed SIGNED delivery claims MUST be rejected before a proof is minted (the same complete
	// delivery-claim validator frame admission uses): a mis-ordered renewal window, and a rollover
	// with a malformed prior_spool_id and prior_sequence=0.
	badRenewal := signDeliveryCap(record, slot.SpoolID, slot.Sequence, &edgev1.EdgeDeliveryClaimsV1{
		Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{RenewedNotBeforeUnixNano: 9, RenewedExpiresUnixNano: 2}},
	})
	if _, err := edgerecord.DeliveryProofDigest(badRenewal, edgerecord.DeliveryModeRenewal); err == nil {
		t.Fatal("renewal proof over a mis-ordered window must be rejected")
	}
	badRollover := signDeliveryCap(record, slot.SpoolID, slot.Sequence, &edgev1.EdgeDeliveryClaimsV1{
		Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{RecoveryId: uuidv7(0x86), PriorSpoolId: []byte("not-a-uuid"), PriorSequence: 0}},
	})
	if _, err := edgerecord.DeliveryProofDigest(badRollover, edgerecord.DeliveryModeRollover); err == nil {
		t.Fatal("rollover proof over malformed prior_spool_id/prior_sequence must be rejected")
	}
	// A SAME-SPOOL rollover (prior_spool_id == spool_id) is invalid -- a rollover moves to a NEW spool.
	sameSpoolRollover := signDeliveryCap(record, slot.SpoolID, slot.Sequence, &edgev1.EdgeDeliveryClaimsV1{
		Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{RecoveryId: uuidv7(0x86), PriorSpoolId: slot.SpoolID, PriorSequence: 42}},
	})
	if _, err := edgerecord.DeliveryProofDigest(sameSpoolRollover, edgerecord.DeliveryModeRollover); err == nil {
		t.Fatal("same-spool rollover proof (prior_spool_id == spool_id) must be rejected")
	}
	renewalIn := edgerecord.TransportProvenanceInput{
		Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeRenewal,
		DeliveryProof: renewalProof, RouteMapVersion: 7,
	}
	prov := mustStr(edgerecord.TransportProvenance(renewalIn))
	goldenBytes(t, "transport_provenance.txt", []byte(prov))
	goldenBytes(t, "transport_provenance_preimage.bin", mustBytes(edgerecord.TransportProvenancePreimage(renewalIn)))

	// FRESH record: no delivery proof (the presence byte marks its absence).
	provFresh := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{
		Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 7,
	}))
	goldenBytes(t, "transport_provenance_fresh.txt", []byte(provFresh))

	// ROLLOVER and LATE_FENCED_DELIVERY: both carry a 32-byte proof over a ROLLOVER capability.
	rolloverProof, err := edgerecord.DeliveryProofDigest(deliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeRollover)
	if err != nil {
		t.Fatalf("rollover delivery proof: %v", err)
	}
	provRollover := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{
		Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeRollover,
		DeliveryProof: rolloverProof, RouteMapVersion: 7,
	}))
	goldenBytes(t, "transport_provenance_rollover.txt", []byte(provRollover))
	lateProof, err := edgerecord.DeliveryProofDigest(deliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeLateFenced)
	if err != nil {
		t.Fatalf("late-fenced delivery proof: %v", err)
	}
	provLate := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{
		Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeLateFenced,
		DeliveryProof: lateProof, RouteMapVersion: 7,
	}))
	goldenBytes(t, "transport_provenance_late.txt", []byte(provLate))

	// Values above 2^32 in sequence and route_map_version must round-trip losslessly (u64,
	// never truncated to 32 bits). This is the parity vector for the Elixir <<v::big-64>> guard.
	bigSlot := slot
	bigSlot.Sequence = 0x1_0000_0000_0007
	provBig := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{
		Edge: &bigSlot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh,
		RouteMapVersion: 0x1_0000_0000_0003,
	}))
	goldenBytes(t, "transport_provenance_bigvals.txt", []byte(provBig))

	// A LATE_FENCED_DELIVERY proof may hash EITHER a renewal or a rollover delivery grant (the
	// spec pins it to a fence outcome under a valid grant, not to a transition).
	if _, err := edgerecord.DeliveryProofDigest(renewalDeliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeLateFenced); err != nil {
		t.Fatalf("late-fenced proof over a RENEWAL grant must be accepted: %v", err)
	}

	// Service-ingress variants -- generated from an ACTUAL CLUSTER_SERVICE record (its own
	// origin_kind, principal, semantic digest and hash), NOT the agent record. The service
	// principal is the service record's own origin_principal_id.
	svcRecord := serviceRecord(t)
	svcRb := golden(t, "service_record.bin", svcRecord)
	svcSum := sha256.Sum256(svcRb)
	svcRecordSha := svcSum[:]
	svcSed := svcRecord.GetSemanticEnvelopeSha256()
	svcID := svcRecord.GetProducerContext().GetOriginPrincipalId()
	if err := edgerecord.ValidateAuthenticatedPrincipal(svcID); err != nil {
		t.Fatalf("service record origin principal: %v", err)
	}
	svc := edgerecord.ServiceSlot{
		NetworkScopeID: svcRecord.GetNetworkScopeId(), AuthenticatedServiceID: svcID,
		PublicationLaneID: uuidv7(0xB1), PublicationSequence: 5,
	}
	svcMsg := mustStr(edgerecord.ServiceNatsMsgID(svc, svcSed, svcRecordSha))
	svcDel := mustStr(edgerecord.ServiceDeliveryID(svc))
	goldenBytes(t, "service_nats_msg_id.txt", []byte(svcMsg))
	goldenBytes(t, "service_delivery_id.txt", []byte(svcDel))
	goldenBytes(t, "service_nats_msg_id_preimage.bin", mustBytes(edgerecord.ServiceNatsMsgIDPreimage(svc, svcSed, svcRecordSha)))
	goldenBytes(t, "service_delivery_id_preimage.bin", mustBytes(edgerecord.ServiceDeliveryIDPreimage(svc)))
	svcIn := edgerecord.TransportProvenanceInput{
		Service: &svc, RecordSha256: svcRecordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 7,
	}
	provSvc := mustStr(edgerecord.TransportProvenance(svcIn))
	goldenBytes(t, "service_transport_provenance.txt", []byte(provSvc))
	goldenBytes(t, "service_transport_provenance_preimage.bin", mustBytes(edgerecord.TransportProvenancePreimage(svcIn)))

	// Encoder input validation (fail closed): zero sequence, invalid principal, non-16-byte
	// UUID, non-32-byte digest, wrong slot arity, service non-FRESH, zero route-map.
	badSlot := slot
	badSlot.Sequence = 0
	if _, err := edgerecord.NatsMsgID(badSlot, sed, recordSha); err == nil {
		t.Fatal("zero sequence must be rejected")
	}
	badPrin := slot
	badPrin.AuthenticatedAgentID = []byte("bad id!")
	if _, err := edgerecord.DeliveryID(badPrin); err == nil {
		t.Fatal("invalid principal must be rejected")
	}
	badUUID := slot
	badUUID.SpoolID = []byte("short")
	if _, err := edgerecord.DeliveryID(badUUID); err == nil {
		t.Fatal("non-16-byte spool_id must be rejected")
	}
	if _, err := edgerecord.NatsMsgID(slot, sed[:16], recordSha); err == nil {
		t.Fatal("non-32-byte semantic-envelope digest must be rejected")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Edge: &slot, Service: &svc, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 7}); err == nil {
		t.Fatal("both slots set must error")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 7}); err == nil {
		t.Fatal("neither slot set must error")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Service: &svc, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeRenewal, DeliveryProof: renewalProof, RouteMapVersion: 7}); err == nil {
		t.Fatal("service-ingress non-FRESH must error")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 0}); err == nil {
		t.Fatal("zero route_map_version must error")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, DeliveryProof: renewalProof, RouteMapVersion: 7}); err == nil {
		t.Fatal("FRESH with a delivery proof must error")
	}
	if _, err := edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeRenewal, RouteMapVersion: 7}); err == nil {
		t.Fatal("non-FRESH without a delivery proof must error")
	}
	if len(prov) > edgerecord.MaxTransportProvenanceHeaderBytes || len(provSvc) > edgerecord.MaxTransportProvenanceHeaderBytes {
		t.Fatal("provenance header exceeds the 512-byte bound")
	}
}

// TestPublicationIdentityCodec proves the strict DECODER and the EventWriter header-set
// validator: every accepted provenance header round-trips (decode -> re-encode == original),
// decoded fields match, ValidateHeaderSet recomputes/cross-checks the whole set, and a battery
// of malformed encodings (unknown version/kind/mode, trailing bytes, non-canonical base64,
// bad presence byte, truncation) is rejected. The reject vectors are also written to a shared
// fixture so the Elixir peer proves an identical strict boundary (bidirectional coverage).
func TestPublicationIdentityCodec(t *testing.T) {
	record := canonicalRecord(t)
	sum := sha256.Sum256(mustMarshal(record))
	recordSha := sum[:]
	sed := record.GetSemanticEnvelopeSha256()
	agent := record.GetProducerContext().GetOriginPrincipalId()
	slot := edgerecord.EdgeSlot{NetworkScopeID: record.GetNetworkScopeId(), AuthenticatedAgentID: agent, SpoolID: uuidv7(0x01), Sequence: 1}

	renewalProof := mustBytes(edgerecord.DeliveryProofDigest(renewalDeliveryCap(record, slot.SpoolID, slot.Sequence), edgerecord.DeliveryModeRenewal))
	renewalIn := edgerecord.TransportProvenanceInput{Edge: &slot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeRenewal, DeliveryProof: renewalProof, RouteMapVersion: 7}
	renewalHdr := mustStr(edgerecord.TransportProvenance(renewalIn))

	// Round-trip: decode -> exact field recovery -> re-encode == original bytes.
	dp, err := edgerecord.DecodeTransportProvenance(renewalHdr)
	if err != nil {
		t.Fatalf("decode renewal: %v", err)
	}
	if dp.Edge == nil || dp.Edge.Sequence != 1 || !bytes.Equal(dp.Edge.AuthenticatedAgentID, agent) {
		t.Fatal("decoded edge slot mismatch")
	}
	if dp.DeliveryMode != edgerecord.DeliveryModeRenewal || !bytes.Equal(dp.DeliveryProof, renewalProof) || dp.RouteMapVersion != 7 {
		t.Fatal("decoded mode/proof/route-map mismatch")
	}
	if !bytes.Equal(dp.RecordSha256, recordSha) {
		t.Fatal("decoded record hash mismatch")
	}
	reHdr := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{
		Edge: dp.Edge, RecordSha256: dp.RecordSha256, DeliveryMode: dp.DeliveryMode, DeliveryProof: dp.DeliveryProof, RouteMapVersion: dp.RouteMapVersion,
	}))
	if reHdr != renewalHdr {
		t.Fatal("decode/re-encode did not round-trip")
	}

	// Big-value round-trip: >2^32 sequence and route-map survive (no 32-bit truncation).
	bigSlot := slot
	bigSlot.Sequence = 0x1_0000_0000_0007
	bigHdr := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Edge: &bigSlot, RecordSha256: recordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 0x1_0000_0000_0003}))
	bdp, err := edgerecord.DecodeTransportProvenance(bigHdr)
	if err != nil {
		t.Fatalf("decode big-values: %v", err)
	}
	if bdp.Edge.Sequence != 0x1_0000_0000_0007 || bdp.RouteMapVersion != 0x1_0000_0000_0003 {
		t.Fatalf("big values truncated: seq=%d rmv=%d", bdp.Edge.Sequence, bdp.RouteMapVersion)
	}

	// Header-set trust binding (edge): recompute + cross-check the whole set against the record-
	// derived context (scope, origin_kind, publisher class, principal). The gateway credential
	// identity DIFFERS from the originating agent BY DESIGN, so TrustedPublisherPrincipal is a
	// gateway id (NOT the agent) and edge validation MUST still pass -- edge trust is the publisher
	// CLASS + per-class subject isolation, never a credential==agent comparison.
	msgID := mustStr(edgerecord.NatsMsgID(slot, sed, recordSha))
	delID := mustStr(edgerecord.DeliveryID(slot))
	hs := edgerecord.HeaderSet{NatsMsgID: msgID, DeliveryID: delID, Provenance: renewalHdr}
	ctx := edgerecord.HeaderTrustContext{
		RecordNetworkScopeID:      record.GetNetworkScopeId(),
		RecordOriginKind:          edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
		RecordPrincipal:           agent,
		ExpectedPublisherClass:    edgerecord.PublisherClassEdge,
		TrustedPublisherPrincipal: []byte("gateway-edge-1"), // gateway credential != agent, on purpose
		SemanticEnvelopeSha256:    sed,
		RecordSha256:              recordSha,
	}
	if err := edgerecord.ValidateHeaderSet(hs, ctx); err != nil {
		t.Fatalf("valid edge header set rejected (gateway credential must not need to equal agent): %v", err)
	}
	// Every trust-context disagreement fails closed -- a self-consistent header set can no longer
	// bind a record to the wrong scope or ingress class.
	bad := func(name string, mutate func(*edgerecord.HeaderSet, *edgerecord.HeaderTrustContext)) {
		h, c := hs, ctx
		mutate(&h, &c)
		if err := edgerecord.ValidateHeaderSet(h, c); err == nil {
			t.Fatalf("%s must be rejected", name)
		}
	}
	bad("tampered msg-id", func(h *edgerecord.HeaderSet, _ *edgerecord.HeaderTrustContext) { h.NatsMsgID = "tampered" })
	bad("tampered delivery-id", func(h *edgerecord.HeaderSet, _ *edgerecord.HeaderTrustContext) { h.DeliveryID = "tampered" })
	bad("record-hash mismatch", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) { c.RecordSha256 = digest32(0xEE) })
	bad("scope mismatch", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) { c.RecordNetworkScopeID = uuidv7(0x99) })
	bad("origin-kind mismatch", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) {
		c.RecordOriginKind = edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_CLUSTER_SERVICE
	})
	bad("publisher-class mismatch", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) {
		c.ExpectedPublisherClass = edgerecord.PublisherClassService
	})
	bad("record-principal mismatch", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) {
		c.RecordPrincipal = []byte("other-agent")
	})
	// NOTE: no edge "publisher-principal mismatch" case -- edge validation deliberately ignores
	// TrustedPublisherPrincipal (the gateway credential is not the agent). The credential-principal
	// binding is asserted service-only below.
	bad("unspecified origin-kind", func(_ *edgerecord.HeaderSet, c *edgerecord.HeaderTrustContext) {
		c.RecordOriginKind = edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_UNSPECIFIED
		c.ExpectedPublisherClass = edgerecord.PublisherClassUnspecified
	})

	// Service header set validated against an ACTUAL service record + its credential identity.
	svcRecord := serviceRecord(t)
	svcSum := sha256.Sum256(mustMarshal(svcRecord))
	svcRecordSha := svcSum[:]
	svcSed := svcRecord.GetSemanticEnvelopeSha256()
	svcID := svcRecord.GetProducerContext().GetOriginPrincipalId()
	svc := edgerecord.ServiceSlot{NetworkScopeID: svcRecord.GetNetworkScopeId(), AuthenticatedServiceID: svcID, PublicationLaneID: uuidv7(0xB1), PublicationSequence: 5}
	svcHdr := mustStr(edgerecord.TransportProvenance(edgerecord.TransportProvenanceInput{Service: &svc, RecordSha256: svcRecordSha, DeliveryMode: edgerecord.DeliveryModeFresh, RouteMapVersion: 7}))
	svcHS := edgerecord.HeaderSet{
		NatsMsgID:  mustStr(edgerecord.ServiceNatsMsgID(svc, svcSed, svcRecordSha)),
		DeliveryID: mustStr(edgerecord.ServiceDeliveryID(svc)),
		Provenance: svcHdr,
	}
	svcCtx := edgerecord.HeaderTrustContext{
		RecordNetworkScopeID:      svcRecord.GetNetworkScopeId(),
		RecordOriginKind:          edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_CLUSTER_SERVICE,
		RecordPrincipal:           svcID,
		ExpectedPublisherClass:    edgerecord.PublisherClassService,
		TrustedPublisherPrincipal: svcID,
		SemanticEnvelopeSha256:    svcSed,
		RecordSha256:              svcRecordSha,
	}
	if err := edgerecord.ValidateHeaderSet(svcHS, svcCtx); err != nil {
		t.Fatalf("valid service header set rejected: %v", err)
	}
	// SERVICE-ONLY credential binding: a credential-derived service identity that disagrees with
	// the record/provenance principal MUST fail (the governed service IS the publisher).
	svcBadCred := svcCtx
	svcBadCred.TrustedPublisherPrincipal = []byte("other-svc")
	if err := edgerecord.ValidateHeaderSet(svcHS, svcBadCred); err == nil {
		t.Fatal("service credential mismatch must be rejected")
	}
	// Service headers validated under the EDGE (agent) context must fail: the class/kind and
	// scope/principal bindings no longer agree.
	if err := edgerecord.ValidateHeaderSet(svcHS, ctx); err == nil {
		t.Fatal("service headers under an agent trust context must be rejected")
	}

	// Raw header multimap boundary: duplicate / case-variant / missing / empty rejected.
	full := func() map[string][]string {
		return map[string][]string{
			edgerecord.HeaderNatsMsgID:  {msgID},
			edgerecord.HeaderDeliveryID: {delID},
			edgerecord.HeaderProvenance: {renewalHdr},
		}
	}
	if _, err := edgerecord.ExtractHeaderSet(full()); err != nil {
		t.Fatalf("valid header multimap rejected: %v", err)
	}
	dup := full()
	dup[edgerecord.HeaderNatsMsgID] = []string{msgID, msgID}
	if _, err := edgerecord.ExtractHeaderSet(dup); err == nil {
		t.Fatal("duplicate header must be rejected")
	}
	caseDup := full()
	caseDup["nats-msg-id"] = []string{msgID}
	if _, err := edgerecord.ExtractHeaderSet(caseDup); err == nil {
		t.Fatal("case-variant duplicate header must be rejected")
	}
	missing := full()
	delete(missing, edgerecord.HeaderProvenance)
	if _, err := edgerecord.ExtractHeaderSet(missing); err == nil {
		t.Fatal("missing header must be rejected")
	}
	if _, err := edgerecord.ExtractHeaderSet(map[string][]string{
		"nats-msg-id": {msgID}, "sr-edge-delivery-id": {delID}, "sr-edge-transport-provenance": {renewalHdr},
	}); err != nil {
		t.Fatalf("case-insensitive header names rejected: %v", err)
	}

	// Malformed decode vectors -- each MUST be rejected. Written to a shared fixture as
	// "label \t std-base64(header)" (so CR/LF and empty headers survive the line format); the
	// label SET is frozen so neither peer can silently drop coverage (bidirectional).
	rejects := malformedProvenanceVectors(t, record)
	gotLabels := make([]string, 0, len(rejects))
	var fixture bytes.Buffer
	for _, v := range rejects {
		if _, err := edgerecord.DecodeTransportProvenance(v.header); err == nil {
			t.Fatalf("malformed vector %q was accepted", v.label)
		}
		gotLabels = append(gotLabels, v.label)
		fixture.WriteString(v.label)
		fixture.WriteByte('\t')
		fixture.WriteString(base64.StdEncoding.EncodeToString([]byte(v.header)))
		fixture.WriteByte('\n')
	}
	if strings.Join(gotLabels, ",") != strings.Join(rejectVectorLabels, ",") {
		t.Fatalf("reject label set drift: got %v want %v", gotLabels, rejectVectorLabels)
	}
	goldenBytes(t, "pubid_reject_vectors.txt", fixture.Bytes())
}

type rejectVector struct {
	label  string
	header string
}

// rejectVectorLabels is the FROZEN malformed-vector label set both peers must cover exactly.
var rejectVectorLabels = []string{ //nolint:gochecknoglobals // frozen shared coverage set
	"cr-lf", "trailing-byte", "truncated", "empty", "bad-base64-char",
	"non-canonical-base64-alias", "unknown-version", "unknown-slot-kind", "unknown-mode",
	"invalid-presence", "zero-route-map", "bad-digest-length", "length-prefix-overflow",
	"service-non-fresh", "oversized",
}

const transportProvenanceDomainForTest = "serviceradar.edge.transport-provenance"

// f{U64,Bytes,Str} and frameProv mirror the digestWriter framing so malformed provenance
// envelopes can be constructed field-by-field, each perturbing exactly one strict-boundary rule.
func fU64(v uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], v)
	return b[:]
}

func fBytes(b []byte) []byte { return append(fU64(uint64(len(b))), b...) }
func fStr(s string) []byte   { return fBytes([]byte(s)) }

func frameProv(version, slotKind uint64, scope, principal, id []byte, seq uint64, recordSha []byte, presence byte, proof []byte, mode, rmv uint64) []byte {
	var b []byte
	b = append(b, fStr(transportProvenanceDomainForTest)...)
	b = append(b, fU64(version)...)
	b = append(b, fU64(slotKind)...)
	b = append(b, fBytes(scope)...)
	b = append(b, fBytes(principal)...)
	b = append(b, fBytes(id)...)
	b = append(b, fU64(seq)...)
	b = append(b, fBytes(recordSha)...)
	b = append(b, presence)
	if proof != nil {
		b = append(b, fBytes(proof)...)
	}
	b = append(b, fU64(mode)...)
	b = append(b, fU64(rmv)...)
	return b
}

// malformedProvenanceVectors builds the frozen battery of invalid transport-provenance headers,
// each exercising exactly one strict-boundary rule.
func malformedProvenanceVectors(t *testing.T, record *edgev1.EdgeRecordV1) []rejectVector {
	t.Helper()
	const fresh, renewal = edgerecord.DeliveryModeFresh, edgerecord.DeliveryModeRenewal
	scope := record.GetNetworkScopeId()
	agent := record.GetProducerContext().GetOriginPrincipalId()
	spool := uuidv7(0x01)
	rshaSum := sha256.Sum256(mustMarshal(record))
	rsha := rshaSum[:]
	proof := digest32(0x07)
	enc := base64.RawURLEncoding.EncodeToString

	// A valid FRESH envelope is the source for structural (non-field) mutations; assert it decodes.
	valid := frameProv(1, 1, scope, agent, spool, 1, rsha, 0x00, nil, fresh, 7)
	if _, err := edgerecord.DecodeTransportProvenance(enc(valid)); err != nil {
		t.Fatalf("base envelope must decode: %v", err)
	}
	// First bytes-field length prefix (network_scope) offset = domain framing + version + kind.
	scopeLenPos := 8 + len(transportProvenanceDomainForTest) + 8 + 8

	crlf := enc(valid)
	crlf = crlf[:20] + "\n" + crlf[20:]

	return []rejectVector{
		{"cr-lf", crlf},
		{"trailing-byte", enc(append(append([]byte{}, valid...), 0x00))},
		{"truncated", enc(valid[:len(valid)-1])},
		{"empty", ""},
		{"bad-base64-char", "++" + enc(valid)},
		{"non-canonical-base64-alias", nonCanonicalBase64(valid)},
		{"unknown-version", enc(frameProv(999, 1, scope, agent, spool, 1, rsha, 0x00, nil, fresh, 7))},
		{"unknown-slot-kind", enc(frameProv(1, 77, scope, agent, spool, 1, rsha, 0x00, nil, fresh, 7))},
		{"unknown-mode", enc(frameProv(1, 1, scope, agent, spool, 1, rsha, 0x00, nil, 99, 7))},
		{"invalid-presence", enc(frameProv(1, 1, scope, agent, spool, 1, rsha, 0x02, nil, fresh, 7))},
		{"zero-route-map", enc(frameProv(1, 1, scope, agent, spool, 1, rsha, 0x00, nil, fresh, 0))},
		{"bad-digest-length", enc(frameProv(1, 1, scope, agent, spool, 1, rsha[:16], 0x00, nil, fresh, 7))},
		{"length-prefix-overflow", enc(withU64At(valid, scopeLenPos, 0xFFFFFFFF))},
		{"service-non-fresh", enc(frameProv(1, 2, scope, []byte("svc-0"), uuidv7(0xB1), 5, rsha, 0x01, proof, renewal, 7))},
		{"oversized", enc(frameProv(1, 1, bytes.Repeat([]byte{0x5A}, 400), agent, spool, 1, rsha, 0x00, nil, fresh, 7))},
	}
}

func withU64At(b []byte, pos int, v uint64) []byte {
	out := append([]byte{}, b...)
	binary.BigEndian.PutUint64(out[pos:pos+8], v)
	return out
}

// nonCanonicalBase64 returns a RawURLEncoding string whose final character sets low bits that a
// strict decoder must reject as an alias of the canonical encoding.
func nonCanonicalBase64(raw []byte) string {
	s := []byte(base64.RawURLEncoding.EncodeToString(raw))
	last := s[len(s)-1]
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	idx := strings.IndexByte(alphabet, last)
	s[len(s)-1] = alphabet[(idx+1)%len(alphabet)]
	return string(s)
}

// serviceRecord is the canonical record re-originated as a governed CLUSTER_SERVICE record
// (origin_kind + principal), re-signed and re-digested, so service headers are generated from an
// ACTUAL service record rather than the agent record's semantic digest/hash.
func serviceRecord(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()
	r := canonicalRecord(t)
	r.GetProducerContext().OriginKind = edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_CLUSTER_SERVICE
	r.GetProducerContext().OriginPrincipalId = []byte("svc-0")
	r.ProductionCapability = productionCap(r)
	if sa := r.GetSourceAuthorization(); sa != nil {
		sa.Capability = sourceCap(r, sa.GetContextId(), sa.GetScopeId())
	}
	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
	return r
}

func TestGoldenSessionAck(t *testing.T) {
	nonce := uuidv7(0x02)
	golden(t, "client_lane_open.bin", &edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: &edgev1.EdgeRecordLaneOpen{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:      uuidv7(0x01), SequenceBase: 1, FirstUnresolvedSequence: 1, SessionNonce: nonce,
		RequestedByteCredits: 1 << 20, RequestedFrameCredits: 256,
	}}})
	// CROSS-RUNTIME VECTOR: a well-formed unknown GROUP (field 6: 0x33 start / 0x34 end) appended to
	// the golden lane_open. Go's PARSER accepts and RETAINS it as an unknown field -- it is
	// ValidateLaneOpen that must reject it, which it previously did NOT, so Go accepted a lane the
	// Elixir ingress boundary closes. Both runtimes now reject these exact bytes; the Elixir peer
	// asserts {:error, :poison} on the same fixture.
	laneRaw := mustMarshal(&edgev1.EdgeRecordLaneOpen{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:      uuidv7(0x01), SequenceBase: 1, FirstUnresolvedSequence: 1, SessionNonce: nonce,
		RequestedByteCredits: 1 << 20, RequestedFrameCredits: 256,
	})
	laneWithGroup := append(append([]byte{}, laneRaw...), 0x33, 0x34)
	clientWithGroup := append([]byte{0x0A, byte(len(laneWithGroup))}, laneWithGroup...)
	goldenBytes(t, "lane_open_unknown_group.bin", clientWithGroup)

	var groupLane edgev1.EdgeRecordLaneOpen
	if err := proto.Unmarshal(laneWithGroup, &groupLane); err != nil {
		t.Fatalf("Go must PARSE and retain a well-formed unknown group, not reject it: %v", err)
	}
	if len(groupLane.ProtoReflect().GetUnknown()) == 0 {
		t.Fatal("Go must RETAIN the unknown group so validation can see it")
	}
	if err := edgerecord.ValidateLaneOpen(&groupLane); !errors.Is(err, edgerecord.ErrUnknownFields) {
		t.Fatalf("ValidateLaneOpen(unknown group) = %v, want ErrUnknownFields", err)
	}
	// CROSS-RUNTIME VECTOR: LAST-ONE-WINS. A negative traffic_class occurrence PRECEDES the golden
	// lane's valid one, so the effective value is BULK and Go ACCEPTS the lane. Elixir must reach the
	// same verdict on these exact bytes -- before the enum-retention transform it raised on the first
	// occurrence and rejected a lane Go accepts.
	negTrafficClass := []byte{0x10, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}
	laneNegThenValid := append(append([]byte{}, negTrafficClass...), laneRaw...)
	clientNegThenValid := append([]byte{0x0A, byte(len(laneNegThenValid))}, laneNegThenValid...)
	goldenBytes(t, "lane_open_negative_then_valid.bin", clientNegThenValid)

	var mergedLane edgev1.EdgeRecordLaneOpen
	if err := proto.Unmarshal(laneNegThenValid, &mergedLane); err != nil {
		t.Fatalf("Go must decode negative-then-valid last-one-wins: %v", err)
	}
	if got := mergedLane.GetTrafficClass(); got != edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK {
		t.Fatalf("effective traffic_class = %v, want BULK (last-one-wins)", got)
	}
	if err := edgerecord.ValidateLaneOpen(&mergedLane); err != nil {
		t.Fatalf("Go must ACCEPT the negative-then-valid lane: %v", err)
	}

	// Control: the unmodified golden lane still validates.
	var cleanLane edgev1.EdgeRecordLaneOpen
	if err := proto.Unmarshal(laneRaw, &cleanLane); err != nil {
		t.Fatalf("golden lane must parse: %v", err)
	}
	if err := edgerecord.ValidateLaneOpen(&cleanLane); err != nil {
		t.Fatalf("golden lane must validate: %v", err)
	}

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

//nolint:gocyclo // one golden vector per branch; splitting it splits the lifecycle it asserts end to end
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
	completion, err := edgerecord.MtrCompletionRoot(leaves, 0, 2, planRoot, commitment)
	if err != nil {
		t.Fatalf("completion root: %v", err)
	}
	// The event carries the full plan/range identity, so the COMMITTED BYTES are a
	// valid event: a fixture that ValidateSweepExecutionEvent rejects can never
	// exercise the completion-proof logic it exists to pin, in either runtime.
	lifecycleBytes := golden(t, "lifecycle.bin", &edgev1.SweepExecutionEventV1{
		ExecutionId: uuidv7(0x20), ExecutionShard: 3, AssignmentEpoch: 5,
		ExecutionPlanId: uuidv7(0x22), ExecutionPlanSha256: digest32(0x96), TargetRangeId: uuidv7(0x23),
		Kind:              edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano: fixedNanos, TerminalBatchSequence: 4, DurableThroughBatchSequence: 4,
		HostsObserved: 100, HostsAvailable: 60,
		ExpectedMtrSummaries: 2, EmittedMtrSummaries: 2, ExpectedMtrTraces: 2, EmittedMtrTraces: 1,
		MtrCompletionDigestVersion: edgerecord.MtrCompletionDigestVersion,
		MtrCompletionDigest:        completion,
		PlanRootSha256:             planRoot,
	})
	mustValidateLifecycleBytes(t, "lifecycle.bin", lifecycleBytes)

	// ZERO-MTR terminal: the plan admitted NO MTR targets, so the completion is the
	// canonical zero-leaf proof rather than an absent one. The commitment is 32 ZERO
	// bytes, never empty. This is the shared vector Elixir reproduces byte-for-byte.
	//
	// The event is paired with a REAL zero-MTR plan header carrying that same 32-zero
	// commitment, so the fixture shows both halves of the relation rather than an
	// event asserting a plan nobody wrote.
	zeroCommitment := edgerecord.MtrOrdinalRangeCommitment(nil) // 32 zero bytes
	zeroPlanID := uuidv7(0x24)
	zeroRange := &edgev1.TargetRangeV1{
		RangeId: uuidv7(0x25), Cidr: "10.9.0.0/24", TargetCount: 256,
		CheckSetSha256: digest32(0x78), AvailabilityPolicyId: []byte("policy-1"),
		// Explicit presence: this range admits NO MTR, which is distinct from a plan
		// that never stated a count.
		MtrOrdinalCount: proto.Uint64(0),
	}
	zeroRange.RangeSha256 = edgerecord.RangeDigest(zeroRange)
	zeroPage := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: zeroPlanID, PageIndex: 0, PageCount: 1, CheckSetSha256: digest32(0x78),
		DigestVersion: edgerecord.PlanDigestVersion, Ranges: []*edgev1.TargetRangeV1{zeroRange},
	}
	zeroPage.PageSha256 = edgerecord.PlanPageDigest(zeroPage)
	zeroPlanRoot := edgerecord.PlanRoot([]*edgev1.ScheduledPlanPageV1{zeroPage})
	zeroHeader := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: zeroPlanID, PageCount: 1, TotalTargetCount: 256, PlanRootSha256: zeroPlanRoot,
		DigestVersion: edgerecord.PlanDigestVersion, CheckSetSha256: digest32(0x78),
		AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: uuidv7(0x11),
		MtrOrdinalRangeCommitment: zeroCommitment,
	}
	zeroHeader.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(zeroHeader)
	golden(t, "plan_header_zero_mtr.bin", zeroHeader)
	golden(t, "plan_page_zero_mtr.bin", zeroPage)
	if err := edgerecord.ValidatePlanHeader(zeroHeader); err != nil {
		t.Fatalf("zero-MTR plan header must validate: %v", err)
	}
	zeroCompletion, err := edgerecord.ZeroMtrCompletionRoot(0, zeroPlanRoot, zeroCommitment)
	if err != nil {
		t.Fatalf("zero-MTR completion root: %v", err)
	}
	zeroBytes := golden(t, "lifecycle_zero_mtr.bin", &edgev1.SweepExecutionEventV1{
		ExecutionId: uuidv7(0x21), ExecutionShard: 3, AssignmentEpoch: 5,
		ExecutionPlanId: zeroPlanID, ExecutionPlanSha256: zeroHeader.GetExecutionPlanSha256(), TargetRangeId: uuidv7(0x25),
		Kind:              edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano: fixedNanos, TerminalBatchSequence: 4, DurableThroughBatchSequence: 4,
		HostsObserved: 100, HostsAvailable: 60,
		// No MTR was planned, so every MTR counter is zero -- but the proof is still
		// present, which is the whole point of the decision.
		MtrCompletionDigestVersion: edgerecord.MtrCompletionDigestVersion,
		MtrCompletionDigest:        zeroCompletion,
		PlanRootSha256:             zeroPlanRoot,
	})
	mustValidateLifecycleBytes(t, "lifecycle_zero_mtr.bin", zeroBytes)
	goldenBytes(t, "zero_mtr_commitment.bin", zeroCommitment)

	// The COMMITTED BYTES verify against the PAIRED plan header's state -- the values
	// a real consumer would have to obtain from a validated carrier. Decoding the
	// fixture is the point: asserting that some OTHER event fails would say nothing
	// about the vector that actually ships.
	var zeroEv edgev1.SweepExecutionEventV1
	if err := proto.Unmarshal(zeroBytes, &zeroEv); err != nil {
		t.Fatalf("decode lifecycle_zero_mtr.bin: %v", err)
	}
	if err := edgerecord.VerifyCompletionAgainstPlanState(&zeroEv, 0, 0, zeroHeader.GetPlanRootSha256(), zeroHeader.GetMtrOrdinalRangeCommitment(), nil); err != nil {
		t.Fatalf("committed zero-MTR event must verify against its paired plan: %v", err)
	}

	// Negative control, so the positive above cannot pass vacuously: one flipped
	// digest byte must be rejected.
	perturbed := proto.Clone(&zeroEv).(*edgev1.SweepExecutionEventV1)
	perturbed.MtrCompletionDigest = append([]byte(nil), zeroEv.GetMtrCompletionDigest()...)
	perturbed.MtrCompletionDigest[0] ^= 0xFF
	if err := edgerecord.VerifyCompletionAgainstPlanState(perturbed, 0, 0, zeroHeader.GetPlanRootSha256(), zeroHeader.GetMtrOrdinalRangeCommitment(), nil); err == nil {
		t.Fatal("a perturbed completion digest must not verify")
	}

	// The AUTHORITATIVE assignment record for the zero-MTR attempt. Its required
	// expectation is what a completion proof verifies against; the plan header's
	// commitment is the plan-wide fact, not the per-attempt authority.
	zeroAssignment := &edgev1.SweepAssignmentRecordV1{
		ProducerAssignmentId: uuidv7(0x26), ExecutionId: uuidv7(0x21),
		ExecutionPlanId: zeroPlanID, ExecutionPlanSha256: zeroHeader.GetExecutionPlanSha256(),
		ExecutionShard: 3, AssignmentEpoch: 5, RecordSequence: 1, AuthoredAtUnixNano: fixedNanos,
		TargetRangeId: zeroRange.GetRangeId(), TargetRangeSha256: zeroRange.GetRangeSha256(),
		LeaseId: []byte("lease-zero"), FenceToken: 7, LeaseExpiresAtUnixNano: fixedNanos + 1,
		State:                 edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_COMPLETED,
		TerminalBatchSequence: 4,
		MtrExpectation: &edgev1.SweepMtrExpectationV1{
			OrdinalCount: 0, OrdinalRangeCommitment: zeroCommitment,
			PlanOrdinalOffset: proto.Uint64(0),
		},
		CheckSetSha256: digest32(0x78), AvailabilityPolicyId: []byte("policy-1"),
		NetworkScopeId: uuidv7(0x11), AuthenticatedAgentId: uuidv7(0x12),
		ProductionScopeId: uuidv7(0x13), ScopeSha256: digest32(0x79),
		ContractBundleSha256:     digest32(0x7A),
		RunId:                    uuidv7(0x64),
		CompiledAssignmentId:     uuidv7(0x65),
		CompiledAssignmentSha256: digest32(0x7D),
	}
	assignmentBytes := golden(t, "assignment_zero_mtr.bin", zeroAssignment)
	var decodedAssignment edgev1.SweepAssignmentRecordV1
	if err := proto.Unmarshal(assignmentBytes, &decodedAssignment); err != nil {
		t.Fatalf("decode assignment_zero_mtr.bin: %v", err)
	}
	if err := edgerecord.ValidateSweepAssignmentRecord(&decodedAssignment); err != nil {
		t.Fatalf("committed assignment record must be VALID: %v", err)
	}
	// The RELATION, on committed bytes: the assignment names THIS plan, agrees with it
	// on every shared fact, and its range is a member of the committed plan. The first
	// version of this fixture passed independent validation while naming a real range
	// with an empty-set commitment and an epoch the header did not share.
	if err := edgerecord.ValidateAssignmentAgainstPlan(
		&decodedAssignment, zeroHeader, []*edgev1.ScheduledPlanPageV1{zeroPage},
	); err != nil {
		t.Fatalf("committed assignment must relate to its paired plan: %v", err)
	}
	// The completion proof verifies against the ASSIGNMENT's expectation.
	if err := edgerecord.VerifyCompletionAgainstPlanState(
		&zeroEv,
		decodedAssignment.GetMtrExpectation().GetPlanOrdinalOffset(),
		decodedAssignment.GetMtrExpectation().GetOrdinalCount(),
		zeroHeader.GetPlanRootSha256(),
		decodedAssignment.GetMtrExpectation().GetOrdinalRangeCommitment(),
		nil,
	); err != nil {
		t.Fatalf("completion must verify against the assignment expectation: %v", err)
	}

	// SPLIT-PLAN, NONZERO vector. The zero-MTR pair above cannot distinguish the
	// assignment expectation from the plan-wide commitment, because both are zero32 --
	// a regression substituting the forbidden plan value stays green. Here the plan
	// admits TWO ordinals while the assignment covers ONE, so the two commitments
	// DIFFER and the substitution is observable.
	splitRange := digest32(0x93)
	planWideLeaves := []edgerecord.MtrCompletionLeaf{
		{Ordinal: 1, Disposition: edgerecord.MtrDispositionTraceAllocated, TraceID: uuidv7(0x30), RangeSha256: splitRange},
		{Ordinal: 2, Disposition: edgerecord.MtrDispositionNotAdmitted, RangeSha256: splitRange},
	}
	planWideCommitment := edgerecord.MtrOrdinalRangeCommitment(planWideLeaves)
	attemptLeaves := planWideLeaves[:1]
	attemptCommitment := edgerecord.MtrOrdinalRangeCommitment(attemptLeaves)
	if bytes.Equal(planWideCommitment, attemptCommitment) {
		t.Fatal("split vector is vacuous: plan-wide and per-attempt commitments are equal")
	}
	splitRoot, err := edgerecord.MtrCompletionRoot(attemptLeaves, 0, 1, planRoot, attemptCommitment)
	if err != nil {
		t.Fatalf("split completion root: %v", err)
	}
	splitEv := &edgev1.SweepExecutionEventV1{
		ExecutionId: uuidv7(0x27), ExecutionShard: 3, AssignmentEpoch: 5,
		ExecutionPlanId: uuidv7(0x22), ExecutionPlanSha256: digest32(0x96), TargetRangeId: uuidv7(0x23),
		Kind:              edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano: fixedNanos, TerminalBatchSequence: 4, DurableThroughBatchSequence: 4,
		ExpectedMtrTraces: 1, EmittedMtrTraces: 1,
		MtrCompletionDigestVersion: edgerecord.MtrCompletionDigestVersion,
		MtrCompletionDigest:        splitRoot,
		PlanRootSha256:             planRoot,
	}
	splitBytes := golden(t, "lifecycle_split_attempt.bin", splitEv)
	mustValidateLifecycleBytes(t, "lifecycle_split_attempt.bin", splitBytes)
	goldenBytes(t, "split_attempt_commitment.bin", attemptCommitment)
	goldenBytes(t, "split_plan_wide_commitment.bin", planWideCommitment)

	// The ASSIGNMENT's expectation verifies.
	if err := edgerecord.VerifyCompletionAgainstPlanState(splitEv, 0, 1, planRoot, attemptCommitment, attemptLeaves); err != nil {
		t.Fatalf("split completion must verify against the ASSIGNMENT expectation: %v", err)
	}
	// Substituting the PLAN-WIDE commitment -- the forbidden shortcut -- fails.
	if err := edgerecord.VerifyCompletionAgainstPlanState(splitEv, 0, 2, planRoot, planWideCommitment, planWideLeaves); err == nil {
		t.Fatal("substituting the plan-wide commitment for the per-attempt one must FAIL")
	}

	// SHARED SECOND-ASSIGNMENT VECTOR. A two-range plan split across two assignments:
	// range A owns plan-global ordinals 1..2, range B owns 3..5. B is the NON-PREFIX
	// case -- its completion leaves stay LOCAL at {1..3} while its membership is folded
	// over global 3..5. Both runtimes consume these bytes.
	splitCheck := digest32(0x7B)
	mkSplitRange := func(tag byte, cidr string, count, budget uint64) *edgev1.TargetRangeV1 {
		r := &edgev1.TargetRangeV1{
			RangeId: uuidv7(tag), Cidr: cidr, TargetCount: 256, CheckSetSha256: splitCheck,
			AvailabilityPolicyId: []byte("policy-1"),
			MtrAdmissionBudget:   budget, MtrOrdinalCount: proto.Uint64(count),
		}
		r.RangeSha256 = edgerecord.RangeDigest(r)
		return r
	}
	splitPlanID := uuidv7(0x28)
	rangeA := mkSplitRange(0x29, "10.20.0.0/24", 2, 4)
	rangeB := mkSplitRange(0x2A, "10.20.1.0/24", 3, 3)
	splitPage := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: splitPlanID, PageIndex: 0, PageCount: 1, CheckSetSha256: splitCheck,
		DigestVersion: edgerecord.PlanDigestVersion,
		Ranges:        []*edgev1.TargetRangeV1{rangeA, rangeB},
	}
	splitPage.PageSha256 = edgerecord.PlanPageDigest(splitPage)
	splitPages := []*edgev1.ScheduledPlanPageV1{splitPage}
	splitPlanCommitment, err := edgerecord.PlanMtrOrdinalRangeCommitment(splitPages)
	if err != nil {
		t.Fatalf("split plan commitment: %v", err)
	}
	splitHeader := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: splitPlanID, PageCount: 1, TotalTargetCount: 512,
		PlanRootSha256: edgerecord.PlanRoot(splitPages), DigestVersion: edgerecord.PlanDigestVersion,
		CheckSetSha256: splitCheck, AvailabilityPolicyId: []byte("policy-1"),
		NetworkScopeId: uuidv7(0x11), MtrOrdinalRangeCommitment: splitPlanCommitment,
	}
	splitHeader.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(splitHeader)
	golden(t, "plan_header_split.bin", splitHeader)
	golden(t, "plan_page_split.bin", splitPage)

	splitWindows, _, err := edgerecord.PlanMtrWindows(splitPages)
	if err != nil {
		t.Fatalf("split windows: %v", err)
	}
	offsetB := splitWindows[string(rangeB.GetRangeId())]
	commitB, err := edgerecord.MtrWindowCommitment(offsetB, rangeB.GetMtrOrdinalCount(), rangeB.GetRangeSha256())
	if err != nil {
		t.Fatalf("window B commitment: %v", err)
	}
	secondAssignment := &edgev1.SweepAssignmentRecordV1{
		ProducerAssignmentId: uuidv7(0x2B), ExecutionId: uuidv7(0x2C),
		ExecutionPlanId: splitPlanID, ExecutionPlanSha256: splitHeader.GetExecutionPlanSha256(),
		ExecutionShard: 3, AssignmentEpoch: 5, RecordSequence: 1, AuthoredAtUnixNano: fixedNanos,
		TargetRangeId: rangeB.GetRangeId(), TargetRangeSha256: rangeB.GetRangeSha256(),
		LeaseId: []byte("lease-split-b"), FenceToken: 9, LeaseExpiresAtUnixNano: fixedNanos + 1,
		State: edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_COMPLETED, TerminalBatchSequence: 7,
		MtrExpectation: &edgev1.SweepMtrExpectationV1{
			OrdinalCount: rangeB.GetMtrOrdinalCount(), OrdinalRangeCommitment: commitB,
			PlanOrdinalOffset: proto.Uint64(offsetB),
		},
		CheckSetSha256: splitCheck, AvailabilityPolicyId: []byte("policy-1"),
		NetworkScopeId: uuidv7(0x11), AuthenticatedAgentId: uuidv7(0x12),
		ProductionScopeId: uuidv7(0x13), ScopeSha256: digest32(0x79),
		ContractBundleSha256:     digest32(0x7A),
		RunId:                    uuidv7(0x66),
		CompiledAssignmentId:     uuidv7(0x67),
		CompiledAssignmentSha256: digest32(0x7E),
	}
	secondBytes := golden(t, "assignment_split_second.bin", secondAssignment)
	var decodedSecond edgev1.SweepAssignmentRecordV1
	if err := proto.Unmarshal(secondBytes, &decodedSecond); err != nil {
		t.Fatalf("decode assignment_split_second.bin: %v", err)
	}
	if err := edgerecord.ValidateAssignmentAgainstPlan(&decodedSecond, splitHeader, splitPages); err != nil {
		t.Fatalf("second assignment must relate to the split plan: %v", err)
	}

	secondLeaves := make([]edgerecord.MtrCompletionLeaf, 0, rangeB.GetMtrOrdinalCount())
	for i := uint64(1); i <= rangeB.GetMtrOrdinalCount(); i++ {
		secondLeaves = append(secondLeaves, edgerecord.MtrCompletionLeaf{
			Ordinal: i, Disposition: edgerecord.MtrDispositionNotAdmitted, RangeSha256: rangeB.GetRangeSha256(),
		})
	}
	secondRoot, err := edgerecord.MtrCompletionRoot(secondLeaves, offsetB, rangeB.GetMtrOrdinalCount(),
		splitHeader.GetPlanRootSha256(), commitB)
	if err != nil {
		t.Fatalf("non-prefix completion must prove: %v", err)
	}
	splitSecondEv := &edgev1.SweepExecutionEventV1{
		ExecutionId: uuidv7(0x2C), ExecutionShard: 3, AssignmentEpoch: 5,
		ExecutionPlanId: splitPlanID, ExecutionPlanSha256: splitHeader.GetExecutionPlanSha256(),
		TargetRangeId:     rangeB.GetRangeId(),
		Kind:              edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano: fixedNanos, TerminalBatchSequence: 7, DurableThroughBatchSequence: 7,
		ExpectedMtrTraces: 3, EmittedMtrTraces: 3,
		MtrCompletionDigestVersion: edgerecord.MtrCompletionDigestVersion,
		MtrCompletionDigest:        secondRoot,
		PlanRootSha256:             splitHeader.GetPlanRootSha256(),
	}
	splitSecondBytes := golden(t, "lifecycle_split_second.bin", splitSecondEv)
	mustValidateLifecycleBytes(t, "lifecycle_split_second.bin", splitSecondBytes)

	// Without the offset the SAME leaves against the SAME commitment must fail, so the
	// shared vector cannot pass by coincidence.
	if _, err := edgerecord.MtrCompletionRoot(secondLeaves, 0, rangeB.GetMtrOrdinalCount(),
		splitHeader.GetPlanRootSha256(), commitB); err == nil {
		t.Fatal("non-prefix vector is vacuous: it proves without the offset")
	}

	// SHARED TARGET-COUNT OVERFLOW vector. Two INDIVIDUALLY VALID /65 ranges, each
	// spanning exactly 2^63 addresses, sum to 2^64 -- which wraps to 0 in a uint64
	// accumulator. Go catches the carry via bits.Add64; Elixir's arbitrary-precision
	// integers simply grow, so it needs an explicit ceiling. Without a SHARED fixture,
	// removing Go's carry rejection left its suite green.
	mkHugeRange := func(tag byte, cidr string) *edgev1.TargetRangeV1 {
		r := &edgev1.TargetRangeV1{
			RangeId: uuidv7(tag), Cidr: cidr, TargetCount: 1 << 63,
			CheckSetSha256: splitCheck, AvailabilityPolicyId: []byte("policy-1"),
			MtrAdmissionBudget: 0, MtrOrdinalCount: proto.Uint64(0),
		}
		r.RangeSha256 = edgerecord.RangeDigest(r)
		return r
	}
	overflowPage := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: splitPlanID, PageIndex: 0, PageCount: 1, CheckSetSha256: splitCheck,
		DigestVersion: edgerecord.PlanDigestVersion,
		Ranges: []*edgev1.TargetRangeV1{
			mkHugeRange(0x62, "2001:db8::/65"), mkHugeRange(0x63, "2001:db9::/65"),
		},
	}
	overflowPage.PageSha256 = edgerecord.PlanPageDigest(overflowPage)
	overflowPages := []*edgev1.ScheduledPlanPageV1{overflowPage}
	overflowCommitment, err := edgerecord.PlanMtrOrdinalRangeCommitment(overflowPages)
	if err != nil {
		t.Fatalf("overflow plan commitment: %v", err)
	}
	overflowHeader := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: splitPlanID, PageCount: 1, TotalTargetCount: 0,
		PlanRootSha256: edgerecord.PlanRoot(overflowPages), DigestVersion: edgerecord.PlanDigestVersion,
		CheckSetSha256: splitCheck, AvailabilityPolicyId: []byte("policy-1"),
		NetworkScopeId: uuidv7(0x11), MtrOrdinalRangeCommitment: overflowCommitment,
	}
	overflowHeader.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(overflowHeader)
	golden(t, "plan_header_total_overflow.bin", overflowHeader)
	golden(t, "plan_page_total_overflow.bin", overflowPage)

	// Each range on its own is legal; only their SUM overflows.
	for _, r := range overflowPage.GetRanges() {
		if r.GetTargetCount() != 1<<63 {
			t.Fatalf("overflow fixture drift: range count %d", r.GetTargetCount())
		}
	}
	if err := edgerecord.ValidatePlanPages(overflowHeader, overflowPages); !errors.Is(err, edgerecord.ErrPlanTotals) {
		t.Fatalf("target-count overflow = %v, want ErrPlanTotals", err)
	}

	// SHARED BLOAT VECTORS on the RAW plan boundary. A page padded with DUPLICATE known
	// fields collapses on a re-marshal, so measuring the round trip is not the physical
	// ceiling: Go's struct path accepted 131,074 received bytes that Elixir refused.
	// These pin the boundary to RECEIVED bytes on both sides, at the limit and one over.
	basePage := splitPage
	atLimit := padWithDuplicateKnownField(t, mustMarshal(basePage), edgerecord.MaxPlanPageBytes)
	overLimit := padWithDuplicateKnownField(t, mustMarshal(basePage), edgerecord.MaxPlanPageBytes+1)
	goldenBytes(t, "plan_page_bytes_at_limit.bin", atLimit)
	goldenBytes(t, "plan_page_bytes_over_limit.bin", overLimit)

	// Both decode to the SAME page -- asserted by FULL message equality, not merely
	// "both unmarshal" -- and both collapse well under the ceiling on a re-marshal.
	// That is what makes the pair non-vacuous: only the RECEIVED size differs.
	var decodedAt, decodedOver edgev1.ScheduledPlanPageV1
	if err := proto.Unmarshal(atLimit, &decodedAt); err != nil {
		t.Fatalf("at-limit vector must decode: %v", err)
	}
	if err := proto.Unmarshal(overLimit, &decodedOver); err != nil {
		t.Fatalf("over-limit vector must decode: %v", err)
	}
	if !proto.Equal(&decodedAt, &decodedOver) {
		t.Fatal("bloat vectors must decode to the SAME page; only received size may differ")
	}
	if !proto.Equal(&decodedAt, basePage) {
		t.Fatal("bloat vectors must decode to the base page")
	}
	if n := len(mustMarshal(&decodedAt)); n >= edgerecord.MaxPlanPageBytes {
		t.Fatalf("re-marshal is %d bytes, expected far below the %d ceiling -- the pair "+
			"only demonstrates the received-bytes rule if the round trip collapses",
			n, edgerecord.MaxPlanPageBytes)
	}
	rawSplitHeader, err := proto.Marshal(splitHeader)
	if err != nil {
		t.Fatalf("marshal split header: %v", err)
	}
	if _, _, err := edgerecord.ValidatePlanFromRaw(rawSplitHeader, [][]byte{atLimit}); err != nil {
		t.Fatalf("a page at exactly MaxPlanPageBytes must be accepted: %v", err)
	}
	if _, _, err := edgerecord.ValidatePlanFromRaw(rawSplitHeader, [][]byte{overLimit}); !errors.Is(err, edgerecord.ErrPlanBounds) {
		t.Fatalf("a page one byte over = %v, want ErrPlanBounds", err)
	}

	// SHARED REJECT VECTORS, authored by Go and consumed by BOTH runtimes. In-memory
	// mutations inside one runtime's test prove only that runtime's opinion; a reject
	// vector has to be BYTES on disk, or the two implementations can disagree about
	// what is refused and nothing notices.
	//
	// Each asserts its EXACT sentinel, not merely "some error": reason parity across the
	// two runtimes is the thing being proven, and any-error assertions cannot show it.
	rejectCases := []struct {
		name   string
		want   error
		mutate func(*edgev1.SweepAssignmentRecordV1)
	}{
		{"assignment_reject_lease.bin", edgerecord.ErrAssignmentLease, func(r *edgev1.SweepAssignmentRecordV1) {
			r.LeaseId = nil
			r.FenceToken = 0
		}},
		{"assignment_reject_expectation.bin", edgerecord.ErrAssignmentExpectation, func(r *edgev1.SweepAssignmentRecordV1) {
			// count and commitment disagree: count 0 with a non-empty commitment.
			r.MtrExpectation.OrdinalCount = 0
		}},
		{"assignment_reject_sequence.bin", edgerecord.ErrAssignmentIdentity, func(r *edgev1.SweepAssignmentRecordV1) {
			r.RecordSequence = 0
		}},
		{"assignment_reject_zero_uuid.bin", edgerecord.ErrAssignmentIdentity, func(r *edgev1.SweepAssignmentRecordV1) {
			r.ProducerAssignmentId = make([]byte, 16)
		}},
		{"assignment_reject_offset_absent.bin", edgerecord.ErrAssignmentExpectation, func(r *edgev1.SweepAssignmentRecordV1) {
			r.MtrExpectation.PlanOrdinalOffset = nil
		}},
	}
	for _, tc := range rejectCases {
		bad := proto.Clone(secondAssignment).(*edgev1.SweepAssignmentRecordV1)
		tc.mutate(bad)
		badBytes := golden(t, tc.name, bad)
		var decoded edgev1.SweepAssignmentRecordV1
		if err := proto.Unmarshal(badBytes, &decoded); err != nil {
			t.Fatalf("%s: decode: %v", tc.name, err)
		}
		if err := edgerecord.ValidateSweepAssignmentRecord(&decoded); !errors.Is(err, tc.want) {
			t.Fatalf("%s: got %v, want %v", tc.name, err, tc.want)
		}
	}

	// SHARED WORK-CEILING BOUNDARY. The ceiling is an ABI fact, not a Go
	// implementation detail: a plan Go rejects and Elixir accepts is a divergence, so
	// both runtimes consume these two pages and must agree on the verdict. Bounds are
	// checked BEFORE any hashing, so a max-sized page costs a walk here, not a fold.
	//
	// The page carries MULTIPLE ranges whose counts SUM to the boundary. A single-range
	// fixture would be satisfied by an implementation that bounds each range on its own
	// and never accumulates, which is precisely the bug the ceiling exists to stop.
	mkCeilingPage := func(tag byte, counts ...uint64) *edgev1.ScheduledPlanPageV1 {
		ranges := make([]*edgev1.TargetRangeV1, 0, len(counts))
		for i, c := range counts {
			r := &edgev1.TargetRangeV1{
				RangeId: uuidv7(tag + byte(i)), Cidr: "10.30.0.0/24", TargetCount: 256,
				CheckSetSha256: digest32(0x7C), AvailabilityPolicyId: []byte("policy-1"),
				MtrAdmissionBudget: c, MtrOrdinalCount: proto.Uint64(c),
			}
			r.RangeSha256 = edgerecord.RangeDigest(r)
			ranges = append(ranges, r)
		}
		p := &edgev1.ScheduledPlanPageV1{
			ExecutionPlanId: uuidv7(0x2D), PageIndex: 0, PageCount: 1,
			CheckSetSha256: digest32(0x7C), DigestVersion: edgerecord.PlanDigestVersion,
			Ranges: ranges,
		}
		p.PageSha256 = edgerecord.PlanPageDigest(p)
		return p
	}
	const halfCeiling = edgerecord.MaxPlanMtrOrdinals / 2
	// Three ranges, each far under the ceiling, summing to exactly N and N+1.
	atMax := mkCeilingPage(0x2E, halfCeiling, halfCeiling-1, 1)
	overMax := mkCeilingPage(0x40, halfCeiling, halfCeiling-1, 2)
	golden(t, "plan_page_ordinals_at_max.bin", atMax)
	golden(t, "plan_page_ordinals_over_max.bin", overMax)

	for _, r := range atMax.GetRanges() {
		if r.GetMtrOrdinalCount() > edgerecord.MaxPlanMtrOrdinals/2 {
			t.Fatal("a single range reaches the ceiling; the multi-range control is vacuous")
		}
	}
	if _, _, err := edgerecord.PlanMtrWindows([]*edgev1.ScheduledPlanPageV1{atMax}); err != nil {
		t.Fatalf("exactly MaxPlanMtrOrdinals must be ACCEPTED: %v", err)
	}
	if _, _, err := edgerecord.PlanMtrWindows([]*edgev1.ScheduledPlanPageV1{overMax}); !errors.Is(err, edgerecord.ErrPlanMtrWindow) {
		t.Fatalf("MaxPlanMtrOrdinals+1 = %v, want ErrPlanMtrWindow", err)
	}
	// Drive the ACTUAL commitment function, not only the bounds walk: if the pre-hash
	// guard were removed this would fold 2^20+1 hashes and RETURN a value instead of an
	// error, so the assertion is what keeps the guard load-bearing.
	if _, err := edgerecord.PlanMtrOrdinalRangeCommitment([]*edgev1.ScheduledPlanPageV1{overMax}); !errors.Is(err, edgerecord.ErrPlanMtrWindow) {
		t.Fatalf("over-ceiling commitment = %v, want ErrPlanMtrWindow", err)
	}
	// And the EXPORTED per-window helper, which was the bypass: a window that ENDS past
	// the ceiling is refused even though its WIDTH is 1.
	if _, err := edgerecord.MtrWindowCommitment(edgerecord.MaxPlanMtrOrdinals, 1, digest32(0x7C)); !errors.Is(err, edgerecord.ErrPlanMtrWindow) {
		t.Fatalf("window ending past the ceiling = %v, want ErrPlanMtrWindow", err)
	}
	if _, err := edgerecord.MtrWindowCommitment(edgerecord.MaxPlanMtrOrdinals-1, 1, digest32(0x7C)); err != nil {
		t.Fatalf("a window ending exactly AT the ceiling must be accepted: %v", err)
	}

	// STALE-WIRE PROOF for the retired tag 20. Reserving a tag prevents source reuse; it
	// does not prove a sender that still emits the field is rejected. This vector is the
	// valid zero-MTR event with a length-delimited field 20 appended, exactly as a
	// pre-retirement sender would encode range_root_sha256.
	staleTag20 := append(append([]byte(nil), zeroBytes...), 0xA2, 0x01, 0x20)
	staleTag20 = append(staleTag20, digest32(0x95)...)
	staleBytes := goldenBytes(t, "lifecycle_stale_tag20.bin", staleTag20)

	var stale edgev1.SweepExecutionEventV1
	if err := proto.Unmarshal(staleBytes, &stale); err != nil {
		t.Fatalf("stale tag-20 vector must still DECODE (that is why it is dangerous): %v", err)
	}
	// Assert the retained bytes really are tag 20, wire type 2 -- otherwise the
	// rejection below could be firing on something else entirely.
	unknown := stale.ProtoReflect().GetUnknown()
	if len(unknown) == 0 {
		t.Fatal("stale vector retained no unknown field; the fixture is vacuous")
	}
	if num, typ, n := protowire.ConsumeTag(unknown); n < 0 || num != 20 || typ != protowire.BytesType {
		t.Fatalf("retained tag = %v/%v, want field 20 wire type 2", num, typ)
	}
	if err := edgerecord.ValidateSweepExecutionEvent(&stale); !errors.Is(err, edgerecord.ErrUnknownFields) {
		t.Fatalf("stale tag-20 event = %v, want ErrUnknownFields", err)
	}

	rid := uuidv7(0x80)
	page := &edgev1.EdgeLossManifestPageV1{
		RecoveryId: rid, PageIndex: 0, PageCount: 1, Terminal: true, DigestVersion: edgerecord.RecoveryDigestVersion,
		ClassificationSpans: []*edgev1.EdgeClassificationSpanV1{
			// ATTRIBUTED_ACTIVE with a source identity PRESENT.
			{
				FromSequence: 10, ThroughSequence: 20,
				Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
					AttributedActive: &edgev1.EdgeAttributedActiveV1{
						Identity: &edgev1.EdgeAttributedSpanIdentityV1{
							ProducerAssignmentId: uuidv7(0x72), RunId: uuidv7(0x73), RunShard: 3,
							AuthorityEpoch: 5, ProductionScopeId: uuidv7(0x74),
							ScopeSha256: digest32(0x84), ContractBundleSha256: digest32(0x40),
							Source: &edgev1.EdgeSourceSpanIdentityV1{
								Kind:              edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
								ContextId:         uuidv7(0x76),
								SourceScopeId:     uuidv7(0x77),
								SourceScopeSha256: digest32(0x86),
							},
						},
						RangeSha256: digest32(0x85),
					},
				},
			},
			// ATTRIBUTED_PASSIVE with the source identity ABSENT. Absence is part of
			// the identity and is NOT the same as PASSIVE -- the two axes are
			// independent, and this vector carries one of each so a cross-language
			// fixture pins both framings.
			{
				FromSequence: 22, ThroughSequence: 22,
				Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
					AttributedPassive: &edgev1.EdgeAttributedPassiveV1{
						Identity: &edgev1.EdgeAttributedSpanIdentityV1{
							ProducerAssignmentId: uuidv7(0x78), RunId: uuidv7(0x79), RunShard: 3,
							AuthorityEpoch: 5, ProductionScopeId: uuidv7(0x7a),
							ScopeSha256: digest32(0x87), ContractBundleSha256: digest32(0x40),
						},
					},
				},
			},
			// UNATTRIBUTABLE. Sequences 21 and 23-29 are deliberately omitted: a gap
			// means NOT LOST, and gaps are legal within a page.
			{
				FromSequence: 30, ThroughSequence: 31,
				Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{
					Unattributable: &edgev1.EdgeUnattributableV1{
						Reason: edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
					},
				},
			},
		},
	}
	page.PageSha256 = edgerecord.ManifestPageDigest(page)
	pages := []*edgev1.EdgeLossManifestPageV1{page}
	root := edgerecord.ManifestRoot(pages)
	golden(t, "manifest_page.bin", page)

	// EVERY UNATTRIBUTABLE REASON as a shared vector. manifest_page.bin exercises all
	// three classifications but only ONE reason, so the other four were pinned by
	// runtime-local tests only -- each runtime self-consistent, neither cross-checked.
	// One page per reason, so a divergence names the reason rather than the page.
	for i, r := range []edgev1.EdgeUnattributableReason{
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE,
	} {
		rp := &edgev1.EdgeLossManifestPageV1{
			RecoveryId: uuidv7(byte(0x90 + i)), PageIndex: 0, PageCount: 1, Terminal: true,
			DigestVersion: edgerecord.RecoveryDigestVersion,
			ClassificationSpans: []*edgev1.EdgeClassificationSpanV1{{
				FromSequence: 1, ThroughSequence: 2,
				Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{
					Unattributable: &edgev1.EdgeUnattributableV1{Reason: r},
				},
			}},
		}
		rp.PageSha256 = edgerecord.ManifestPageDigest(rp)
		if err := edgerecord.ValidateManifestChain([]*edgev1.EdgeLossManifestPageV1{rp}, nil); err != nil {
			t.Fatalf("reason %v vector must validate: %v", r, err)
		}
		golden(t, fmt.Sprintf("manifest_page_reason_%d.bin", int32(r.Number())), rp)
	}

	// NON-CANONICAL BLOAT as SHARED bytes. Both runtimes previously constructed this
	// case independently, so each proved its own decoder against its own padding --
	// which cannot show the two agree on what "the received bytes" are. Same page,
	// re-encoded with a duplicate singular field so the RECEIVED size exceeds the
	// re-encoded size.
	canonical, err := proto.Marshal(page)
	if err != nil {
		t.Fatalf("marshal page: %v", err)
	}
	bloated := append(append([]byte{}, canonical...), 0x40, 0x01) // digest_version again
	goldenBytes(t, "manifest_page_bloated.bin", bloated)

	// THE AGGREGATE OVER-BUDGET PAIR, as SHARED bytes and a GENUINE TWO-PAGE CHAIN.
	//
	// An earlier version padded two copies of the same single-page manifest, so the
	// pair decoded as page 0/1 terminal TWICE. Relational validation rejected it as a
	// broken chain -- meaning an implementation that summed RE-ENCODED sizes would
	// still have rejected the pair, just later and for an unrelated reason. The
	// intended bypass was never isolated.
	//
	// These are page 0/2 nonterminal and page 1/2 terminal, correctly chained by
	// predecessor digest with globally ordered spans, so the DECODED pair is valid.
	// Each is individually UNDER the cap and their re-encoded aggregate is far below
	// it, while the RAW pair is exactly one byte over: the only thing that can reject
	// them is received-byte accounting.
	chainA := &edgev1.EdgeLossManifestPageV1{
		RecoveryId: rid, PageIndex: 0, PageCount: 2, Terminal: false,
		DigestVersion:       edgerecord.RecoveryDigestVersion,
		ClassificationSpans: []*edgev1.EdgeClassificationSpanV1{page.GetClassificationSpans()[0]},
	}
	chainA.PageSha256 = edgerecord.ManifestPageDigest(chainA)

	chainB := &edgev1.EdgeLossManifestPageV1{
		RecoveryId: rid, PageIndex: 1, PageCount: 2, Terminal: true,
		PrevPageSha256:      chainA.GetPageSha256(),
		DigestVersion:       edgerecord.RecoveryDigestVersion,
		ClassificationSpans: []*edgev1.EdgeClassificationSpanV1{page.GetClassificationSpans()[2]},
	}
	chainB.PageSha256 = edgerecord.ManifestPageDigest(chainB)

	chain := []*edgev1.EdgeLossManifestPageV1{chainA, chainB}
	if err := edgerecord.ValidateManifestChain(chain, edgerecord.ManifestRoot(chain)); err != nil {
		t.Fatalf("the over-budget pair must be a VALID chain when decoded, or the "+
			"bounds rejection is not attributable to byte accounting: %v", err)
	}

	half := edgerecord.MaxManifestBytes / 2
	targets := [...]int{half, half + 1}
	names := [...]string{"manifest_page_overbudget_a.bin", "manifest_page_overbudget_b.bin"}

	rawTotal, reencodedTotal := 0, 0
	padded := make([][]byte, len(chain))
	for i, pg := range chain {
		canon, err := proto.Marshal(pg)
		if err != nil {
			t.Fatalf("marshal chain page %d: %v", i, err)
		}
		reencodedTotal += len(canon)

		p := padToLen(t, canon, targets[i])
		if len(p) > edgerecord.MaxManifestBytes {
			t.Fatalf("%s is %d bytes, individually over the cap; the pair would not isolate the aggregate",
				names[i], len(p))
		}
		var probe edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(p, &probe); err != nil {
			t.Fatalf("%s must decode: %v", names[i], err)
		}
		if !proto.Equal(&probe, pg) {
			t.Fatalf("%s decoded to a different message; the padding is not inert", names[i])
		}
		rawTotal += len(p)
		padded[i] = p
		goldenBytes(t, names[i], p)
	}

	if rawTotal != edgerecord.MaxManifestBytes+1 {
		t.Fatalf("raw pair totals %d, want exactly %d", rawTotal, edgerecord.MaxManifestBytes+1)
	}
	if reencodedTotal >= edgerecord.MaxManifestBytes {
		t.Fatalf("re-encoded aggregate is %d, must be BELOW %d so a re-encode-summing "+
			"implementation would ADMIT this pair", reencodedTotal, edgerecord.MaxManifestBytes)
	}

	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: uuidv7(0x01), NewSpoolId: uuidv7(0x82),
		ManifestRootSha256: root, ManifestPageCount: 1,
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
	r := &edgev1.TargetRangeV1{RangeId: uuidv7(0xA1), Cidr: "10.0.0.0/24", TargetCount: 256, CheckSetSha256: checkSet, AvailabilityPolicyId: []byte("policy-1"), MtrAdmissionBudget: 8, MtrOrdinalCount: proto.Uint64(2)}
	r.RangeSha256 = edgerecord.RangeDigest(r)
	page := &edgev1.ScheduledPlanPageV1{ExecutionPlanId: planID, PageIndex: 0, PageCount: 1, CheckSetSha256: checkSet, DigestVersion: edgerecord.PlanDigestVersion, Ranges: []*edgev1.TargetRangeV1{r}}
	page.PageSha256 = edgerecord.PlanPageDigest(page)
	pages := []*edgev1.ScheduledPlanPageV1{page}
	// This plan ADMITS MTR (the range carries a budget), so the header commits the
	// (ordinal, range) assignment the completion proof proves membership against. A
	// plan admitting NO MTR carries 32 ZERO bytes here -- never empty bytes; see
	// lifecycle_zero_mtr.bin. The field is ALWAYS 32 bytes either way.
	mtrCommitment, err := edgerecord.PlanMtrOrdinalRangeCommitment(pages)
	if err != nil {
		t.Fatalf("plan mtr commitment: %v", err)
	}
	h := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: planID, PageCount: 1, TotalTargetCount: 256, PlanRootSha256: edgerecord.PlanRoot(pages),
		DigestVersion: edgerecord.PlanDigestVersion, CheckSetSha256: checkSet, AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: uuidv7(0x11),
		MtrOrdinalRangeCommitment: mtrCommitment,
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

// TestGoldenCompiledAssignment freezes the compiled-assignment carrier as SHARED BYTES
// so Elixir implements against committed vectors rather than a second reading of the
// prose. It emits the carrier, both digests, the capability signing preimage, the issuer
// public key, and reject vectors whose EXACT reason is pinned for both runtimes.
//
//nolint:gocyclo // one golden vector per branch
func TestGoldenCompiledAssignment(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		t.Fatal("ed25519 public key type assertion failed")
	}
	goldenBytes(t, "compiled_assignment_issuer.pub", pub)

	// A REAL COMMITTED PLAN. The boundary validates the record against its plan, so a
	// record whose range exists in no plan would make that check unreachable.
	planID, scopeID, agentID := uuidv7(0x31), uuidv7(0x33), uuidv7(0x34)
	carrierRange := &edgev1.TargetRangeV1{
		RangeId: uuidv7(0x32), Cidr: "10.11.0.0/24", TargetCount: 256,
		CheckSetSha256: digest32(0x83), AvailabilityPolicyId: []byte("policy-1"),
		MtrOrdinalCount: proto.Uint64(0),
	}
	carrierRange.RangeSha256 = edgerecord.RangeDigest(carrierRange)
	carrierPage := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: planID, PageIndex: 0, PageCount: 1, CheckSetSha256: digest32(0x83),
		DigestVersion: edgerecord.PlanDigestVersion, Ranges: []*edgev1.TargetRangeV1{carrierRange},
	}
	carrierPage.PageSha256 = edgerecord.PlanPageDigest(carrierPage)
	carrierPlanHeader := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: planID, PageCount: 1, TotalTargetCount: 256,
		PlanRootSha256: edgerecord.PlanRoot([]*edgev1.ScheduledPlanPageV1{carrierPage}),
		DigestVersion:  edgerecord.PlanDigestVersion, CheckSetSha256: digest32(0x83),
		AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: scopeID,
		MtrOrdinalRangeCommitment: edgerecord.MtrOrdinalRangeCommitment(nil),
	}
	carrierPlanHeader.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(carrierPlanHeader)
	carrierPlanPages := []*edgev1.ScheduledPlanPageV1{carrierPage}
	golden(t, "compiled_assignment_plan_header.bin", carrierPlanHeader)
	golden(t, "compiled_assignment_plan_page.bin", carrierPage)

	rangeID := carrierRange.GetRangeId()
	prodAssignID, execID := uuidv7(0x35), uuidv7(0x36)
	// The window closes AT the lease: collection is constrained to the lease, so a
	// carrier outliving it is not a representable valid fixture.
	notBefore, expires := fixedNanos, fixedNanos+1

	c := &edgev1.CompiledSweepAssignmentV1{
		CompiledAssignmentId: uuidv7(0x37),
		DigestVersion:        edgerecord.CompiledAssignmentDigestVersion,
		ProducerAssignmentId: prodAssignID,
		ExecutionId:          execID,
		ExecutionPlanId:      planID,
		ExecutionPlanSha256:  carrierPlanHeader.GetExecutionPlanSha256(),
		TargetRangeId:        rangeID,
		TargetRangeSha256:    carrierRange.GetRangeSha256(),
		NetworkScopeId:       scopeID,
		AuthenticatedAgentId: agentID,
		ExecutionShard:       3,
		AssignmentEpoch:      5,
		ConfigGeneration:     7,
		ResultFormat:         edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1,
		CheckSetSha256:       carrierPlanHeader.GetCheckSetSha256(),
		TrafficClass:         edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		NotBeforeUnixNano:    notBefore,
		ExpiresAtUnixNano:    expires,
	}
	c.CompiledAssignmentBodySha256 = edgerecord.CompiledAssignmentBodyDigest(c)
	c.CollectionCapability = &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("sched"), IssuerKeyId: []byte("k1"),
		Algorithm: "ed25519", NotBeforeUnixNano: notBefore, ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Collection{
			Collection: &edgev1.EdgeCollectionClaimsV1{
				Purpose:                      edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
				NetworkScopeId:               scopeID,
				AuthenticatedAgentId:         agentID,
				ExecutionPlanId:              planID,
				TargetRangeId:                rangeID,
				ExecutionShard:               3,
				AssignmentEpoch:              5,
				CompiledAssignmentBodySha256: c.GetCompiledAssignmentBodySha256(),
				TrafficClass:                 c.GetTrafficClass(),
				ProducerAssignmentId:         prodAssignID,
				ExecutionId:                  execID,
			},
		},
	}
	// The SIGNING PREIMAGE is a vector in its own right: it is the one artifact that
	// proves Elixir frames the collection claims identically, independent of whether it
	// can reproduce an Ed25519 signature.
	goldenBytes(t, "compiled_assignment_capability_signing_bytes.bin",
		edgerecord.CapabilitySigningBytes(c.GetCollectionCapability()))
	edgerecord.SignCapability(c.GetCollectionCapability(), priv)
	c.CompiledAssignmentSha256 = edgerecord.CompiledAssignmentArtifactDigest(c)

	goldenBytes(t, "compiled_assignment_body_digest.bin", c.GetCompiledAssignmentBodySha256())
	goldenBytes(t, "compiled_assignment_artifact_digest.bin", c.GetCompiledAssignmentSha256())
	carrierBytes := golden(t, "compiled_assignment.bin", c)

	if len(carrierBytes) > edgerecord.MaxCompiledAssignmentBytes {
		t.Fatalf("golden carrier exceeds the frozen ceiling: %d", len(carrierBytes))
	}
	decoded, err := edgerecord.ValidateCompiledSweepAssignmentBytes(carrierBytes)
	if err != nil {
		t.Fatalf("golden carrier must validate from committed bytes: %v", err)
	}
	if !proto.Equal(decoded, c) {
		t.Fatal("golden carrier did not round-trip to an equal message")
	}

	// Authentication against the committed public key -- the vectors prove a REAL
	// signature, not merely a present one.
	// A SEPARATE host key, and PURPOSE-SCOPED entries. Sharing one key or ignoring purpose
	// would make the host/scheduler separation untestable: a scheduler-signed execution grant
	// would still verify.
	hostSeed := make([]byte, ed25519.SeedSize)
	for i := range hostSeed {
		hostSeed[i] = byte(0x80 + i)
	}
	hostPriv := ed25519.NewKeyFromSeed(hostSeed)
	hostPub, okHost := hostPriv.Public().(ed25519.PublicKey)
	if !okHost {
		t.Fatal("host ed25519 public key type assertion failed")
	}
	goldenBytes(t, "compiled_assignment_host_issuer.pub", hostPub)
	trust := goldenTrust{
		"sched|k1|EDGE_CAPABILITY_PURPOSE_COLLECTION":                   pub,
		"host|host-exec-1|EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION": hostPub,
	}
	status, err := edgerecord.VerifyCompiledAssignmentWithTrust(decoded, trust, notBefore, 1)
	if err != nil || status != edgerecord.KeyValid {
		t.Fatalf("golden carrier authentication: status=%v err=%v", status, err)
	}

	// The referencing record, and the full relation.
	r := &edgev1.SweepAssignmentRecordV1{
		ProducerAssignmentId: prodAssignID, ExecutionId: execID,
		ExecutionPlanId: planID, ExecutionPlanSha256: c.GetExecutionPlanSha256(),
		ExecutionShard: 3, AssignmentEpoch: 5, RecordSequence: 1, AuthoredAtUnixNano: fixedNanos,
		TargetRangeId: rangeID, TargetRangeSha256: c.GetTargetRangeSha256(),
		LeaseId: []byte("lease-compiled"), FenceToken: 7, LeaseExpiresAtUnixNano: expires,
		State: edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN,
		// DERIVED from the plan, exactly as the relation recomputes it. A hand-picked
		// commitment would be the self-authoritative hole again.
		MtrExpectation: &edgev1.SweepMtrExpectationV1{
			OrdinalCount:           carrierRange.GetMtrOrdinalCount(),
			OrdinalRangeCommitment: edgerecord.MtrOrdinalRangeCommitment(nil),
			PlanOrdinalOffset:      proto.Uint64(0),
		},
		CheckSetSha256:       c.GetCheckSetSha256(),
		AvailabilityPolicyId: carrierPlanHeader.GetAvailabilityPolicyId(),
		NetworkScopeId:       scopeID, AuthenticatedAgentId: agentID,
		ProductionScopeId: uuidv7(0x38), ScopeSha256: digest32(0x84),
		ContractBundleSha256:     digest32(0x85),
		RunId:                    uuidv7(0x39),
		CompiledAssignmentId:     c.GetCompiledAssignmentId(),
		CompiledAssignmentSha256: c.GetCompiledAssignmentSha256(),
		SourceIdentity: &edgev1.EdgeSourceSpanIdentityV1{
			Kind:              edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
			ContextId:         uuidv7(0x3A),
			SourceScopeId:     uuidv7(0x3B),
			SourceScopeSha256: digest32(0x86),
		},
	}
	recordBytes := golden(t, "compiled_assignment_record.bin", r)
	var decodedRecord edgev1.SweepAssignmentRecordV1
	if err := proto.Unmarshal(recordBytes, &decodedRecord); err != nil {
		t.Fatalf("decode compiled_assignment_record.bin: %v", err)
	}
	if err := edgerecord.ValidateAssignmentAgainstCompiled(&decodedRecord, decoded); err != nil {
		t.Fatalf("golden relation: %v", err)
	}
	// The HOST's execution grant, from a committed CAPABILITY. It is a dedicated
	// ASSIGNMENT_EXECUTION grant validated COMPLETELY -- PRODUCTION/SOURCE are record-plane
	// contracts whose full semantics need an EdgeRecordV1, so a grant consuming them could
	// only interpret a subset.
	grantCap := &edgev1.EdgeSignedCapabilityV1{
		// The HOST key family, deliberately not the scheduler's: the grant is a separate
		// principal's decision to run the carrier the scheduler compiled.
		CapabilityVersion: 1, IssuerId: []byte("host"), IssuerKeyId: []byte("host-exec-1"),
		Algorithm: "ed25519", NotBeforeUnixNano: notBefore, ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
			AssignmentExecution: &edgev1.EdgeAssignmentExecutionClaimsV1{
				Purpose:              edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
				NetworkScopeId:       scopeID,
				AuthenticatedAgentId: agentID,
				ProducerAssignmentId: prodAssignID,
				ExecutionId:          execID,
				RunId:                r.GetRunId(),
				RunShard:             3,
				AuthorityEpoch:       5,
				ProductionScopeId:    r.GetProductionScopeId(),
				ScopeSha256:          r.GetScopeSha256(),
				ContractBundleSha256: r.GetContractBundleSha256(),
				ExecutionPlanSha256:  r.GetExecutionPlanSha256(),
				TargetRangeSha256:    r.GetTargetRangeSha256(),
				TrafficClass:         c.GetTrafficClass(),
				// A REAL collection window; an unset one is refused, not read as unconstrained.
				CollectionNotBeforeUnixNano: notBefore,
				CollectionExpiresUnixNano:   expires,
				SourceIdentity:              r.GetSourceIdentity(),
				// THE EXACT CARRIER this grant permits.
				CompiledAssignmentId:     c.GetCompiledAssignmentId(),
				CompiledAssignmentSha256: c.GetCompiledAssignmentSha256(),
			},
		},
	}
	// THE SIGNING PREIMAGE as a shared vector: the one artifact that proves the Elixir peer
	// frames the execution-grant claims identically, independent of reproducing a signature.
	goldenBytes(t, "compiled_assignment_execution_grant_signing_bytes.bin",
		edgerecord.CapabilitySigningBytes(grantCap))
	edgerecord.SignCapability(grantCap, hostPriv)
	golden(t, "compiled_assignment_execution_grant.bin", grantCap)
	rawGrant, err := proto.Marshal(grantCap)
	if err != nil {
		t.Fatalf("marshal grant: %v", err)
	}

	// The composition proof for the standalone GRANT, built from THIS grant -- the one that
	// matches the committed record and carrier. Building it from the source-absent vector
	// instead would let a runtime that regressed to direct decoding still reject, as a
	// BINDING failure against the wrong pair, and the decoder claim would go unproven.
	grantWithGroup := append(append([]byte{}, rawGrant...), 0x33, 0x34)
	goldenBytes(t, "compiled_assignment_grant_unknown_group.bin", grantWithGroup)

	var groupGrant edgev1.EdgeSignedCapabilityV1
	if err := proto.Unmarshal(grantWithGroup, &groupGrant); err != nil {
		t.Fatalf("Go must PARSE and retain a well-formed unknown group, not reject it: %v", err)
	}
	if err := edgerecord.ValidateCapability(&groupGrant,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION); !errors.Is(err, edgerecord.ErrUnknownFields) {
		t.Fatalf("grant with a retained unknown group = %v, want ErrUnknownFields", err)
	}
	if status, err := edgerecord.VerifyAssignmentExecutionGrant(&decodedRecord, carrierBytes, rawGrant, trust, notBefore, 1); err != nil || status != edgerecord.KeyValid {
		t.Fatalf("golden execution grant: status=%v err=%v", status, err)
	}

	// THE FULL CURRENT-AUTHORITY BOUNDARY, from committed bytes.
	rawCarrierHeader, err := proto.Marshal(carrierPlanHeader)
	if err != nil {
		t.Fatalf("marshal plan header: %v", err)
	}
	rawCarrierPages := make([][]byte, 0, len(carrierPlanPages))
	for _, pg := range carrierPlanPages {
		pb, err := proto.Marshal(pg)
		if err != nil {
			t.Fatalf("marshal plan page: %v", err)
		}
		rawCarrierPages = append(rawCarrierPages, pb)
	}
	authority := edgerecord.CollectionAuthority{
		Trust: trust,
		Assignments: goldenAssignmentAuthority{
			want: edgerecord.AssignmentKey{
				NetworkScopeID:       decodedRecord.GetNetworkScopeId(),
				AuthenticatedAgentID: decodedRecord.GetAuthenticatedAgentId(),
				ProducerAssignmentID: decodedRecord.GetProducerAssignmentId(),
			},
			rec: edgerecord.AuthoritativeAssignment{
				Status:        edgerecord.AssignmentAuthorityResolved,
				Record:        &decodedRecord,
				PlanHeaderRaw: rawCarrierHeader,
				// RAW page bytes: the physical page ceiling only exists on received bytes.
				PlanPagesRaw: rawCarrierPages,
			},
		},
		// The SESSION answers as the transport, holding its own attested identity rather than
		// one restated from the bytes under test.
		Session:           goldenSession{networkScopeID: scopeID, agentID: agentID},
		NowUnixNano:       notBefore,
		TrustEpoch:        1,
		ExecutionGrantRaw: rawGrant,
	}
	if err := edgerecord.AuthorizeCollectionNow(&decodedRecord, carrierBytes, authority); err != nil {
		t.Fatalf("golden authorization inside the window: %v", err)
	}
	lapsed := authority
	lapsed.NowUnixNano = expires
	if err := edgerecord.AuthorizeCollectionNow(&decodedRecord, carrierBytes, lapsed); err == nil {
		t.Fatal("collection past the lease must not be authorized")
	}
	revoked := authority
	revoked.Trust = goldenRevokedTrust{pub: pub}
	if err := edgerecord.AuthorizeCollectionNow(&decodedRecord, carrierBytes, revoked); err == nil {
		t.Fatal("a compromise-revoked key must not authorize collection")
	}
	anonymous := authority
	anonymous.Session = goldenSession{}
	if err := edgerecord.AuthorizeCollectionNow(&decodedRecord, carrierBytes, anonymous); err == nil {
		t.Fatal("an unattested caller must not authorize collection")
	}

	// THE EXACT CEILING as shared vectors: 65536 accepted, 65537 rejected. They differ by
	// one byte, decode to the same carrier, and collapse far below the ceiling on
	// re-encode -- which is why a decoded-struct check cannot enforce this bound.
	atLimit := padToExact(t, carrierBytes, c.GetCheckSetSha256(), edgerecord.MaxCompiledAssignmentBytes)
	oneOver := padToExact(t, carrierBytes, c.GetCheckSetSha256(), edgerecord.MaxCompiledAssignmentBytes+1)
	goldenBytes(t, "compiled_assignment_at_ceiling.bin", atLimit)
	goldenBytes(t, "compiled_assignment_over_ceiling.bin", oneOver)
	if _, err := edgerecord.ValidateCompiledSweepAssignmentBytes(atLimit); err != nil {
		t.Fatalf("exactly %d bytes must be accepted: %v", edgerecord.MaxCompiledAssignmentBytes, err)
	}
	if _, err := edgerecord.ValidateCompiledSweepAssignmentBytes(oneOver); !errors.Is(err, edgerecord.ErrCompiledAssignmentTooLarge) {
		t.Fatalf("one over the ceiling = %v, want ErrCompiledAssignmentTooLarge", err)
	}
	for name, padded := range map[string][]byte{"at": atLimit, "over": oneOver} {
		var round edgev1.CompiledSweepAssignmentV1
		if err := proto.Unmarshal(padded, &round); err != nil {
			t.Fatalf("%s-ceiling vector must decode: %v", name, err)
		}
		if !proto.Equal(&round, c) {
			t.Fatalf("%s-ceiling vector must decode to the same carrier", name)
		}
		if proto.Size(&round) > edgerecord.MaxCompiledAssignmentBytes {
			t.Fatalf("%s-ceiling vector did not collapse on re-encode", name)
		}
	}

	// REJECT VECTORS as shared bytes with the EXACT reason pinned. A vector that only
	// proved "some error" would prove no reason parity between the runtimes.
	rejects := []struct {
		name   string
		reason error
		mutate func(*edgev1.CompiledSweepAssignmentV1)
	}{
		{"compiled_reject_body_digest.bin", edgerecord.ErrCompiledAssignmentDigest, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.ConfigGeneration = 8 // body changed, body digest not recomputed
		}},
		{"compiled_reject_artifact_digest.bin", edgerecord.ErrCompiledAssignmentDigest, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.CompiledAssignmentSha256 = digest32(0x8F)
		}},
		{"compiled_reject_no_capability.bin", edgerecord.ErrCompiledAssignmentCapability, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.CollectionCapability = nil
		}},
		{"compiled_reject_wrong_purpose.bin", edgerecord.ErrCapabilityPurpose, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.CollectionCapability.Claims = &edgev1.EdgeSignedCapabilityV1_Production{
				Production: &edgev1.EdgeProductionClaimsV1{},
			}
		}},
		{"compiled_reject_claim_cross_bound.bin", edgerecord.ErrCompiledAssignmentCapability, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.CollectionCapability.GetCollection().ProducerAssignmentId = uuidv7(0x3F)
		}},
		{"compiled_reject_zero_config_generation.bin", edgerecord.ErrCompiledAssignment, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.ConfigGeneration = 0
			x.CompiledAssignmentBodySha256 = nil // recomputed below
		}},
		{"compiled_reject_unknown_result_format.bin", edgerecord.ErrCompiledAssignment, func(x *edgev1.CompiledSweepAssignmentV1) {
			x.ResultFormat = edgev1.SweepResultFormat(99)
			x.CompiledAssignmentBodySha256 = nil
		}},
	}
	var manifest bytes.Buffer
	for _, rc := range rejects {
		bad, okClone := proto.Clone(c).(*edgev1.CompiledSweepAssignmentV1)
		if !okClone {
			t.Fatalf("%s: clone type assertion failed", rc.name)
		}
		rc.mutate(bad)
		// A vector whose body digest was blanked is re-sealed, so the ONLY defect left is
		// the semantic one under test -- not a digest mismatch standing in for it.
		if bad.GetCompiledAssignmentBodySha256() == nil {
			bad.CompiledAssignmentBodySha256 = edgerecord.CompiledAssignmentBodyDigest(bad)
			if cl := bad.GetCollectionCapability().GetCollection(); cl != nil {
				cl.CompiledAssignmentBodySha256 = bad.GetCompiledAssignmentBodySha256()
			}
			if capb := bad.GetCollectionCapability(); capb != nil {
				edgerecord.SignCapability(capb, priv)
			}
			bad.CompiledAssignmentSha256 = edgerecord.CompiledAssignmentArtifactDigest(bad)
		}
		raw := golden(t, rc.name, bad)
		if _, err := edgerecord.ValidateCompiledSweepAssignmentBytes(raw); !errors.Is(err, rc.reason) {
			t.Fatalf("%s = %v, want %v", rc.name, err, rc.reason)
		}
		manifest.WriteString(rc.name + " " + rc.reason.Error() + "\n")
	}
	goldenBytes(t, "compiled_assignment_reject_manifest.txt", manifest.Bytes())
}

// goldenRevokedTrust resolves the golden key as COMPROMISE-REVOKED: the signature still
// verifies, but it must never authorize new work.
type goldenRevokedTrust struct{ pub ed25519.PublicKey }

func (g goldenRevokedTrust) ResolveKey(_, _ []byte, ev edgerecord.KeyEvidence) edgerecord.KeyResolution {
	return edgerecord.KeyResolution{
		Status: edgerecord.KeyHistoricallyRevoked, Public: g.pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
}

// padToExact inflates a carrier encoding to EXACTLY `target` bytes by repeating
// check_set_sha256 -- a known non-repeated field, so the decoder keeps the LAST occurrence
// and the padded bytes decode identically to the original.
func padToExact(t *testing.T, raw, checkSet []byte, target int) []byte {
	t.Helper()
	num := (&edgev1.CompiledSweepAssignmentV1{}).ProtoReflect().
		Descriptor().Fields().ByName("check_set_sha256").Number()
	trueField := protowire.AppendBytes(protowire.AppendTag(nil, num, protowire.BytesType), checkSet)
	fillerTotal := target - len(raw) - len(trueField)
	payloadLen := fillerTotal - 1 - protowire.SizeVarint(uint64(fillerTotal))
	if payloadLen < 0 {
		t.Fatalf("target %d is too small to pad to", target)
	}
	filler := protowire.AppendBytes(protowire.AppendTag(nil, num, protowire.BytesType), make([]byte, payloadLen))
	out := make([]byte, 0, target)
	out = append(out, raw...)
	out = append(out, filler...)
	out = append(out, trueField...)
	if len(out) != target {
		t.Fatalf("padded to %d, want exactly %d", len(out), target)
	}
	return out
}

// TestGoldenCompiledAssignmentSourceAbsent is the SECOND carrier/grant vector, and it exists
// to break two ways the first one is degenerate.
//
// (1) The first vector's grant carries a SOURCE IDENTITY, so the legal ABSENT case -- and the
// presence marker that distinguishes it -- is never exercised from committed bytes.
// (2) In the first vector `digest_version`, `result_format` and `traffic_class` are ALL
// numerically 1, so an implementation that framed them in the wrong slots produces the same
// preimage. Here `traffic_class` is INTERACTIVE (2), which separates it from the other two.
func TestGoldenCompiledAssignmentSourceAbsent(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	hostSeed := make([]byte, ed25519.SeedSize)
	for i := range hostSeed {
		hostSeed[i] = byte(0x80 + i)
	}
	hostPriv := ed25519.NewKeyFromSeed(hostSeed)

	planID, scopeID, agentID := uuidv7(0x41), uuidv7(0x43), uuidv7(0x44)
	rangeID, prodAssignID, execID := uuidv7(0x42), uuidv7(0x45), uuidv7(0x46)
	notBefore, expires := fixedNanos, fixedNanos+1

	c := &edgev1.CompiledSweepAssignmentV1{
		CompiledAssignmentId: uuidv7(0x47),
		DigestVersion:        edgerecord.CompiledAssignmentDigestVersion,
		ProducerAssignmentId: prodAssignID,
		ExecutionId:          execID,
		ExecutionPlanId:      planID,
		ExecutionPlanSha256:  digest32(0x91),
		TargetRangeId:        rangeID,
		TargetRangeSha256:    digest32(0x92),
		NetworkScopeId:       scopeID,
		AuthenticatedAgentId: agentID,
		ExecutionShard:       3,
		AssignmentEpoch:      5,
		ConfigGeneration:     7,
		ResultFormat:         edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1,
		CheckSetSha256:       digest32(0x93),
		// INTERACTIVE (2), deliberately NOT the same number as digest_version/result_format.
		TrafficClass:      edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE,
		NotBeforeUnixNano: notBefore,
		ExpiresAtUnixNano: expires,
	}
	c.CompiledAssignmentBodySha256 = edgerecord.CompiledAssignmentBodyDigest(c)
	c.CollectionCapability = &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("sched"), IssuerKeyId: []byte("k1"),
		Algorithm: "ed25519", NotBeforeUnixNano: notBefore, ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_Collection{
			Collection: &edgev1.EdgeCollectionClaimsV1{
				Purpose:                      edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
				NetworkScopeId:               scopeID,
				AuthenticatedAgentId:         agentID,
				ExecutionPlanId:              planID,
				TargetRangeId:                rangeID,
				ExecutionShard:               3,
				AssignmentEpoch:              5,
				CompiledAssignmentBodySha256: c.GetCompiledAssignmentBodySha256(),
				TrafficClass:                 c.GetTrafficClass(),
				ProducerAssignmentId:         prodAssignID,
				ExecutionId:                  execID,
			},
		},
	}
	edgerecord.SignCapability(c.GetCollectionCapability(), priv)
	c.CompiledAssignmentSha256 = edgerecord.CompiledAssignmentArtifactDigest(c)

	goldenBytes(t, "compiled_assignment_interactive_body_digest.bin", c.GetCompiledAssignmentBodySha256())
	goldenBytes(t, "compiled_assignment_interactive_artifact_digest.bin", c.GetCompiledAssignmentSha256())
	interactiveBytes := golden(t, "compiled_assignment_interactive.bin", c)

	// The grant with NO source identity -- the legal absent case.
	grant := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("host"), IssuerKeyId: []byte("host-exec-1"),
		Algorithm: "ed25519", NotBeforeUnixNano: notBefore, ExpiresAtUnixNano: expires,
		Claims: &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
			AssignmentExecution: &edgev1.EdgeAssignmentExecutionClaimsV1{
				Purpose:                     edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
				NetworkScopeId:              scopeID,
				AuthenticatedAgentId:        agentID,
				ProducerAssignmentId:        prodAssignID,
				ExecutionId:                 execID,
				RunId:                       uuidv7(0x48),
				RunShard:                    3,
				AuthorityEpoch:              5,
				ProductionScopeId:           uuidv7(0x49),
				ScopeSha256:                 digest32(0x94),
				ContractBundleSha256:        digest32(0x95),
				ExecutionPlanSha256:         c.GetExecutionPlanSha256(),
				TargetRangeSha256:           c.GetTargetRangeSha256(),
				TrafficClass:                c.GetTrafficClass(),
				CollectionNotBeforeUnixNano: notBefore,
				CollectionExpiresUnixNano:   expires,
				// SourceIdentity deliberately ABSENT.
				CompiledAssignmentId:     c.GetCompiledAssignmentId(),
				CompiledAssignmentSha256: c.GetCompiledAssignmentSha256(),
			},
		},
	}
	goldenBytes(t, "compiled_assignment_interactive_grant_signing_bytes.bin",
		edgerecord.CapabilitySigningBytes(grant))
	edgerecord.SignCapability(grant, hostPriv)
	golden(t, "compiled_assignment_interactive_grant.bin", grant)

	if grant.GetAssignmentExecution().GetSourceIdentity() != nil {
		t.Fatal("this vector must carry NO source identity, or the absent marker stays unpinned")
	}

	// CROSS-RUNTIME VECTOR: the golden carrier with a well-formed unknown GROUP appended
	// (field 6: 0x33 start / 0x34 end).
	//
	// This pins the DECODER COMPOSITION, which nothing else does. Go's parser RETAINS the
	// group and ValidateCompiledSweepAssignment rejects it via hasUnknownFields.
	// protobuf-elixir ERASES it, so a direct decode returns a carrier indistinguishable from
	// the clean one -- an Elixir validator reading only the decoded struct CANNOT see it.
	// Only the raw path does, which is the whole reason the Elixir entry point routes through
	// the curated WireDecode rather than decoding locally. The Elixir peer asserts
	// {:error, :poison} on these exact bytes.
	carrierWithGroup := append(append([]byte{}, interactiveBytes...), 0x33, 0x34)
	goldenBytes(t, "compiled_assignment_unknown_group.bin", carrierWithGroup)

	var groupCarrier edgev1.CompiledSweepAssignmentV1
	if err := proto.Unmarshal(carrierWithGroup, &groupCarrier); err != nil {
		t.Fatalf("Go must PARSE and retain a well-formed unknown group, not reject it: %v", err)
	}
	if _, err := edgerecord.ValidateCompiledSweepAssignmentBytes(carrierWithGroup); !errors.Is(err, edgerecord.ErrUnknownFields) {
		t.Fatalf("carrier with a retained unknown group = %v, want ErrUnknownFields", err)
	}
}

// goldenAssignmentAuthority answers ONLY for the key it expects. It does not echo an
// arbitrary request: a mirror would make the echo assertion self-fulfilling.
type goldenAssignmentAuthority struct {
	want edgerecord.AssignmentKey
	rec  edgerecord.AuthoritativeAssignment
}

func (g goldenAssignmentAuthority) ResolveAssignment(key edgerecord.AssignmentKey) edgerecord.AuthoritativeAssignment {
	if !bytes.Equal(key.NetworkScopeID, g.want.NetworkScopeID) ||
		!bytes.Equal(key.AuthenticatedAgentID, g.want.AuthenticatedAgentID) ||
		!bytes.Equal(key.ProducerAssignmentID, g.want.ProducerAssignmentID) {
		return edgerecord.AuthoritativeAssignment{Status: edgerecord.AssignmentAuthorityUnknown, Key: key}
	}
	out := g.rec
	out.Key = key
	return out
}

// goldenSession stands in for the transport. Its zero value is UNATTESTED.
type goldenSession struct {
	networkScopeID []byte
	agentID        []byte
}

func (s goldenSession) AuthorizeAgent(networkScopeID, agentID []byte) edgerecord.CallerVerdict {
	if s.networkScopeID == nil && s.agentID == nil {
		return edgerecord.CallerUnattested
	}
	if bytes.Equal(s.networkScopeID, networkScopeID) && bytes.Equal(s.agentID, agentID) {
		return edgerecord.CallerMatches
	}
	return edgerecord.CallerMismatch
}

// The FROZEN rebuild sequence is split across TWO helpers, matching the two halves
// of the contract's own ordering:
//
//	step 1  the caller applies its mutation
//	step 2  mutateSweepBody -- re-encode the body, update BOTH size fields and
//	        payload_sha256. Only body-mutating vectors need it.
//	step 3  rebuildRecord   -- re-sign every capability whose COMPLETE SIGNING
//	        PREIMAGE changed, after re-syncing the outer source-authorization
//	        mirror to the claims it duplicates
//	step 4  rebuildRecord   -- recompute semantic_envelope_sha256 LAST, because the
//	        semantic preimage CONTAINS capability signatures
//
// rebuildRecord below is steps 3-4. Skipping either makes a vector die at signature
// verification or the envelope-digest check, which is a rejection for the wrong
// reason. Not hypothetical: the first draft of these vectors omitted both and every
// case failed on "semantic envelope digest mismatch" or "producer identity" instead
// of its correlation label.
// mutateSweepBody is STEP 2 of the sequence above: re-encode the mutated body and
// update BOTH size fields and payload_sha256. The caller then runs rebuildRecord
// for steps 3-4.
func mutateSweepBody(r *edgev1.EdgeRecordV1, f func(*edgev1.SweepObservationBatchV1)) {
	var b edgev1.SweepObservationBatchV1
	if err := proto.Unmarshal(r.GetPayload(), &b); err != nil {
		panic("golden record payload is not a sweep batch: " + err.Error())
	}
	f(&b)
	payload := mustMarshal(&b)
	sum := sha256.Sum256(payload)
	r.Payload = payload
	r.EncodedSize = uint32(len(payload))
	r.UncompressedSize = uint32(len(payload))
	r.PayloadSha256 = sum[:]
}

func rebuildRecord(r *edgev1.EdgeRecordV1) {
	if sa := r.GetSourceAuthorization(); sa != nil {
		if src := sa.GetCapability().GetSource(); src != nil {
			// The outer mirror MUST agree with the signed claims; the record
			// validator checks that before correlation is ever consulted.
			sa.Kind = src.GetKind()
			sa.ContextId = src.GetContextId()
			sa.ScopeId = src.GetScopeId()
			sa.ScopeSha256 = src.GetScopeSha256()
		}
		edgerecord.SignCapability(sa.GetCapability(), issuerPrivB)
	}
	if pc := r.GetProductionCapability(); pc != nil {
		edgerecord.SignCapability(pc, issuerPrivA)
	}
	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
}

// EACH SPLIT PREDICATE EMITS ITS OWN LABEL.
//
// Five checks in joinSweepAuthority previously covered TWO labels each. Splitting
// them is what makes the labels independently removable, and this test is what
// proves the split is real rather than cosmetic: a re-merged pair would report one
// label for both mutations and fail here.
//
// MOST of these vectors mutate the RECORD's signed claims, so the body's digests
// still hold and only steps 3-4 of the rebuild sequence apply. TWO -- execution
// shard and assignment epoch -- mutate the BODY, and go through mutateSweepBody
// for steps 1-2 as well: they must, because the production capability and the
// source claims both mirror the producer context, so moving the context would be
// refused by those mirrors before correlation.
//
// These assert the LABEL and the OWNING GATE together, and that the error does NOT
// match the other gate. The FIVE TIME labels are not among them: those still have no
// vector pinning them to a gate, which task 1.3-f owns.
// sweepJoinCase is one labelled rejection: the mutation, the portable label it must
// produce, and the gate that must own it.
type sweepJoinCase struct {
	name   string
	want   edgerecord.SweepJoinLabel
	gate   error
	break_ func(*edgev1.EdgeRecordV1)
}

// sweepJoinCases is the ONE table. `TestSweepJoinLabelsAreDistinctPerPredicate` proves each
// case in-process; `TestSweepJoinSharedCorpus` writes the same cases as bytes for Elixir to
// consume. Two tables would let the in-process proof and the shared corpus drift, so that a
// label is pinned in one runtime and never exported to the other.
func sweepJoinCases() []sweepJoinCase {
	return []sweepJoinCase{
		{"absent authority", edgerecord.SweepLabelSourceAuthorityAbsent, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.SourceAuthorization = nil
		}},
		// Mutate the SIGNED claim, not the outer mirror: the mirror is re-synced from
		// the claims during the rebuild, so mutating it alone would be undone.
		{"wrong kind", edgerecord.SweepLabelSourceKind, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().Kind =
				edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC
		}},
		{"context id", edgerecord.SweepLabelContextID, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().ContextId = uuidv7(0x7E)
		}},
		{"range id", edgerecord.SweepLabelRangeID, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().ScopeId = uuidv7(0x7D)
		}},
		{"scope digest", edgerecord.SweepLabelScopeDigest, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().ScopeSha256 = digest32(0x7C)
		}},
		{"target range digest", edgerecord.SweepLabelTargetRangeDigest, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().TargetRangeSha256 = digest32(0x7B)
		}},
		{"plan digest", edgerecord.SweepLabelPlanDigest, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().GetCapability().GetSource().ExecutionPlanSha256 = digest32(0x7A)
		}},
		// These two mutate the BODY's view of the attested producer rather than the
		// producer context, because the production capability and the source claims
		// both mirror the context: moving the context would be refused by those
		// mirrors before correlation, which is a rejection for the wrong reason.
		{"execution shard", edgerecord.SweepLabelExecutionShard, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) { b.ExecutionShard = 99 })
		}},
		{"assignment epoch", edgerecord.SweepLabelAssignmentEpoch, edgerecord.ErrSweepJoin, func(r *edgev1.EdgeRecordV1) {
			mutateSweepBody(r, func(b *edgev1.SweepObservationBatchV1) { b.AssignmentEpoch = 4242 })
		}},
		// THE FIVE TIME LABELS ARE NOT HERE. They live in the SHARED corpus
		// (sweep_corpus_test.go), which asserts the same label/gate/not-other-gate triple
		// AND constructs them as the spec requires: both window sides on all three paths,
		// overflow values that wrap INSIDE the window, and batch-time negatives whose host
		// delta is counter-adjusted so only one comparison differs. The versions that used
		// to sit here satisfied none of that, and a second, weaker construction of the same
		// vectors is worse than none.
	}
}

func TestSweepJoinLabelsAreDistinctPerPredicate(t *testing.T) {
	// Every case pins the label AND the owning gate in ONE assertion. Asserting them
	// in separate tests leaves the PAIR unpinned: a site can emit the right label with
	// the wrong gate, or the reverse, and both tests stay green.
	for _, tc := range sweepJoinCases() {
		t.Run(tc.name, func(t *testing.T) {
			record := canonicalRecord(t)
			// CONTROL: unmutated, this record joins. Without it a vector could pass
			// for a reason unrelated to the mutation.
			if err := edgerecord.ValidateSweepRecord(record, record.GetOutputContract(), goldenPolicy()); err != nil {
				t.Fatalf("control must join: %v", err)
			}
			tc.break_(record)
			rebuildRecord(record)
			err := edgerecord.ValidateSweepRecord(record, record.GetOutputContract(), goldenPolicy())
			if err == nil {
				t.Fatal("mutation must be rejected")
			}
			got, ok := edgerecord.SweepLabelOf(err)
			if !ok {
				t.Fatalf("rejection carries no portable label: %v", err)
			}
			if got != tc.want {
				t.Fatalf("label = %q, want %q (err: %v)", got, tc.want, err)
			}
			// The GATE, asserted here rather than in a separate test, so the two
			// cannot drift apart.
			if !errors.Is(err, tc.gate) {
				t.Fatalf("label %q came from the wrong gate: %v, want errors.Is %v", got, err, tc.gate)
			}
			// And NOT from the other gate -- otherwise a single error wrapping both
			// sentinels would satisfy the check above.
			other := edgerecord.ErrSweepSourceRunID
			if errors.Is(tc.gate, edgerecord.ErrSweepSourceRunID) {
				other = edgerecord.ErrSweepJoin
			}
			if errors.Is(err, other) {
				t.Fatalf("label %q matched BOTH gates: %v", got, err)
			}
		})
	}
}
