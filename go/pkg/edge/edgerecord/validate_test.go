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

package edgerecord

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"google.golang.org/protobuf/reflect/protoreflect"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// TestValidateFrameRawEnvelopeRejectsDuplicateFieldBloat proves the relational envelope budget is
// enforced on EXACT RAW wire bytes: 20 KiB of duplicate `sequence` fields (which proto decode collapses
// last-wins, so proto.Size stays tiny) is rejected by the raw peel even though a decoded-size check
// would miss it.
func TestValidateFrameRawEnvelopeRejectsDuplicateFieldBloat(t *testing.T) {
	// record_bytes (field 5) = 1 byte.
	raw := protowire.AppendTag(nil, protowire.Number(frameRecordBytesFieldNumber), protowire.BytesType)
	raw = protowire.AppendBytes(raw, []byte{0x00})
	// 20 KiB of duplicate sequence (field 2, varint) = 1 -- ~2 bytes each.
	for i := 0; i < 10*1024; i++ {
		raw = protowire.AppendTag(raw, 2, protowire.VarintType)
		raw = protowire.AppendVarint(raw, 1)
	}
	if err := ValidateFrameRawEnvelope(raw); !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("duplicate-field bloat = %v, want ErrFrameTooLarge", err)
	}
	// The DECODED frame is tiny (canonicalized), so proto.Size alone would MISS the bloat -- proving the
	// raw peel is necessary.
	var f edgev1.EdgeDeliveryFrameV1
	if err := proto.Unmarshal(raw, &f); err != nil {
		t.Fatalf("bloated frame must still decode: %v", err)
	}
	if proto.Size(&f) > MaxDeliveryEnvelopeBytes {
		t.Fatalf("decoded frame should canonicalize small, got proto.Size=%d", proto.Size(&f))
	}
	// A minimal frame (record + a 1 KiB envelope) passes the raw check.
	good := protowire.AppendTag(nil, protowire.Number(frameRecordBytesFieldNumber), protowire.BytesType)
	good = protowire.AppendBytes(good, make([]byte, 1024))
	good = protowire.AppendTag(good, 2, protowire.VarintType)
	good = protowire.AppendVarint(good, 1)
	if err := ValidateFrameRawEnvelope(good); err != nil {
		t.Fatalf("small envelope must pass: %v", err)
	}
}

func d32(tag byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = tag + byte(i)
	}
	return b
}

func mustUUID(t *testing.T) []byte {
	t.Helper()
	id, err := NewUUIDv7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	return id
}

// window returns a validity window containing the identity time of id.
func window(t *testing.T, id []byte) (int64, int64) {
	t.Helper()
	ms, err := UUIDv7Millis(id)
	if err != nil {
		t.Fatalf("uuid millis: %v", err)
	}
	ns := ms * 1_000_000
	return ns - 3_600_000_000_000, ns + 3_600_000_000_000
}

// productionCap builds a PRODUCTION grant fully bound to the record's producer
// context, contract, topology, and cost so validateProductionCapability accepts.
func productionCap(t *testing.T, r *edgev1.EdgeRecordV1) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	nb, exp := window(t, r.GetEventId())
	p := r.GetProducerContext()
	c := r.GetOutputContract()
	return &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("issuer"), IssuerKeyId: []byte("key-1"),
		Algorithm: "ed25519", NotBeforeUnixNano: nb, ExpiresAtUnixNano: exp,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId: c.GetContractId(), ContractVersion: c.GetContractVersion(),
			ContractBundleSha256: c.GetContractBundleSha256(), RegistryEpoch: c.GetRegistryEpoch(),
			NetworkScopeId: r.GetNetworkScopeId(), ProducerAssignmentId: p.GetProducerAssignmentId(),
			TrafficClass: r.GetTrafficClass(), RouteProfile: r.GetRouteProfile(),
			OriginKind: p.GetOriginKind(), OriginPrincipalId: p.GetOriginPrincipalId(),
			ProducerInstanceId: p.GetProducerInstanceId(), RunId: p.GetRunId(), RunShard: p.GetRunShard(),
			AuthorityEpoch: p.GetAuthorityEpoch(), ScopeId: p.GetScopeId(), ScopeSha256: p.GetScopeSha256(),
			PackageSha256: p.GetPackageSha256(), RegistrySnapshotSha256: c.GetRegistrySnapshotSha256(),
			EffectiveGrantSha256: c.GetEffectiveGrantSha256(),
			MaxProjectedRowCount: r.GetProjectedRowCount(), MaxProjectedWriteBytes: r.GetProjectedWriteBytes(),
			CostModelVersion: r.GetCostModelVersion(), PackageId: p.GetPackageId(),
		}},
		Signature: []byte("signature"),
	}
}

// sourceCap builds a SOURCE grant fully bound to the record's producer identity,
// topology, and the given context/scope so validateSourceAuthorization accepts.
func sourceCap(t *testing.T, r *edgev1.EdgeRecordV1, context, scopeID []byte, kind edgev1.EdgeSourceAuthorizationKind) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	nb, exp := window(t, r.GetEventId())
	p := r.GetProducerContext()
	return &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("issuer"), IssuerKeyId: []byte("key-1"),
		Algorithm: "ed25519", NotBeforeUnixNano: nb, ExpiresAtUnixNano: exp,
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
			Kind: kind, ContextId: context, ScopeId: scopeID, ScopeSha256: d32(0xAA),
			NetworkScopeId: r.GetNetworkScopeId(), CollectionNotBeforeUnixNano: nb, CollectionExpiresUnixNano: exp,
			OriginPrincipalId: p.GetOriginPrincipalId(), ProducerInstanceId: p.GetProducerInstanceId(),
			ProducerAssignmentId: p.GetProducerAssignmentId(), RunId: p.GetRunId(), RunShard: p.GetRunShard(),
			AuthorityEpoch: p.GetAuthorityEpoch(), TrafficClass: r.GetTrafficClass(), RouteProfile: r.GetRouteProfile(),
			OriginKind: p.GetOriginKind(),
		}},
		Signature: []byte("signature"),
	}
}

func validRecord(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()
	eventID := mustUUID(t)
	scope := mustUUID(t)
	payload := []byte("canonical-contract-payload-bytes")
	sum := sha256.Sum256(payload)
	contract := &edgev1.EdgeOutputContractRef{
		ContractId: "serviceradar.sweep.observation", ContractVersion: 1,
		ContractBundleSha256: d32(0x02), RegistryEpoch: 7,
		RegistrySnapshotSha256: d32(0x03), EffectiveGrantSha256: d32(0x04),
	}
	r := &edgev1.EdgeRecordV1{
		EventId: eventID, PayloadFamily: edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		Compression: edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
		EncodedSize: uint32(len(payload)), UncompressedSize: uint32(len(payload)), PayloadSha256: sum[:],
		OutputContract: contract,
		ProducerContext: &edgev1.EdgeProducerContext{
			OriginKind:        edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId: []byte("principal"), ProducerInstanceId: []byte("instance"),
			ProducerAssignmentId: mustUUID(t), RunId: mustUUID(t), RunShard: 3,
			AuthorityEpoch: proto.Uint64(5), ScopeId: mustUUID(t), ScopeSha256: d32(0x06),
			PackageId: "serviceradar.core.sweep", PackageSha256: d32(0x05),
		},
		RouteProfile:      edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass:      edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		NetworkScopeId:    scope,
		ProjectedRowCount: 3, ProjectedWriteBytes: 2048, CostModelVersion: 2, Payload: payload,
	}
	r.ProductionCapability = productionCap(t, r)
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)
	return r
}

func reseal(r *edgev1.EdgeRecordV1) { r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r) }

func TestValidateRecordAcceptsCanonical(t *testing.T) {
	if err := ValidateRecord(validRecord(t)); err != nil {
		t.Fatalf("canonical record must validate: %v", err)
	}
}

// Reviewer repro (r3-01): a production grant for assignment A paired with producer
// context B must be rejected.
func TestProductionAuthorityBoundToAssignment(t *testing.T) {
	r := validRecord(t)
	r.GetProducerContext().ProducerAssignmentId = mustUUID(t) // different attested assignment
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrProductionGrant) {
		t.Fatalf("assignment replay = %v, want ErrProductionGrant", err)
	}
	// Cost ceiling: a record projecting beyond the signed maximum is rejected.
	r2 := validRecord(t)
	r2.ProjectedRowCount = r2.GetProductionCapability().GetProduction().GetMaxProjectedRowCount() + 1
	reseal(r2)
	if err := ValidateRecord(r2); !errors.Is(err, ErrProductionGrant) {
		t.Fatalf("cost ceiling = %v, want ErrProductionGrant", err)
	}
}

// Reviewer repro: payload substitution with stale checksum/size must be rejected.
func TestValidateRecordBindsPayloadBytes(t *testing.T) {
	r := validRecord(t)
	r.Payload = []byte("attacker-substituted-payload-of-different-length")
	if err := ValidateRecord(r); err == nil {
		t.Fatal("substituted payload must be rejected")
	}
	r2 := validRecord(t)
	r2.Payload = []byte("another-substituted-payload")
	r2.EncodedSize = uint32(len(r2.Payload))
	r2.UncompressedSize = uint32(len(r2.Payload))
	reseal(r2)
	if err := ValidateRecord(r2); !errors.Is(err, ErrPayloadDigest) {
		t.Fatalf("size-corrected substitution = %v, want ErrPayloadDigest", err)
	}
}

// Reviewer repro (r3-05): a record retaining an unknown top-level protobuf field
// must be rejected by ValidateRecord, not only by the raw canonical decode.
func TestValidateRecordRejectsUnknownFields(t *testing.T) {
	r := validRecord(t)
	canon, _ := CanonicalRecordBytes(r)
	unknown := append(append([]byte{}, canon...), 0xF8, 0x3F, 0x01) // field 127 varint
	var decoded edgev1.EdgeRecordV1
	if err := proto.Unmarshal(unknown, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if err := ValidateRecord(&decoded); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("in-memory unknown field = %v, want ErrUnknownFields", err)
	}
}

// Reviewer repro: a full record whose payload is exactly 512 KiB validates only
// on len(payload) but encodes above MaxRecordBytes; ValidateRecord must reject it.
func TestValidateRecordEnforcesFullRecordBound(t *testing.T) {
	r := validRecord(t)
	big := make([]byte, MaxRecordBytes)
	r.Payload = big
	r.EncodedSize = uint32(len(big))
	r.UncompressedSize = uint32(len(big))
	sum := sha256.Sum256(big)
	r.PayloadSha256 = sum[:]
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrRecordTooLarge) {
		t.Fatalf("full-record bound = %v, want ErrRecordTooLarge", err)
	}
}

// Reviewer repro: compression=ZSTD on a non-zstd payload must be rejected, and a
// real frame with trailing/empty-second/skippable-frame data must be rejected.
func TestValidateRecordZstdMustBeRealFrame(t *testing.T) {
	r := validRecord(t)
	r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrZstdInvalid) && !errors.Is(err, ErrUncompressedSize) && !errors.Is(err, ErrZstdOutputSize) {
		t.Fatalf("non-zstd payload = %v, want a zstd rejection", err)
	}

	enc, _ := zstd.NewWriter(nil)
	original := []byte("the quick brown fox jumps over the lazy dog, repeatedly and at length")
	frame := enc.EncodeAll(original, nil)
	_ = enc.Close()
	makeZstd := func(payload []byte, uncompressed int) *edgev1.EdgeRecordV1 {
		r := validRecord(t)
		r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD
		r.Payload = payload
		r.EncodedSize = uint32(len(payload))
		r.UncompressedSize = uint32(uncompressed)
		s := sha256.Sum256(payload)
		r.PayloadSha256 = s[:]
		reseal(r)
		return r
	}
	if err := ValidateRecord(makeZstd(frame, len(original))); err != nil {
		t.Fatalf("valid zstd frame: %v", err)
	}
	// Trailing byte.
	if err := ValidateRecord(makeZstd(append(append([]byte{}, frame...), 0x00), len(original))); !errors.Is(err, ErrZstdTrailing) {
		t.Fatalf("trailing byte = %v, want ErrZstdTrailing", err)
	}
	// Empty concatenated second frame.
	empty := (func() []byte { e, _ := zstd.NewWriter(nil); b := e.EncodeAll(nil, nil); _ = e.Close(); return b })()
	if err := ValidateRecord(makeZstd(append(append([]byte{}, frame...), empty...), len(original))); !errors.Is(err, ErrZstdTrailing) {
		t.Fatalf("empty second frame = %v, want ErrZstdTrailing", err)
	}
	// Zero-length skippable trailing frame (magic 0x184D2A50 + size 0).
	skippable := []byte{0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00}
	if err := ValidateRecord(makeZstd(append(append([]byte{}, frame...), skippable...), len(original))); !errors.Is(err, ErrZstdTrailing) {
		t.Fatalf("skippable trailing frame = %v, want ErrZstdTrailing", err)
	}
}

func TestValidateRecordFailsClosed(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*edgev1.EdgeRecordV1)
		want error
	}{
		{"unspecified family", func(r *edgev1.EdgeRecordV1) {
			r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED
		}, ErrPayloadFamily},
		{"unspecified compression", func(r *edgev1.EdgeRecordV1) {
			r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_UNSPECIFIED
		}, ErrCompression},
		{"missing capability", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability = nil }, ErrCapabilityMissing},
		{"grant mismatch", func(r *edgev1.EdgeRecordV1) { r.GetProductionCapability().GetProduction().NetworkScopeId = mustUUID(t) }, ErrProductionGrant},
		{"incomplete producer", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.RunId = []byte{1, 2, 3} }, ErrProducerContext},
		{"bad network scope", func(r *edgev1.EdgeRecordV1) { r.NetworkScopeId = []byte{1} }, ErrNetworkScope},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := validRecord(t)
			c.mut(r)
			reseal(r)
			if err := ValidateRecord(r); !errors.Is(err, c.want) {
				t.Fatalf("got %v, want %v", err, c.want)
			}
		})
	}
}

// Capability role confusion: a production capability presented as source is
// rejected because the purpose (claims variant) is bound into validation.
func TestCapabilityRoleConfusion(t *testing.T) {
	r := validRecord(t)
	prod := r.GetProductionCapability() // a PRODUCTION-purpose capability
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: prod, ContextId: mustUUID(t), ScopeId: mustUUID(t), ScopeSha256: d32(0xAA),
	}
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrSourceAuthorization) {
		t.Fatalf("production cap as source = %v, want ErrSourceAuthorization", err)
	}
}

func TestSourceAuthorizationOuterMatchesClaims(t *testing.T) {
	r := validRecord(t)
	ctx := mustUUID(t)
	scopeID := mustUUID(t)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, r, ctx, scopeID, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scopeID, ScopeSha256: d32(0xAA),
	}
	reseal(r)
	if err := ValidateRecord(r); err != nil {
		t.Fatalf("matching source auth: %v", err)
	}
	// Widen the outer context beyond the signed claims -> rejected.
	r.SourceAuthorization.ContextId = mustUUID(t)
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrSourceAuthorization) {
		t.Fatalf("outer/claims mismatch = %v, want ErrSourceAuthorization", err)
	}
}

func TestIdentityTimeOutsideWindow(t *testing.T) {
	r := validRecord(t)
	// Move the capability window entirely into the past.
	r.GetProductionCapability().NotBeforeUnixNano = 1000
	r.GetProductionCapability().ExpiresAtUnixNano = 2000
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrIdentityTime) {
		t.Fatalf("identity time outside window = %v, want ErrIdentityTime", err)
	}
}

func TestRecoveryLaneMatrix(t *testing.T) {
	// Recovery payload on a non-recovery route is rejected.
	r := validRecord(t)
	r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
	reseal(r)
	if err := ValidateRecord(r); !errors.Is(err, ErrRecoveryLane) {
		t.Fatalf("recovery payload on durable route = %v, want ErrRecoveryLane", err)
	}
	// Recovery route without recovery payload is rejected.
	r2 := validRecord(t)
	r2.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	r2.GetProductionCapability().GetProduction().RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	reseal(r2)
	if err := ValidateRecord(r2); !errors.Is(err, ErrRecoveryLane) {
		t.Fatalf("recovery route without recovery payload = %v, want ErrRecoveryLane", err)
	}
}

// Reviewer repro (r3-11): a cumulative ACK cannot reclaim a sent window with no
// dispositions, nor beyond the sent window, and each disposition must match the
// sent event id.
func TestValidateAckExplicitDispositions(t *testing.T) {
	e5, e6 := mustUUID(t), mustUUID(t)
	sess := Session{
		SpoolID: mustUUID(t), Nonce: mustUUID(t), NextSequence: 7, HighestSent: 6, ResolvedThrough: 4,
		SentEvents: map[uint64][]byte{5: e5, 6: e6},
	}
	// Resolving past the sent window is rejected.
	if err := ValidateAck(&edgev1.EdgeDeliveryAckV1{SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: ^uint64(0)}, sess, 100, 1<<16); !errors.Is(err, ErrAckWindow) {
		t.Fatalf("MaxUint64 watermark = %v, want ErrAckWindow", err)
	}
	// Advancing the watermark with NO dispositions is rejected.
	if err := ValidateAck(&edgev1.EdgeDeliveryAckV1{SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 6}, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("empty dispositions resolving a window = %v, want ErrDisposition", err)
	}
	// Exact contiguous coverage with matching sent event ids validates; the
	// permanent rejection carries a bounded machine-token code.
	good := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 6,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 5, EventId: e5, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
			{Sequence: 6, EventId: e6, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT, RejectionCode: "POISON"},
		},
	}
	if err := ValidateAck(good, sess, 100, 1<<16); err != nil {
		t.Fatalf("valid ack: %v", err)
	}
	// A disposition naming the wrong event id is rejected.
	good.Dispositions[0].EventId = mustUUID(t)
	if err := ValidateAck(good, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("wrong event id = %v, want ErrDisposition", err)
	}
	good.Dispositions[0].EventId = e5 // restore
	// All three accepted outcomes resolve the slot.
	for _, k := range []edgev1.EdgeRecordDispositionKind{
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
		edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE,
	} {
		good.Dispositions[0].Kind = k
		if err := ValidateAck(good, sess, 100, 1<<16); err != nil {
			t.Fatalf("accepted kind %v must validate: %v", k, err)
		}
	}
	good.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE // restore
	// An accepted disposition carrying a rejection code is contradictory.
	good.Dispositions[0].RejectionCode = "NOPE"
	if err := ValidateAck(good, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("accept with rejection code = %v, want ErrDisposition", err)
	}
	good.Dispositions[0].RejectionCode = "" // restore
	// Permanent rejection MUST carry a bounded machine token: an empty code and a
	// non-token (lowercase/space) code are both rejected.
	good.Dispositions[1].RejectionCode = ""
	if err := ValidateAck(good, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("permanent rejection without code = %v, want ErrDisposition", err)
	}
	good.Dispositions[1].RejectionCode = "not a token"
	if err := ValidateAck(good, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("non machine-token code = %v, want ErrDisposition", err)
	}
	good.Dispositions[1].RejectionCode = "POISON" // restore

	// A RETRYABLE tail IS encodable (reviewer P0): seq 5 resolves, seq 6 is
	// retryable with its WOULD_BLOCK code, and resolved_through advances only across
	// the resolving prefix (5), leaving seq 6 unresolved.
	retryTail := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 5,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 5, EventId: e5, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
			{Sequence: 6, EventId: e6, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: "WOULD_BLOCK"},
		},
	}
	if err := ValidateAck(retryTail, sess, 100, 1<<16); err != nil {
		t.Fatalf("retryable tail must be encodable: %v", err)
	}
	// Counting the retryable sequence as resolved (resolved_through past the
	// resolving prefix) is rejected.
	retryTail.ResolvedThroughSequence = 6
	if err := ValidateAck(retryTail, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("retryable counted as resolved = %v, want ErrDisposition", err)
	}
	// A resolving outcome after a retryable one is impossible.
	afterRetry := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 4,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 5, EventId: e5, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: "WOULD_BLOCK"},
			{Sequence: 6, EventId: e6, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
		},
	}
	if err := ValidateAck(afterRetry, sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("resolving after retryable = %v, want ErrDisposition", err)
	}
	// Reviewer repro (r4-11): the byte budget is the ACTUAL encoded size, and a
	// zero max applies the hard default, never "unlimited".
	sz := proto.Size(good)
	if err := ValidateAck(good, sess, 100, sz-1); !errors.Is(err, ErrDisposition) {
		t.Fatalf("encoded-size budget = %v, want ErrDisposition", err)
	}
	if err := ValidateAck(good, sess, 100, sz); err != nil {
		t.Fatalf("exact encoded budget: %v", err)
	}
}

func TestValidateAckOverflowAndCoverage(t *testing.T) {
	e1, e2, e3 := mustUUID(t), mustUUID(t), mustUUID(t)
	sess := Session{
		SpoolID: mustUUID(t), Nonce: mustUUID(t), NextSequence: 4, HighestSent: 3, ResolvedThrough: 0,
		SentEvents: map[uint64][]byte{1: e1, 2: e2, 3: e3},
	}
	ack := func(rt uint64, disps ...*edgev1.EdgeRecordDisposition) *edgev1.EdgeDeliveryAckV1 {
		return &edgev1.EdgeDeliveryAckV1{SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: rt, Dispositions: disps}
	}
	retry := func(seq uint64, ev []byte) *edgev1.EdgeRecordDisposition {
		return &edgev1.EdgeRecordDisposition{Sequence: seq, EventId: ev,
			Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: "WOULD_BLOCK"}
	}

	// Zero-progress, single retryable (the original required shape): rt stays 0.
	if err := ValidateAck(ack(0, retry(1, e1)), sess, 100, 1<<16); err != nil {
		t.Fatalf("zero-progress single retryable: %v", err)
	}
	// Multiple retryables, still zero progress.
	if err := ValidateAck(ack(0, retry(1, e1), retry(2, e2)), sess, 100, 1<<16); err != nil {
		t.Fatalf("multiple retryables: %v", err)
	}
	// Non-contiguous / skipped sequence (starts at 2 with ResolvedThrough 0).
	if err := ValidateAck(ack(0, retry(2, e2)), sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("skipped sequence: want ErrDisposition, got %v", err)
	}
	// Unsent event: contiguous seq 1 but an event id the sender never transmitted.
	if err := ValidateAck(ack(0, retry(1, mustUUID(t))), sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("unsent event id: want ErrDisposition, got %v", err)
	}
	// Unspecified and unknown kinds are rejected.
	unspec := &edgev1.EdgeRecordDisposition{Sequence: 1, EventId: e1}
	if err := ValidateAck(ack(0, unspec), sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("unspecified kind: want ErrDisposition, got %v", err)
	}
	unknown := &edgev1.EdgeRecordDisposition{Sequence: 1, EventId: e1, Kind: edgev1.EdgeRecordDispositionKind(99)}
	if err := ValidateAck(ack(0, unknown), sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("unknown kind: want ErrDisposition, got %v", err)
	}
	// Raw pre-decode wire guard (bounds parse cost before decode).
	if err := ValidateAckRawSize(make([]byte, 10), 8); !errors.Is(err, ErrDisposition) {
		t.Fatalf("raw-size over limit: want ErrDisposition, got %v", err)
	}
	if err := ValidateAckRawSize(make([]byte, 8), 8); err != nil {
		t.Fatalf("raw-size within limit: %v", err)
	}

	// A pre-decode rejection may OMIT event_id (the gateway couldn't read the inner
	// id of an oversize/undecodable frame); it binds to session/spool/sequence.
	permNoID := &edgev1.EdgeRecordDisposition{Sequence: 1,
		Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT, RejectionCode: "OVERSIZE"}
	if err := ValidateAck(ack(1, permNoID), sess, 100, 1<<16); err != nil {
		t.Fatalf("pre-decode permanent without event id: %v", err)
	}
	retryNoID := &edgev1.EdgeRecordDisposition{Sequence: 1,
		Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: "WOULD_BLOCK"}
	if err := ValidateAck(ack(0, retryNoID), sess, 100, 1<<16); err != nil {
		t.Fatalf("pre-decode retryable without event id: %v", err)
	}
	// An ACCEPT without an event id is rejected: an accept must have decoded the record.
	acceptNoID := &edgev1.EdgeRecordDisposition{Sequence: 1,
		Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE}
	if err := ValidateAck(ack(1, acceptNoID), sess, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("accept without event id: want ErrDisposition, got %v", err)
	}

	// Reviewer P2 overflow counterexample: an exhausted session (ResolvedThrough =
	// HighestSent = MaxUint64) must not let ResolvedThrough+1 wrap to sequence 0 and
	// validate a bogus ack for a slot that cannot exist.
	maxU := ^uint64(0)
	exhausted := Session{
		SpoolID: sess.SpoolID, Nonce: sess.Nonce, NextSequence: maxU, HighestSent: maxU, ResolvedThrough: maxU,
		SentEvents: map[uint64][]byte{0: e1},
	}
	overflow := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: maxU,
		Dispositions: []*edgev1.EdgeRecordDisposition{retry(0, e1)},
	}
	if err := ValidateAck(overflow, exhausted, 100, 1<<16); !errors.Is(err, ErrDisposition) {
		t.Fatalf("sequence exhaustion overflow: want ErrDisposition, got %v", err)
	}
}

// A retained unknown field on the delivery frame OR its nested signed delivery
// capability is outside the field-framed signature and MUST be rejected recursively.
func TestFrameAndCapabilityRejectUnknownFields(t *testing.T) {
	r := validRecord(t)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	unknown := func(b []byte) []byte { return append(append([]byte{}, b...), 0xF8, 0x3F, 0x01) } // field 127

	// Top-level unknown field on the frame.
	base := &edgev1.EdgeDeliveryFrameV1{SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb}
	fb, _ := proto.Marshal(base)
	var badFrame edgev1.EdgeDeliveryFrameV1
	if err := proto.Unmarshal(unknown(fb), &badFrame); err != nil {
		t.Fatalf("decode frame: %v", err)
	}
	if err := ValidateDeliveryFrame(&badFrame, false); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("frame unknown field: want ErrUnknownFields, got %v", err)
	}

	// Unknown field NESTED in the signed delivery capability (recursion through the
	// frame): a decoded capability that retains an unknown field fails validation.
	dcb, _ := proto.Marshal(&edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("issuer"), IssuerKeyId: []byte("key-1"), Algorithm: "ed25519",
	})
	var badCap edgev1.EdgeSignedCapabilityV1
	if err := proto.Unmarshal(unknown(dcb), &badCap); err != nil {
		t.Fatalf("decode cap: %v", err)
	}
	nested := &edgev1.EdgeDeliveryFrameV1{
		SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb, DeliveryCapability: &badCap,
	}
	if err := ValidateDeliveryFrame(nested, false); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("nested delivery capability unknown field: want ErrUnknownFields, got %v", err)
	}

	// The standalone capability validator rejects it too.
	if err := ValidateCapability(&badCap, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("capability unknown field: want ErrUnknownFields, got %v", err)
	}
}

// Reviewer repro (r4-11): a reconnect must be able to REPLAY an unresolved
// sequence below the next-allocation, but not go below the replay window or beyond
// the next new sequence.
func TestValidateFrameReplayWindow(t *testing.T) {
	r := validRecord(t)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	spool := mustUUID(t)
	frame := func(seq uint64) *edgev1.EdgeDeliveryFrameV1 {
		return &edgev1.EdgeDeliveryFrameV1{SpoolId: spool, Sequence: seq, RecordSha256: sum[:], RecordBytes: rb}
	}
	s := Session{
		RouteProfile: r.GetRouteProfile(), TrafficClass: r.GetTrafficClass(), SpoolID: spool,
		FirstUnresolved: 1, NextSequence: 2, HighestSent: 1,
	}
	// Retransmit of unresolved sequence 1 (below NextSequence) is allowed.
	if err := ValidateFrameForSession(frame(1), s); err != nil {
		t.Fatalf("retransmit sequence 1 must be allowed: %v", err)
	}
	// The next new sequence is allowed.
	if err := ValidateFrameForSession(frame(2), s); err != nil {
		t.Fatalf("next sequence 2 must be allowed: %v", err)
	}
	// Sequence 0 is invalid at the frame level; beyond the next allocation and
	// (with a higher window) below the replay window are rejected.
	if err := ValidateFrameForSession(frame(0), s); !errors.Is(err, ErrDeliverySequence) {
		t.Fatalf("sequence 0 = %v, want ErrDeliverySequence", err)
	}
	if err := ValidateFrameForSession(frame(3), s); !errors.Is(err, ErrAckWindow) {
		t.Fatalf("sequence 3 = %v, want ErrAckWindow", err)
	}
	// A retransmit below the replay window is rejected.
	s2 := s
	s2.FirstUnresolved, s2.NextSequence, s2.HighestSent = 5, 6, 5
	if err := ValidateFrameForSession(frame(4), s2); !errors.Is(err, ErrAckWindow) {
		t.Fatalf("sequence below replay window = %v, want ErrAckWindow", err)
	}
}

func TestValidateDeliveryFrameCanonical(t *testing.T) {
	r := validRecord(t)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	f := &edgev1.EdgeDeliveryFrameV1{SpoolId: mustUUID(t), Sequence: 1, RecordSha256: sum[:], RecordBytes: rb}
	if err := ValidateDeliveryFrame(f, true); err != nil {
		t.Fatalf("delivery frame: %v", err)
	}
	f.RecordSha256 = d32(0xEE)
	if err := ValidateDeliveryFrame(f, true); !errors.Is(err, ErrRecordChecksum) {
		t.Fatalf("bad checksum = %v, want ErrRecordChecksum", err)
	}
}

// Reviewer repro (r3-02): a delivery capability is bound to the exact sequence, so
// the same grant cannot drain the same bytes at another sequence.
func TestDeliveryCapabilityBindsSequence(t *testing.T) {
	r := validRecord(t)
	rb, _ := CanonicalRecordBytes(r)
	sum := sha256.Sum256(rb)
	spool := mustUUID(t)
	dc := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("issuer"), IssuerKeyId: []byte("key-1"), Algorithm: "ed25519",
		NotBeforeUnixNano: 1, ExpiresAtUnixNano: 1 << 62,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
			EventId: r.GetEventId(), RecordSha256: sum[:], SpoolId: spool, Sequence: 1,
			Transition: &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{
				RecoveryId: mustUUID(t), PriorSpoolId: mustUUID(t), PriorSequence: 7,
			}},
		}},
		Signature: []byte("sig"),
	}
	// Frame at sequence 2 with a capability bound to sequence 1 is rejected.
	f := &edgev1.EdgeDeliveryFrameV1{SpoolId: spool, Sequence: 2, RecordSha256: sum[:], RecordBytes: rb, DeliveryCapability: dc}
	if err := ValidateDeliveryFrame(f, false); !errors.Is(err, ErrRecordChecksum) {
		t.Fatalf("sequence mismatch = %v, want ErrRecordChecksum", err)
	}
	// Correct sequence validates.
	f.Sequence = 1
	if err := ValidateDeliveryFrame(f, false); err != nil {
		t.Fatalf("sequence-bound delivery cap: %v", err)
	}
}

func TestDecodeRecordRejectsUnknownButToleratesNonCanonical(t *testing.T) {
	r := validRecord(t)
	canon, _ := CanonicalRecordBytes(r)
	if _, err := DecodeRecord(canon); err != nil {
		t.Fatalf("canonical decode: %v", err)
	}
	// Unknown fields are still rejected (a later reader could reinterpret them).
	unknown := append(append([]byte{}, canon...), 0xF8, 0x3F, 0x01) // unknown field 127
	if _, err := DecodeRecord(unknown); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("unknown field = %v, want ErrUnknownFields", err)
	}
	// A NON-canonical re-encoding of the SAME record (field 1 event_id, tag 0x0A,
	// repeated with its identical value -- last-wins, so the decode is unchanged)
	// is now TOLERATED: the prohibited decode->re-encode->bytes.Equal admission was
	// removed. Record identity is record_sha256 over the EXACT bytes plus the
	// field-framed semantic digest, never byte-canonicity.
	nonCanonical := append([]byte{}, canon...)
	nonCanonical = append(nonCanonical, 0x0A, byte(len(r.GetEventId())))
	nonCanonical = append(nonCanonical, r.GetEventId()...)
	decoded, err := DecodeRecord(nonCanonical)
	if err != nil {
		t.Fatalf("non-canonical (duplicate field) re-encode must be tolerated, got %v", err)
	}
	if string(decoded.GetEventId()) != string(r.GetEventId()) {
		t.Fatal("tolerated non-canonical record must decode to the same event id")
	}
}

func TestSemanticDigestPresence(t *testing.T) {
	a := validRecord(t)
	b := validRecord(t)
	b.ProducerContext = proto.Clone(a.ProducerContext).(*edgev1.EdgeProducerContext)
	b.OutputContract = a.OutputContract
	b.NetworkScopeId = a.NetworkScopeId
	b.ProductionCapability = a.ProductionCapability
	b.EventId = a.EventId
	b.Payload = a.Payload
	b.PayloadSha256 = a.PayloadSha256
	// Same record but present-zero authority_epoch vs the cloned value.
	epoch := uint64(0)
	b.ProducerContext.AuthorityEpoch = &epoch
	if string(SemanticEnvelopeDigest(a)) == string(SemanticEnvelopeDigest(b)) {
		t.Fatal("present-5 vs present-zero authority_epoch must differ in the digest")
	}
}

// The RETURN path is part of the same frozen ABI: both ACK validators must reject recursively
// retained unknown fields. Without this an older sender reclaims spool state while silently
// ignoring a future/unsupported qualifier it never evaluated.
func TestAckValidatorsRejectRetainedUnknownFields(t *testing.T) {
	e5 := mustUUID(t)
	sess := Session{
		SpoolID: mustUUID(t), Nonce: mustUUID(t), NextSequence: 6, HighestSent: 5, ResolvedThrough: 4,
		SentEvents: map[uint64][]byte{5: e5},
	}
	ack := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 5,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 5, EventId: e5, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
		},
	}
	// Control: the ack validates before any unknown field is introduced.
	if err := ValidateAck(ack, sess, 100, 1<<16); err != nil {
		t.Fatalf("control ack must validate: %v", err)
	}

	// ROOT-level ordinary unknown field 15 (0x78 0x01), retained by proto.Unmarshal.
	rootUnknown := reparseWithSuffix(t, ack, []byte{0x78, 0x01})
	if len(rootUnknown.ProtoReflect().GetUnknown()) == 0 {
		t.Fatal("Go must RETAIN the unknown field so validation can see it")
	}
	if err := ValidateAck(rootUnknown, sess, 100, 1<<16); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("ack with a root unknown field = %v, want ErrUnknownFields", err)
	}

	// NESTED unknown field inside an EdgeRecordDisposition: the check must be recursive.
	nested := proto.Clone(ack).(*edgev1.EdgeDeliveryAckV1)
	nestedDisp := reparseWithSuffix(t, nested.GetDispositions()[0], []byte{0x78, 0x01})
	nested.Dispositions = []*edgev1.EdgeRecordDisposition{nestedDisp}
	if err := ValidateAck(nested, sess, 100, 1<<16); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("ack with a NESTED unknown field = %v, want ErrUnknownFields", err)
	}

	// The lane-open ACK shares the policy.
	req := &edgev1.EdgeRecordLaneOpen{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		SpoolId:      sess.SpoolID, SequenceBase: 1, FirstUnresolvedSequence: 1,
		SessionNonce: sess.Nonce, RequestedByteCredits: 1 << 20, RequestedFrameCredits: 256,
	}
	laneAck := &edgev1.EdgeRecordLaneOpenAck{
		RouteProfile: req.GetRouteProfile(), TrafficClass: req.GetTrafficClass(),
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce,
		GrantedByteCredits: 1 << 20, GrantedFrameCredits: 256,
	}
	if err := ValidateLaneOpenAck(reparseWithSuffix(t, laneAck, []byte{0x78, 0x01}), req); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("lane-open ack with an unknown field = %v, want ErrUnknownFields", err)
	}
}

// reparseWithSuffix marshals m, appends raw wire bytes, and re-parses so the extra bytes are
// RETAINED as unknown fields exactly as they would arrive from a future peer.
func reparseWithSuffix[T proto.Message](t *testing.T, m T, suffix []byte) T {
	t.Helper()

	raw, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	out, ok := m.ProtoReflect().Type().New().Interface().(T)
	if !ok {
		t.Fatal("unexpected message type")
	}

	if err := proto.Unmarshal(append(raw, suffix...), out); err != nil {
		t.Fatalf("Go must RETAIN a well-formed unknown field, not reject it: %v", err)
	}

	return out
}

// The gateway-to-agent envelope and the grammar-covered plan/recovery validators must reject
// recursively retained unknown fields too, or the return path and the content-addressed plan path
// stay asymmetric with the recursive client-message boundary.
func TestServerWrapperAndGrammarValidatorsRejectUnknownFields(t *testing.T) {
	unknown := []byte{0x78, 0x01} // ordinary field 15, varint
	group := []byte{0x33, 0x34}   // well-formed unknown GROUP (field 6)

	// --- server envelope: unknown bytes live on the WRAPPER, not the extracted ack ---
	e5 := mustUUID(t)
	sess := Session{
		SpoolID: mustUUID(t), Nonce: mustUUID(t), NextSequence: 6, HighestSent: 5, ResolvedThrough: 4,
		SentEvents: map[uint64][]byte{5: e5},
	}
	ack := &edgev1.EdgeDeliveryAckV1{
		SpoolId: sess.SpoolID, SessionNonce: sess.Nonce, ResolvedThroughSequence: 5,
		Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 5, EventId: e5, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
		},
	}
	server := &edgev1.EdgeRecordServerMessage{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: ack}}

	if err := ValidateServerMessage(server); err != nil {
		t.Fatalf("control server message must validate: %v", err)
	}

	for name, suffix := range map[string][]byte{"ordinary": unknown, "group": group} {
		tainted := reparseWithSuffix(t, server, suffix)
		if len(tainted.ProtoReflect().GetUnknown()) == 0 {
			t.Fatalf("%s: Go must RETAIN the wrapper unknown bytes", name)
		}
		// The inner ack alone is CLEAN -- which is exactly why the wrapper needs its own boundary.
		if err := ValidateAck(tainted.GetAck(), sess, 100, 1<<16); err != nil {
			t.Fatalf("%s: inner ack unexpectedly rejected: %v", name, err)
		}
		if err := ValidateServerMessage(tainted); !errors.Is(err, ErrUnknownFields) {
			t.Fatalf("%s: wrapper unknown field = %v, want ErrUnknownFields", name, err)
		}
	}

	// --- grammar-covered plan / recovery validators ---
	header, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256, 256}, {512}})
	if err := ValidatePlanHeader(header); err != nil {
		t.Fatalf("control plan header must validate: %v", err)
	}

	if err := ValidatePlanHeader(reparseWithSuffix(t, header, unknown)); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("plan header with unknown field must be rejected before hashing")
	}

	taintedPages := append([]*edgev1.ScheduledPlanPageV1{}, pages...)
	taintedPages[0] = reparseWithSuffix(t, pages[0], unknown)

	if err := ValidatePlanPages(header, taintedPages); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("plan page with unknown field must be rejected before hashing")
	}
}

// The server envelope must carry exactly ONE SET variant, and the exactly-one-OCCURRENCE rule needs
// a RAW boundary because the decoded struct has already collapsed duplicates last-one-wins.
func TestValidateServerMessageOneofAndRawEnvelope(t *testing.T) {
	if err := ValidateServerMessage(nil); !errors.Is(err, ErrNilRecord) {
		t.Fatalf("nil wrapper = %v, want ErrNilRecord", err)
	}
	// Unset oneof.
	if err := ValidateServerMessage(&edgev1.EdgeRecordServerMessage{}); !errors.Is(err, ErrNilRecord) {
		t.Fatalf("unset payload = %v, want ErrNilRecord", err)
	}
	// TYPED-NIL inner messages: the variant is set but carries nothing to validate.
	typedNils := []*edgev1.EdgeRecordServerMessage{
		{Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: nil}},
		{Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: nil}},
	}
	for i, m := range typedNils {
		if err := ValidateServerMessage(m); !errors.Is(err, ErrNilRecord) {
			t.Fatalf("typed-nil variant %d = %v, want ErrNilRecord", i, err)
		}
	}
	// Control: a set variant validates.
	ok := &edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_Ack{Ack: &edgev1.EdgeDeliveryAckV1{}},
	}
	if err := ValidateServerMessage(ok); err != nil {
		t.Fatalf("control server message = %v, want nil", err)
	}

	// RAW envelope: exactly one payload occurrence.
	laneAck := mustMarshalT(t, &edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: &edgev1.EdgeRecordLaneOpenAck{}},
	})
	ackRaw := mustMarshalT(t, ok)

	if err := ValidateServerMessageRawEnvelope(ackRaw); err != nil {
		t.Fatalf("single-payload envelope = %v, want nil", err)
	}
	// Concatenation decodes last-one-wins into ONE valid ack, so only the raw check can see it.
	dup := append(append([]byte{}, laneAck...), ackRaw...)

	var decoded edgev1.EdgeRecordServerMessage
	if err := proto.Unmarshal(dup, &decoded); err != nil {
		t.Fatalf("duplicate envelope must still DECODE (last-one-wins): %v", err)
	}

	if err := ValidateServerMessage(&decoded); err != nil {
		t.Fatalf("decoded duplicate looks clean (%v) -- which is why the raw check exists", err)
	}

	if err := ValidateServerMessageRawEnvelope(dup); !errors.Is(err, ErrRecordDecode) {
		t.Fatalf("duplicate payload occurrence = %v, want ErrRecordDecode", err)
	}
	// Zero payloads is equally invalid.
	if err := ValidateServerMessageRawEnvelope(nil); !errors.Is(err, ErrRecordDecode) {
		t.Fatalf("empty envelope = %v, want ErrRecordDecode", err)
	}
}

// ValidatePlanPages consumes the header's declared fields, so a tainted header must not drive the
// chain check just because the pages themselves are clean.
func TestValidatePlanPagesRejectsUnknownFieldsOnHeader(t *testing.T) {
	header, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256, 256}, {512}})
	tainted := reparseWithSuffix(t, header, []byte{0x78, 0x01})

	if err := ValidatePlanHeader(tainted); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("precondition: tainted header must be rejected, got %v", err)
	}

	if err := ValidatePlanPages(tainted, pages); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("ValidatePlanPages(tainted header, clean pages) = %v, want ErrUnknownFields", err)
	}

	if err := ValidatePlanPages(header, pages); err != nil {
		t.Fatalf("control plan must validate: %v", err)
	}
}

func mustMarshalT(t *testing.T, m proto.Message) []byte {
	t.Helper()

	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	return b
}

// TestGoldenEnumPolicyManifest exports, per policed (message, field), the enum members GO actually
// accepts -- computed by running Go's OWN predicates over every declared member, not by restating a
// list. The Elixir semantic validator asserts its frozen allowed sets equal this manifest exactly.
//
// This is what makes the evolution guard a real PARITY guard: updating the Elixir list (or adding a
// proto member) without updating the corresponding closed Go switch changes this manifest, and the
// Elixir test fails. A purely Elixir-internal check cannot detect that.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1 go test ./go/pkg/edge/edgerecord/...
func TestGoldenEnumPolicyManifest(t *testing.T) {
	var b bytes.Buffer

	for _, e := range enumPolicyContexts() {
		var names []string

		vals := e.enum.Values()
		for i := range vals.Len() {
			v := vals.Get(i)
			if e.ok(int32(v.Number())) {
				names = append(names, string(v.Name()))
			}
		}

		fmt.Fprintf(&b, "%s\t%s\n", e.field, strings.Join(names, ","))
	}

	goldenBytesLocal(t, "enum_policy_manifest.txt", b.Bytes())
}

// goldenBytesLocal writes/compares a fixture under proto/edge/v1/testdata so both runtimes read the
// same bytes. Set EDGE_GOLDEN_UPDATE=1 to regenerate.
func goldenBytesLocal(t *testing.T, name string, b []byte) {
	t.Helper()

	path := goldenPath(name)

	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		if err := os.WriteFile(path, b, 0o600); err != nil {
			t.Fatalf("write golden %s: %v", name, err)
		}

		return
	}

	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s (run EDGE_GOLDEN_UPDATE=1): %v", name, err)
	}

	if !bytes.Equal(want, b) {
		t.Fatalf("golden %s drifted:\n have: %s\n want: %s", name, b, want)
	}
}

// goldenPath resolves a shared fixture under `go test` (relative to the package dir) and under
// Bazel (via the runfiles tree, where the files arrive through the `edge_testdata` data dep).
func goldenPath(name string) string {
	rel := filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", name)
	if fileExists(rel) {
		return rel
	}

	if dir := os.Getenv("TEST_SRCDIR"); dir != "" {
		if ws := os.Getenv("TEST_WORKSPACE"); ws != "" {
			if p := filepath.Join(dir, ws, "proto", "edge", "v1", "testdata", name); fileExists(p) {
				return p
			}
		}

		if p := filepath.Join(dir, "_main", "proto", "edge", "v1", "testdata", name); fileExists(p) {
			return p
		}
	}

	return rel
}

func fileExists(p string) bool {
	_, err := os.Stat(p)

	return err == nil
}

// enumPolicyContext binds ONE Elixir policy context (message.field) to the GO predicate that gates
// it. Every context in SemanticValidate.enum_field_policy/0 must appear here, and the Elixir test
// asserts exact key-set equality in BOTH directions -- so neither side can police a field the other
// does not. The predicates are the PRODUCTION ones; none of the accepted sets is restated inline.
type enumPolicyContext struct {
	field string
	enum  protoreflect.EnumDescriptor
	ok    func(int32) bool
}

func enumPolicyContexts() []enumPolicyContext {
	origin := func(v int32) bool { return knownOriginKind(edgev1.EdgeOriginKind(v)) }
	route := func(v int32) bool { return knownRouteProfile(edgev1.EdgeRecordRouteProfile(v)) }
	traffic := func(v int32) bool { return knownTrafficClass(edgev1.EdgeRecordTrafficClass(v)) }
	sourceKind := func(v int32) bool { return knownSourceAuthKind(edgev1.EdgeSourceAuthorizationKind(v)) }
	sweepSource := func(v int32) bool { return knownSweepSource(edgev1.SweepExecutionSource(v)) }
	protocol := func(v int32) bool { return knownTransportProtocol(edgev1.TransportProtocol(v)) }
	mtr := func(v int32) bool { return mtrTerminalOutcome(edgev1.MtrOutcome(v)) }
	modeOutcome := func(v int32) bool { return sweepModeOutcomeKnown(edgev1.SweepModeOutcome(v)) }

	originEnum := edgev1.EdgeOriginKind(0).Descriptor()
	routeEnum := edgev1.EdgeRecordRouteProfile(0).Descriptor()
	trafficEnum := edgev1.EdgeRecordTrafficClass(0).Descriptor()
	sourceKindEnum := edgev1.EdgeSourceAuthorizationKind(0).Descriptor()
	reasonEnum := edgev1.EdgeUnattributableReason(0).Descriptor()
	unattributableReason := func(v int32) bool {
		return knownUnattributableReason(edgev1.EdgeUnattributableReason(v))
	}
	sweepSourceEnum := edgev1.SweepExecutionSource(0).Descriptor()
	protocolEnum := edgev1.TransportProtocol(0).Descriptor()
	mtrEnum := edgev1.MtrOutcome(0).Descriptor()
	modeOutcomeEnum := edgev1.SweepModeOutcome(0).Descriptor()
	assignmentStateEnum := edgev1.SweepAssignmentState(0).Descriptor()
	resultFormatEnum := edgev1.SweepResultFormat(0).Descriptor()
	resultFormat := func(v int32) bool { return knownResultFormat(edgev1.SweepResultFormat(v)) }
	purposeEnum := edgev1.EdgeCapabilityPurpose(0).Descriptor()
	capabilityPurpose := func(v int32) bool { return knownCapabilityPurpose(edgev1.EdgeCapabilityPurpose(v)) }
	assignmentState := func(v int32) bool { return knownAssignmentState(edgev1.SweepAssignmentState(v)) }

	return []enumPolicyContext{
		// --- record plane ---
		{"EdgeProducerContext.origin_kind", originEnum, origin},
		{"EdgeProductionClaimsV1.origin_kind", originEnum, origin},
		{"EdgeProductionClaimsV1.route_profile", routeEnum, route},
		{"EdgeProductionClaimsV1.traffic_class", trafficEnum, traffic},
		{"EdgeRecordDisposition.kind", edgev1.EdgeRecordDispositionKind(0).Descriptor(), func(v int32) bool {
			// A kind is ACCEPTED if it validates under SOME legal rejection-code configuration: the
			// three ACCEPTED kinds FORBID a code while the two REJECTED kinds REQUIRE one, so a
			// single probe would misreport one group or the other.
			for _, code := range []string{"", "POISON"} {
				if _, err := validateDispositionKind(&edgev1.EdgeRecordDisposition{
					Kind: edgev1.EdgeRecordDispositionKind(v), RejectionCode: code,
				}); err == nil {
					return true
				}
			}

			return false
		}},
		{"SweepAssignmentRecordV1.state", assignmentStateEnum, assignmentState},
		{"CompiledSweepAssignmentV1.result_format", resultFormatEnum, resultFormat},
		{"CompiledSweepAssignmentV1.traffic_class", trafficEnum, traffic},
		{"EdgeCollectionClaimsV1.purpose", purposeEnum, capabilityPurpose},
		{"EdgeCollectionClaimsV1.traffic_class", trafficEnum, traffic},
		{"EdgeAssignmentExecutionClaimsV1.purpose", purposeEnum, capabilityPurpose},
		{"EdgeAssignmentExecutionClaimsV1.traffic_class", trafficEnum, traffic},
		{"EdgeRecordLaneOpen.route_profile", routeEnum, route},
		{"EdgeRecordLaneOpen.traffic_class", trafficEnum, traffic},
		{"EdgeRecordLaneOpenAck.route_profile", routeEnum, route},
		{"EdgeRecordLaneOpenAck.traffic_class", trafficEnum, traffic},
		{"EdgeRecordV1.compression", edgev1.EdgeRecordCompression(0).Descriptor(), func(v int32) bool {
			return knownCompression(edgev1.EdgeRecordCompression(v))
		}},
		{"EdgeRecordV1.payload_family", edgev1.EdgeRecordPayloadFamily(0).Descriptor(), func(v int32) bool {
			return knownPayloadFamily(edgev1.EdgeRecordPayloadFamily(v))
		}},
		{"EdgeRecordV1.route_profile", routeEnum, route},
		{"EdgeRecordV1.traffic_class", trafficEnum, traffic},
		{"EdgeSourceAuthorizationV1.kind", sourceKindEnum, sourceKind},
		{"EdgeSourceClaimsV1.kind", sourceKindEnum, sourceKind},
		// --- recovery classification spans (1.6a) ---
		// The span's source kind reuses the SAME predicate as the record's own
		// source_authorization, so the two can never police different sets.
		{"EdgeSourceSpanIdentityV1.kind", sourceKindEnum, sourceKind},
		{"EdgeUnattributableV1.reason", reasonEnum, unattributableReason},
		{"EdgeSourceClaimsV1.origin_kind", originEnum, origin},
		{"EdgeSourceClaimsV1.route_profile", routeEnum, route},
		{"EdgeSourceClaimsV1.traffic_class", trafficEnum, traffic},
		// --- domain payload families ---
		{"MtrTraceBatchV1.source", sweepSourceEnum, sweepSource},
		{"MtrTraceEventV1.outcome", mtrEnum, mtr},
		{"MtrTraceEventV1.protocol", protocolEnum, protocol},
		{"SweepExecutionEventV1.kind", edgev1.SweepExecutionEventKind(0).Descriptor(), func(v int32) bool {
			return knownLifecycleKind(edgev1.SweepExecutionEventKind(v))
		}},
		{"SweepIcmpSummaryV1.outcome", modeOutcomeEnum, modeOutcome},
		{"SweepMtrSummaryV1.outcome", mtrEnum, mtr},
		{"SweepObservationBatchV1.source", sweepSourceEnum, sweepSource},
		{"SweepTcpSummaryV1.outcome", modeOutcomeEnum, modeOutcome},
		{"SweepTestV1.mode", edgev1.SweepMode(0).Descriptor(), func(v int32) bool {
			return knownSweepMode(edgev1.SweepMode(v))
		}},
		{"SweepTestV1.protocol", protocolEnum, protocol},
	}
}
