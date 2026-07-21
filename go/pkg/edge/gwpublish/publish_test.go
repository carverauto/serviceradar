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

package gwpublish

import (
	"fmt"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func frame() *edgev1.EdgeResultFrame {
	return &edgev1.EdgeResultFrame{
		SpoolId:        []byte("spool-id-16bytes"),
		Sequence:       42,
		EventId:        []byte("event-id-16bytes"),
		PayloadKind:    edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
		PayloadSha256:  []byte("0123456789abcdef0123456789abcdef"),
		ExecutionId:    []byte("exec-id-16bytes!"),
		NetworkScopeId: []byte("scope-id-16bytes"),
		TrafficClass:   edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_BULK,
	}
}

func ident() TrustedIdentity {
	return TrustedIdentity{NetworkScopeID: []byte("scope-id-16bytes"), AgentID: []byte("agent-id-16bytes")}
}

// The semantic digest must ignore placement/delivery coordinates: two frames
// that differ only in spool coordinates, delivery capability, or compression are
// the same observation and must share a digest.
func TestSemanticDigestIgnoresPlacement(t *testing.T) {
	a := frame()
	b := frame()
	b.SpoolId = []byte("other-spool-1616")
	b.Sequence = 9999
	b.DeliveryCapability = []byte("renewed-cap")
	b.Compression = edgev1.EdgeResultCompression_EDGE_RESULT_COMPRESSION_ZSTD
	b.EncodedSize = 123
	b.CollectionCapability = []byte("coll-cap")

	if string(SemanticDigest(a)) != string(SemanticDigest(b)) {
		t.Fatal("semantic digest must not depend on placement/delivery coordinates")
	}
}

// A change to a genuine domain-identity term must change the digest.
func TestSemanticDigestSensitiveToIdentity(t *testing.T) {
	a := frame()
	b := frame()
	b.ExecutionId = []byte("exec-id-DIFFEREN")
	if string(SemanticDigest(a)) == string(SemanticDigest(b)) {
		t.Fatal("semantic digest must change when execution identity changes")
	}
	c := frame()
	c.PayloadSha256 = []byte("ffffffffffffffffffffffffffffffff")
	if string(SemanticDigest(a)) == string(SemanticDigest(c)) {
		t.Fatal("semantic digest must change when payload hash changes")
	}
}

// The msg id is idempotent for the same spool coordinate and differs across
// spool coordinates and identities.
func TestMsgIDIdempotentAndScoped(t *testing.T) {
	a := MsgID(ident(), frame())
	if a != MsgID(ident(), frame()) {
		t.Fatal("msg id must be idempotent for the same coordinate")
	}
	f2 := frame()
	f2.Sequence = 43
	if a == MsgID(ident(), f2) {
		t.Fatal("msg id must differ across sequence")
	}
	other := TrustedIdentity{NetworkScopeID: []byte("scope-id-16bytes"), AgentID: []byte("OTHER-agent-1616")}
	if a == MsgID(other, frame()) {
		t.Fatal("msg id must differ across trusted identity")
	}
}

func TestLaneForRouting(t *testing.T) {
	cases := []struct {
		kind  edgev1.EdgeResultPayloadKind
		class edgev1.EdgeResultTrafficClass
		want  edgev1.EdgeResultLaneKind
	}{
		{edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1, edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_BULK, edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK},
		{edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1, edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE, edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE},
		{edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1, edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_BULK, edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_BULK},
		{edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1, edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE, edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_MTR_INTERACTIVE},
		{edgev1.EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1, edgev1.EdgeResultTrafficClass_EDGE_RESULT_TRAFFIC_CLASS_BULK, edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_RECOVERY_CONTROL},
	}
	for _, c := range cases {
		f := &edgev1.EdgeResultFrame{PayloadKind: c.kind, TrafficClass: c.class}
		if got := LaneFor(f); got != c.want {
			t.Fatalf("LaneFor(%v,%v) = %v, want %v", c.kind, c.class, got, c.want)
		}
	}
}

func TestExpectedStreamResolves(t *testing.T) {
	stream, partition, err := ExpectedStream(frame())
	if err != nil {
		t.Fatalf("expected stream: %v", err)
	}
	if stream == "" {
		t.Fatal("empty stream name")
	}
	if partition >= 64 {
		t.Fatalf("partition %d out of range", partition)
	}
}

func TestClassify(t *testing.T) {
	if Classify(nil) != ClassNone {
		t.Fatal("nil must be ClassNone")
	}
	if Classify(fmt.Errorf("wrap: %w", ErrCapacity)) != ClassCapacity {
		t.Fatal("capacity")
	}
	if Classify(fmt.Errorf("wrap: %w", ErrPermanent)) != ClassPermanent {
		t.Fatal("permanent")
	}
	// Unknown errors must be retryable, never treated as durable success.
	if c := Classify(fmt.Errorf("mystery")); c != ClassTimeout || !c.Retryable() {
		t.Fatalf("unknown error class = %v (retryable=%v), want retryable timeout", c, c.Retryable())
	}
	if ClassPermanent.Retryable() || ClassProtocol.Retryable() {
		t.Fatal("permanent/protocol must not be retryable")
	}
}
