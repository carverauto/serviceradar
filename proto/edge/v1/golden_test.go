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
	"os"
	"path/filepath"
	"strings"
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
// enum (production traffic_class = -1). Go marshals it and retains the unknown value on decode; the
// Elixir generated decoder raises on it, so the project-owned total decode boundary must convert it
// to poison/quarantine rather than crash-looping a malformed durable message.
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
// (Serviceradar.Edge.PublicationIdentity) can prove byte-identical header derivation.
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
