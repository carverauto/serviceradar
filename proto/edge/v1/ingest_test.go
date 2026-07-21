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

package edgev1

import (
	"testing"

	"google.golang.org/protobuf/proto"
)

func TestClientMessageLaneOpenRoundTrip(t *testing.T) {
	msg := &EdgeResultClientMessage{
		Payload: &EdgeResultClientMessage_LaneOpen{
			LaneOpen: &EdgeResultLaneOpen{
				SpoolId:                 make([]byte, 16),
				LaneKind:                EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK,
				SequenceBase:            1,
				FirstUnresolvedSequence: 7,
				SessionNonce:            make([]byte, 16),
				RequestedByteCredits:    1 << 20,
				RequestedFrameCredits:   256,
			},
		},
	}
	b, err := proto.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got EdgeResultClientMessage
	if err := proto.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	lo := got.GetLaneOpen()
	if lo == nil {
		t.Fatal("lane_open not preserved")
	}
	if lo.GetLaneKind() != EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK {
		t.Fatalf("lane_kind = %v", lo.GetLaneKind())
	}
	if lo.GetFirstUnresolvedSequence() != 7 {
		t.Fatalf("first_unresolved = %d", lo.GetFirstUnresolvedSequence())
	}
	if got.GetFrame() != nil {
		t.Fatal("frame should be unset for a lane_open message")
	}
}

func TestClientMessageFrameRoundTrip(t *testing.T) {
	msg := &EdgeResultClientMessage{
		Payload: &EdgeResultClientMessage_Frame{
			Frame: &EdgeResultFrame{Sequence: 12, PayloadKind: EdgeResultPayloadKind_EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1},
		},
	}
	b, _ := proto.Marshal(msg)
	var got EdgeResultClientMessage
	if err := proto.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.GetFrame().GetSequence() != 12 {
		t.Fatalf("frame sequence = %d, want 12", got.GetFrame().GetSequence())
	}
}

func TestServerMessageAckRoundTrip(t *testing.T) {
	msg := &EdgeResultServerMessage{
		Payload: &EdgeResultServerMessage_Ack{
			Ack: &EdgeResultAck{
				SpoolId:                 make([]byte, 16),
				ResolvedThroughSequence: 99,
				SessionNonce:            make([]byte, 16),
			},
		},
	}
	b, _ := proto.Marshal(msg)
	var got EdgeResultServerMessage
	if err := proto.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.GetAck().GetResolvedThroughSequence() != 99 {
		t.Fatalf("resolved_through = %d, want 99", got.GetAck().GetResolvedThroughSequence())
	}
	if got.GetLaneOpenAck() != nil {
		t.Fatal("lane_open_ack should be unset")
	}
}
