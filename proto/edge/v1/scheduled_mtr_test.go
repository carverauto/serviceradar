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
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestAgentScheduledMtrTraceBatchV1RoundTrip(t *testing.T) {
	original := &edgev1.AgentScheduledMtrTraceBatchV1{
		Traces: []*edgev1.AgentScheduledMtrTraceV1{
			{
				CheckId:           "mtr-check-01",
				CheckName:         "Synthetic Edge Core Link",
				DeviceId:          "sr:0197f8a0-0000-7000-8000-000000000001",
				SweepGroupId:      uuidv7(0x51),
				ExecutionId:       uuidv7(0x52),
				CommandId:         "cmd-synthetic-01",
				ExecutionSource:   edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
				ProbedHops:        4,
				LastRespondingHop: 2,
				TcpPort:           443,
				TcpProbeMode:      "syn",
				ErrorMessage:      "",
				Trace: &edgev1.MtrTraceEventV1{
					TraceId:            uuidv7(0x53),
					EventId:            uuidv7(0x54),
					SweepHostAddress:   []byte{192, 0, 2, 10},
					DeviceHint:         []byte("sr:0197f8a0-0000-7000-8000-000000000001"),
					ObservedAtUnixNano: fixedNanos,
					Attempted:          true,
					Outcome:            edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
					Target:             "target.example.com",
					ResolvedAddress:    []byte{192, 0, 2, 10},
					Protocol:           edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
					IpVersion:          4,
					PacketSize:         64,
					TargetReached:      true,
					TotalHops:          2,
					Hops: []*edgev1.MtrTraceHopV1{
						{
							HopNumber: 1,
							Address:   []byte{198, 51, 100, 1},
							Hostname:  "hop1.example.com",
							EcmpAddresses: [][]byte{
								{198, 51, 100, 2},
							},
							MplsLabels: []*edgev1.MtrMplsLabelV1{
								{
									Label:         24001,
									Experimental:  0,
									BottomOfStack: true,
									Ttl:           63,
								},
							},
							Asn:                     64512,
							AsnOrg:                  "Example Transit AS64512",
							Sent:                    10,
							Received:                10,
							LossPct:                 0,
							LastMicro:               proto.Uint64(1200),
							AvgMicro:                proto.Uint64(1150),
							MinMicro:                proto.Uint64(1000),
							MaxMicro:                proto.Uint64(1400),
							StddevMicro:             proto.Uint64(120),
							JitterMicro:             proto.Uint64(80),
							JitterWorstMicro:        proto.Uint64(200),
							JitterInterarrivalMicro: proto.Uint64(95),
						},
						{
							HopNumber:               2,
							Address:                 []byte{192, 0, 2, 10},
							Hostname:                "target.example.com",
							Asn:                     64513,
							AsnOrg:                  "Example Edge AS64513",
							Sent:                    10,
							Received:                9,
							LossPct:                 10.0,
							LastMicro:               proto.Uint64(3400),
							AvgMicro:                proto.Uint64(3200),
							MinMicro:                proto.Uint64(2900),
							MaxMicro:                proto.Uint64(3800),
							StddevMicro:             proto.Uint64(250),
							JitterMicro:             proto.Uint64(140),
							JitterWorstMicro:        proto.Uint64(400),
							JitterInterarrivalMicro: proto.Uint64(160),
						},
					},
				},
				TcpHandshake: &edgev1.MtrTcpHandshakeDiagnosticsV1{
					Ttl:               64,
					Attempts:          3,
					SynSent:           4,
					SynackReceived:    3,
					RstReceived:       0,
					Unanswered:        1,
					SynDropPct:        25.0,
					SynRetransmits:    1,
					AnsweredAfterRetx: 1,
					AckMismatch:       0,
					SynackDuplicates:  0,
					RttMinUs:          2900,
					RttAvgUs:          3200,
					RttMaxUs:            3800,
					ServerResponseUs:    3100,
					HasServerResponseUs: true,
				},
				HopDiagnostics: []*edgev1.MtrHopReplyDiagnosticsV1{
					{
						HopNumber:          1,
						HasUnreachableCode: false,
						UnreachableCode:    0,
						ReplyTimeExceeded:  10,
						ReplyUnreachable:   0,
						ReplySynack:        0,
						ReplyRst:           0,
					},
					{
						HopNumber:          2,
						HasUnreachableCode: true,
						UnreachableCode:    3,
						ReplyTimeExceeded:  0,
						ReplyUnreachable:   1,
						ReplySynack:        8,
						ReplyRst:           0,
					},
				},
			},
		},
	}

	raw := mustMarshal(original)
	var decoded edgev1.AgentScheduledMtrTraceBatchV1
	if err := proto.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal AgentScheduledMtrTraceBatchV1: %v", err)
	}
	if !proto.Equal(original, &decoded) {
		t.Fatalf("round-trip mismatch:\ngot:  %v\nwant: %v", &decoded, original)
	}
}

func TestScheduledMtrProtoDeclaresNoProto3OptionalScalars(t *testing.T) {
	var checkMessages func(msgs protoreflect.MessageDescriptors)
	checkMessages = func(msgs protoreflect.MessageDescriptors) {
		for i := 0; i < msgs.Len(); i++ {
			msg := msgs.Get(i)
			fields := msg.Fields()
			for j := 0; j < fields.Len(); j++ {
				field := fields.Get(j)
				if field.HasOptionalKeyword() {
					t.Errorf("%s.%s declares proto3 optional; scheduled_mtr.proto must not add optional scalars outside presence_corpus.txt",
						msg.Name(), field.Name())
				}
			}
			checkMessages(msg.Messages())
		}
	}

	checkMessages(edgev1.File_edge_v1_scheduled_mtr_proto.Messages())
}
