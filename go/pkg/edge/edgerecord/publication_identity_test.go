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
	"encoding/base64"
	"strings"
	"testing"
)

// testUUIDv7 builds a structurally valid UUIDv7 (version nibble 0x7 + RFC variant) for slot
// fixtures -- the validated encoders now check UUID SEMANTICS, not merely 16-byte shape.
func testUUIDv7(seed byte) []byte {
	b := make([]byte, 16)
	for i := range b {
		b[i] = seed + byte(i)
	}
	b[6] = (b[6] & 0x0F) | 0x70
	b[8] = (b[8] & 0x3F) | 0x80
	return b
}

// pubIDFixture returns a valid edge slot / service slot / digests for the unit vectors. All
// fields satisfy the validated encoders (canonical/UUIDv7 IDs, 32-byte digests, ASCII principals).
func pubIDFixture() (EdgeSlot, ServiceSlot, []byte, []byte) {
	slot := EdgeSlot{
		NetworkScopeID: testUUIDv7(0x40), AuthenticatedAgentID: []byte("agent-0"),
		SpoolID: testUUIDv7(0x01), Sequence: 7,
	}
	svc := ServiceSlot{
		NetworkScopeID: slot.NetworkScopeID, AuthenticatedServiceID: []byte("agent-0"),
		PublicationLaneID: testUUIDv7(0x02), PublicationSequence: 7,
	}
	sed := bytes.Repeat([]byte{0xAA}, 32)
	rsha := bytes.Repeat([]byte{0xBB}, 32)
	return slot, svc, sed, rsha
}

func TestPublicationIdentityGrammars(t *testing.T) {
	slot, svc, sed, rsha := pubIDFixture()

	msgID, err := NatsMsgID(slot, sed, rsha)
	if err != nil {
		t.Fatalf("NatsMsgID: %v", err)
	}
	again, _ := NatsMsgID(slot, sed, rsha)
	if msgID != again {
		t.Fatal("NatsMsgID is not deterministic")
	}
	if strings.ContainsAny(msgID, "+/=") {
		t.Fatalf("header is not base64url(no-pad): %q", msgID)
	}
	if _, err := base64.RawURLEncoding.DecodeString(msgID); err != nil {
		t.Fatalf("header does not decode as base64url: %v", err)
	}

	delID, err := DeliveryID(slot)
	if err != nil {
		t.Fatalf("DeliveryID: %v", err)
	}
	// Domain separation: msg-id vs delivery-id, and edge vs service, differ.
	if msgID == delID {
		t.Fatal("msg-id and delivery-id must differ (distinct domain tags)")
	}
	svcDel, err := ServiceDeliveryID(svc)
	if err != nil {
		t.Fatalf("ServiceDeliveryID: %v", err)
	}
	if delID == svcDel {
		t.Fatal("edge and service delivery-id must differ (domain separation)")
	}

	// record_sha256 is part of the msg-id transcript, so a same-slot re-encode with a new
	// record_sha256 yields a DIFFERENT publication id and cannot be broker-deduped.
	otherSha := bytes.Repeat([]byte{0xCC}, 32)
	if other, _ := NatsMsgID(slot, sed, otherSha); msgID == other {
		t.Fatal("msg-id must depend on record_sha256")
	}

	// A valid FRESH envelope and a valid RENEWAL envelope (32-byte proof) differ.
	fresh, err := TransportProvenance(TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	if err != nil {
		t.Fatalf("fresh provenance: %v", err)
	}
	renew, err := TransportProvenance(TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeRenewal, DeliveryProof: bytes.Repeat([]byte{1}, 32), RouteMapVersion: 1})
	if err != nil {
		t.Fatalf("renewal provenance: %v", err)
	}
	if fresh == renew {
		t.Fatal("delivery_mode / proof presence must change the framed envelope")
	}

	// Fail-closed matrix.
	reject := func(name string, in TransportProvenanceInput) {
		if _, err := TransportProvenance(in); err == nil {
			t.Fatalf("%s must be rejected", name)
		}
	}
	reject("neither slot", TransportProvenanceInput{RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	reject("both slots", TransportProvenanceInput{Edge: &slot, Service: &svc, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	reject("unspecified mode", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeUnspecified, RouteMapVersion: 1})
	reject("unknown mode", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: 99, RouteMapVersion: 1})
	reject("zero route-map", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 0})
	reject("fresh with proof", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, DeliveryProof: bytes.Repeat([]byte{1}, 32), RouteMapVersion: 1})
	reject("renewal without proof", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeRenewal, RouteMapVersion: 1})
	reject("renewal wrong-size proof", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeRenewal, DeliveryProof: bytes.Repeat([]byte{1}, 31), RouteMapVersion: 1})
	reject("service non-fresh", TransportProvenanceInput{Service: &svc, RecordSha256: rsha, DeliveryMode: DeliveryModeRollover, DeliveryProof: bytes.Repeat([]byte{1}, 32), RouteMapVersion: 1})
	reject("zero sequence", TransportProvenanceInput{Edge: &EdgeSlot{NetworkScopeID: slot.NetworkScopeID, AuthenticatedAgentID: slot.AuthenticatedAgentID, SpoolID: slot.SpoolID, Sequence: 0}, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	reject("bad principal", TransportProvenanceInput{Edge: &EdgeSlot{NetworkScopeID: slot.NetworkScopeID, AuthenticatedAgentID: []byte("bad id!"), SpoolID: slot.SpoolID, Sequence: 1}, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	reject("short spool", TransportProvenanceInput{Edge: &EdgeSlot{NetworkScopeID: slot.NetworkScopeID, AuthenticatedAgentID: slot.AuthenticatedAgentID, SpoolID: []byte("short"), Sequence: 1}, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	reject("short record hash", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha[:16], DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	// UUID SEMANTICS (not just shape): a non-16-byte network scope and a 16-byte-but-non-v7 spool
	// are both rejected.
	badScope := EdgeSlot{NetworkScopeID: bytes.Repeat([]byte{0x5A}, 20), AuthenticatedAgentID: slot.AuthenticatedAgentID, SpoolID: slot.SpoolID, Sequence: 1}
	reject("non-uuid network scope", TransportProvenanceInput{Edge: &badScope, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
	v4Spool := testUUIDv7(0x01)
	v4Spool[6] = (v4Spool[6] & 0x0F) | 0x40 // version 4, not 7
	badSpool := EdgeSlot{NetworkScopeID: slot.NetworkScopeID, AuthenticatedAgentID: slot.AuthenticatedAgentID, SpoolID: v4Spool, Sequence: 1}
	reject("non-v7 spool", TransportProvenanceInput{Edge: &badSpool, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 1})
}

// TestPublicationIdentityIsSeparateFromTheSemanticEnvelope executes the three scenarios stated
// by the "Broker publication identity is separate from the semantic envelope" requirement.
//
// THE COMMITTED FIXTURES PIN THE GRAMMAR; THEY DO NOT PIN WHAT IT IS FOR. A mutation battery over
// these transcripts kills every reordering, dropped field and swapped domain tag, because the
// preimage bytes are committed. None of that says these are SEPARATE identities -- from the
// semantic envelope, and from each other. That is a claim about how the values relate as inputs
// change, so it needs inputs that change, which a frozen fixture by construction does not have.
func TestPublicationIdentityIsSeparateFromTheSemanticEnvelope(t *testing.T) {
	slot, _, sed, rsha := pubIDFixture()

	msgID, err := NatsMsgID(slot, sed, rsha)
	if err != nil {
		t.Fatalf("NatsMsgID: %v", err)
	}

	delID, err := DeliveryID(slot)
	if err != nil {
		t.Fatalf("DeliveryID: %v", err)
	}

	// SCENARIO: a re-encoded record changes its message id but not its delivery id.
	reEncoded := bytes.Repeat([]byte{0xCC}, 32)
	if same, _ := NatsMsgID(slot, sed, reEncoded); same == msgID {
		t.Fatal("msg-id must depend on record_sha256, or a broker dedupes two encodings as one")
	}

	// DeliveryID takes the slot ALONE -- there is no record digest to hand it -- so its stability
	// across a re-encode is structural rather than measured. Asserting it anyway pins the
	// SIGNATURE: giving the delivery id a digest input would have to change this call site.
	if again, _ := DeliveryID(slot); again != delID {
		t.Fatal("delivery-id must name the slot, not the bytes")
	}

	// SCENARIO: the message id commits the semantic envelope without becoming it.
	otherSED := bytes.Repeat([]byte{0xDD}, 32)
	if same, _ := NatsMsgID(slot, otherSED, rsha); same == msgID {
		t.Fatal("msg-id must depend on semantic_envelope_sha256")
	}

	if msgID == base64.RawURLEncoding.EncodeToString(sed) {
		t.Fatal("msg-id is the semantic envelope digest re-encoded, not a separate identity")
	}

	raw, err := base64.RawURLEncoding.DecodeString(msgID)
	if err != nil {
		t.Fatalf("msg-id does not decode: %v", err)
	}

	if bytes.Equal(raw, sed) {
		t.Fatal("msg-id decodes to the semantic envelope digest")
	}

	// SCENARIO: edge and service publication values cannot collide. The service transcripts mirror
	// the edge FIELD ORDER exactly, so a service slot carrying the same values leaves the domain
	// tag as the only difference between the two preimages -- which is the whole claim. A fixture
	// whose lane id and spool id merely happened to differ would prove separation by accident.
	twin := ServiceSlot{
		NetworkScopeID:         slot.NetworkScopeID,
		AuthenticatedServiceID: slot.AuthenticatedAgentID,
		PublicationLaneID:      slot.SpoolID,
		PublicationSequence:    slot.Sequence,
	}

	svcMsg, err := ServiceNatsMsgID(twin, sed, rsha)
	if err != nil {
		t.Fatalf("ServiceNatsMsgID: %v", err)
	}

	if svcMsg == msgID {
		t.Fatal("edge and service msg-id must differ on the domain tag alone")
	}

	svcDel, err := ServiceDeliveryID(twin)
	if err != nil {
		t.Fatalf("ServiceDeliveryID: %v", err)
	}

	if svcDel == delID {
		t.Fatal("edge and service delivery-id must differ on the domain tag alone")
	}
}

func TestDecodeTransportProvenanceRoundTrip(t *testing.T) {
	slot, _, _, rsha := pubIDFixture()
	proof := bytes.Repeat([]byte{0x07}, 32)

	for _, tc := range []struct {
		name  string
		in    TransportProvenanceInput
		proof []byte
		mode  uint64
	}{
		{"fresh", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 3}, nil, DeliveryModeFresh},
		{"renewal", TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeRenewal, DeliveryProof: proof, RouteMapVersion: 3}, proof, DeliveryModeRenewal},
	} {
		hdr, err := TransportProvenance(tc.in)
		if err != nil {
			t.Fatalf("%s encode: %v", tc.name, err)
		}
		dp, err := DecodeTransportProvenance(hdr)
		if err != nil {
			t.Fatalf("%s decode: %v", tc.name, err)
		}
		if dp.Edge == nil || dp.Edge.Sequence != slot.Sequence || !bytes.Equal(dp.RecordSha256, rsha) {
			t.Fatalf("%s decoded slot/record mismatch", tc.name)
		}
		if dp.DeliveryMode != tc.mode || !bytes.Equal(dp.DeliveryProof, tc.proof) {
			t.Fatalf("%s decoded mode/proof mismatch", tc.name)
		}
		reHdr, err := TransportProvenance(TransportProvenanceInput{Edge: dp.Edge, RecordSha256: dp.RecordSha256, DeliveryMode: dp.DeliveryMode, DeliveryProof: dp.DeliveryProof, RouteMapVersion: dp.RouteMapVersion})
		if err != nil || reHdr != hdr {
			t.Fatalf("%s did not round-trip", tc.name)
		}
	}

	// Trailing bytes after a valid envelope are rejected (exact-EOF).
	valid, _ := TransportProvenance(TransportProvenanceInput{Edge: &slot, RecordSha256: rsha, DeliveryMode: DeliveryModeFresh, RouteMapVersion: 3})
	raw, _ := base64.RawURLEncoding.DecodeString(valid)
	if _, err := DecodeTransportProvenance(base64.RawURLEncoding.EncodeToString(append(raw, 0x00))); err == nil {
		t.Fatal("trailing byte must be rejected")
	}
}
