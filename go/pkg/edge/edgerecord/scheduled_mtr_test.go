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
	"crypto/sha256"
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func scheduledMtrRecord(t *testing.T, batch *edgev1.AgentScheduledMtrTraceBatchV1, rows uint32) *edgev1.EdgeRecordV1 {
	t.Helper()
	return scheduledMtrRecordWithBytes(t, batch, rows, uint64(rows)*ScheduledMtrTraceProjectedRowBytes)
}

func scheduledMtrRecordWithBytes(
	t *testing.T,
	batch *edgev1.AgentScheduledMtrTraceBatchV1,
	rows uint32,
	writeBytes uint64,
) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = ScheduledMtrTraceContractID
	r.OutputContract.ContractVersion = ScheduledMtrTraceContractVersion
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, writeBytes
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func scheduledMtrBatch(t *testing.T) *edgev1.AgentScheduledMtrTraceBatchV1 {
	t.Helper()
	return &edgev1.AgentScheduledMtrTraceBatchV1{
		Traces: []*edgev1.AgentScheduledMtrTraceV1{
			{
				CheckId:           "mtr-check-01",
				CheckName:         "Synthetic Edge Core Link",
				DeviceId:          "sr:0197f8a0-0000-7000-8000-000000000001",
				SweepGroupId:      mustUUID(t),
				ExecutionId:       mustUUID(t),
				CommandId:         "cmd-synthetic-01",
				ExecutionSource:   edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
				ProbedHops:        4,
				LastRespondingHop: 2,
				TcpPort:           443,
				TcpProbeMode:      edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_SYN,
				Trace: &edgev1.MtrTraceEventV1{
					TraceId:            mustUUID(t),
					EventId:            mustUUID(t),
					SweepHostAddress:   []byte{192, 0, 2, 10},
					DeviceHint:         []byte("sr:0197f8a0-0000-7000-8000-000000000001"),
					ObservedAtUnixNano: 1_780_000_000_000_000_000,
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
							Sent:      10,
							Received:  10,
							LossPct:   0,
							LastMicro: proto.Uint64(1200),
							AvgMicro:  proto.Uint64(1150),
						},
						{
							HopNumber: 2,
							Address:   []byte{192, 0, 2, 10},
							Hostname:  "target.example.com",
							Sent:      10,
							Received:  9,
							LossPct:   10,
							LastMicro: proto.Uint64(3400),
							AvgMicro:  proto.Uint64(3200),
						},
					},
				},
				TcpHandshake: &edgev1.MtrTcpHandshakeDiagnosticsV1{
					Ttl:                 64,
					Attempts:            3,
					SynSent:             4,
					SynackReceived:      3,
					Unanswered:          1,
					SynDropPct:          25.0,
					SynRetransmits:      1,
					AnsweredAfterRetx:   1,
					RttMinUs:            2900,
					RttAvgUs:            3200,
					RttMaxUs:            3800,
					ServerResponseUs:    3100,
					HasServerResponseUs: true,
				},
				HopDiagnostics: []*edgev1.MtrHopReplyDiagnosticsV1{
					{
						HopNumber:         1,
						ReplyTimeExceeded: 10,
					},
					{
						HopNumber:          2,
						HasUnreachableCode: true,
						UnreachableCode:    3,
						ReplyUnreachable:   1,
						ReplySynack:        8,
					},
				},
			},
		},
	}
}

func TestValidateScheduledMtrTraceRecord(t *testing.T) {
	if err := ValidateScheduledMtrTraceRecord(scheduledMtrRecord(t, scheduledMtrBatch(t), 1)); err != nil {
		t.Fatalf("valid scheduled MTR trace record: %v", err)
	}

	other := scheduledMtrRecord(t, scheduledMtrBatch(t), 1)
	other.OutputContract.ContractId = MetricsBatchContractID
	other.ProductionCapability = productionCap(t, other)
	reseal(other)

	sourced := scheduledMtrRecord(t, scheduledMtrBatch(t), 1)
	ctx, scope := mustUUID(t), mustUUID(t)
	sourced.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability:  sourceCap(t, sourced, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:   ctx,
		ScopeId:     scope,
		ScopeSha256: d32(0xAA),
	}
	reseal(sourced)

	emptyBatch := &edgev1.AgentScheduledMtrTraceBatchV1{}
	badTraceID := scheduledMtrBatch(t)
	badTraceID.Traces[0].Trace.TraceId = d32(0x11)[:16]
	badGroupID := scheduledMtrBatch(t)
	badGroupID.Traces[0].SweepGroupId = []byte{1, 2, 3}
	badExecID := scheduledMtrBatch(t)
	badExecID.Traces[0].ExecutionId = []byte{1, 2, 3}
	badProbeMode := scheduledMtrBatch(t)
	badProbeMode.Traces[0].TcpProbeMode = edgev1.MtrTcpProbeModeV1(99)
	badPort := scheduledMtrBatch(t)
	badPort.Traces[0].TcpPort = 70000
	badHopOrder := scheduledMtrBatch(t)
	badHopOrder.Traces[0].Trace.Hops[1].HopNumber = 1

	cases := map[string]struct {
		record *edgev1.EdgeRecordV1
		want   error
	}{
		"another contract":                    {other, ErrContractDispatch},
		"a source authorization":              {sourced, ErrScheduledMtrSourceAuthorization},
		"an empty trace batch":                {scheduledMtrRecord(t, emptyBatch, 1), ErrScheduledMtrBatch},
		"a non-UUIDv7 trace id":               {scheduledMtrRecord(t, badTraceID, 1), ErrScheduledMtrBatch},
		"a 3-byte sweep group id":             {scheduledMtrRecord(t, badGroupID, 1), ErrScheduledMtrBatch},
		"a 3-byte execution id":               {scheduledMtrRecord(t, badExecID, 1), ErrScheduledMtrBatch},
		"an unknown tcp probe mode":           {scheduledMtrRecord(t, badProbeMode, 1), ErrScheduledMtrBatch},
		"a tcp port above 65535":              {scheduledMtrRecord(t, badPort, 1), ErrScheduledMtrBatch},
		"non-increasing hop numbers":          {scheduledMtrRecord(t, badHopOrder, 1), ErrMtrHop},
		"rows that disagree with the traces":  {scheduledMtrRecord(t, scheduledMtrBatch(t), 2), ErrScheduledMtrBatch},
		"write bytes that disagree with rows": {scheduledMtrRecordWithBytes(t, scheduledMtrBatch(t), 1, 1024), ErrScheduledMtrBatch},
	}
	for name, tc := range cases {
		if err := ValidateScheduledMtrTraceRecord(tc.record); !errors.Is(err, tc.want) {
			t.Errorf("record with %s = %v, want %v", name, err, tc.want)
		}
	}
}
