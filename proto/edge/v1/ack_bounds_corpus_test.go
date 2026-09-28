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

package edgev1_test

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func TestAckAdmissionCorpus(t *testing.T) {
	session := edgerecord.Session{SpoolID: uuidv7(1), Nonce: uuidv7(2), HighestSent: 3, SentEvents: map[uint64][]byte{1: uuidv7(11), 2: uuidv7(12), 3: uuidv7(13)}}
	goldenText(t, "ack_bound_session.txt", fmt.Sprintf("%x %x %x %x %x\n", session.SpoolID, session.Nonce, session.SentEvents[1], session.SentEvents[2], session.SentEvents[3]))
	var manifest strings.Builder
	emit := func(name, group string, accepted bool, raw []byte, wire, count, canonical int, s edgerecord.Session) {
		t.Helper()
		_, err := edgerecord.DecodeAck(raw, s, wire, count, canonical)
		if (err == nil) != accepted {
			t.Fatalf("%s accepted=%v got %v", name, accepted, err)
		}
		filename := "ack_bound_" + name + ".bin"
		goldenBytes(t, filename, raw)
		sent := 1
		if len(s.SentEvents) == 0 {
			sent = 0
		}
		fmt.Fprintf(&manifest, "%s %s %d %d %d %d %d %d %t\n", filename, group, wire, count, canonical, s.HighestSent, s.ResolvedThrough, sent, accepted)
	}
	marshal := func(a *edgev1.EdgeDeliveryAckV1) []byte {
		raw, err := proto.Marshal(a)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	retry := func(n int, code string) *edgev1.EdgeDeliveryAckV1 {
		a := &edgev1.EdgeDeliveryAckV1{SpoolId: session.SpoolID, SessionNonce: session.Nonce}
		for i := 0; i < n; i++ {
			a.Dispositions = append(a.Dispositions, &edgev1.EdgeRecordDisposition{Sequence: uint64(i + 1), Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, RejectionCode: code})
		}
		return a
	}
	for _, size := range []int{128, 129} {
		raw := marshal(retry(1, "A"))
		gap := size - len(raw)
		if gap%2 == 1 {
			raw = append(raw, 0x10, 0x80, 0)
		}
		for len(raw) < size {
			raw = append(raw, 0x10, 0)
		}
		if len(raw) != size {
			t.Fatal("raw padding")
		}
		emit(fmt.Sprintf("raw_%d", size), "raw", size == 128, raw, 128, 10, 100, session)
	}
	emit("raw_predecode", "raw", false, bytes.Repeat([]byte{255}, 129), 128, 10, 100, session)
	for _, n := range []int{2, 3} {
		emit(fmt.Sprintf("count_%d", n), "count", n == 2, marshal(retry(n, "A")), 1024, 2, 512, session)
	}
	for _, size := range []int{65, 66} {
		raw := marshal(retry(1, strings.Repeat("A", size-44)))
		if len(raw) != size {
			t.Fatalf("canonical size %d got %d", size, len(raw))
		}
		emit(fmt.Sprintf("canonical_%d", size), "canonical", size == 65, raw, 1024, 10, 65, session)
	}
	for _, tc := range []struct {
		name, code string
		accepted   bool
	}{
		{"code_empty", "", false}, {"code_min", "A", true}, {"code_cap", strings.Repeat("A", 64), true}, {"code_over", strings.Repeat("A", 65), false},
		{"code_lower", "Aa", false}, {"code_punctuation", "A-", false}, {"code_alphabet", "A_09Z", true},
	} {
		emit(tc.name, "code", tc.accepted, marshal(retry(1, tc.code)), 1024, 10, 512, session)
	}

	base := retry(1, "")
	base.ResolvedThroughSequence = 1
	base.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
	base.Dispositions[0].EventId = session.SentEvents[1]
	emit("accept_control", "semantic", true, marshal(base), 1024, 10, 512, session)
	for _, tc := range []struct {
		name     string
		accepted bool
		change   func(*edgev1.EdgeDeliveryAckV1)
	}{
		{"accept_audit", true, func(a *edgev1.EdgeDeliveryAckV1) {
			a.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY
		}},
		{"accept_quarantine", true, func(a *edgev1.EdgeDeliveryAckV1) {
			a.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE
		}},
		{"permanent_absent_id", true, func(a *edgev1.EdgeDeliveryAckV1) {
			a.Dispositions[0].Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
			a.Dispositions[0].EventId = nil
			a.Dispositions[0].RejectionCode = "A"
		}},
		{"spool", false, func(a *edgev1.EdgeDeliveryAckV1) { a.SpoolId = uuidv7(9) }},
		{"nonce", false, func(a *edgev1.EdgeDeliveryAckV1) { a.SessionNonce = uuidv7(9) }},
		{"window", false, func(a *edgev1.EdgeDeliveryAckV1) { a.ResolvedThroughSequence = 4 }},
		{"prefix", false, func(a *edgev1.EdgeDeliveryAckV1) { a.ResolvedThroughSequence = 2 }},
		{"sequence", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].Sequence = 2 }},
		{"kind_zero", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].Kind = 0 }},
		{"kind_unknown", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].Kind = 99 }},
		{"kind_negative", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].Kind = -1 }},
		{"event_absent", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].EventId = nil }},
		{"event_mismatch", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].EventId = uuidv7(9) }},
		{"event_short", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].EventId = []byte{1} }},
		{"accept_code", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].RejectionCode = "A" }},
		{"unknown_outer", false, func(a *edgev1.EdgeDeliveryAckV1) { a.ProtoReflect().SetUnknown([]byte{160, 6, 1}) }},
		{"unknown_nested", false, func(a *edgev1.EdgeDeliveryAckV1) { a.Dispositions[0].ProtoReflect().SetUnknown([]byte{160, 6, 1}) }},
	} {
		a := proto.Clone(base).(*edgev1.EdgeDeliveryAckV1)
		tc.change(a)
		emit(tc.name, "semantic", tc.accepted, marshal(a), 1024, 10, 512, session)
	}
	a := proto.Clone(base).(*edgev1.EdgeDeliveryAckV1)
	a.Dispositions = append(a.Dispositions, retry(2, "A").Dispositions[1])
	emit("retryable_tail", "semantic", true, marshal(a), 1024, 10, 512, session)
	a = retry(2, "A")
	a.ResolvedThroughSequence = 1
	a.Dispositions[1] = proto.Clone(base.Dispositions[0]).(*edgev1.EdgeRecordDisposition)
	a.Dispositions[1].Sequence = 2
	a.Dispositions[1].EventId = session.SentEvents[2]
	emit("resolve_after_retry", "semantic", false, marshal(a), 1024, 10, 512, session)
	missing := session
	missing.SentEvents = nil
	emit("missing_sent_event", "semantic", false, marshal(base), 1024, 10, 512, missing)
	short := session
	short.HighestSent = 0
	emit("past_highest_sent", "semantic", false, marshal(retry(1, "A")), 1024, 10, 512, short)
	prior := session
	prior.ResolvedThrough = 2
	emit("watermark_regression", "semantic", false, marshal(base), 1024, 10, 512, prior)
	high := session
	high.ResolvedThrough = ^uint64(0)
	high.HighestSent = ^uint64(0)
	a = retry(0, "A")
	a.ResolvedThroughSequence = high.ResolvedThrough
	emit("exhausted_empty", "semantic", true, marshal(a), 1024, 10, 512, high)
	a.Dispositions = retry(1, "A").Dispositions
	a.Dispositions[0].Sequence = 0
	emit("exhausted_nonempty", "semantic", false, marshal(a), 1024, 10, 512, high)
	emit("nonpositive_defaults", "policy", true, marshal(base), 0, -1, 0, session)
	goldenText(t, "ack_bounds_corpus.txt", manifest.String())
}
