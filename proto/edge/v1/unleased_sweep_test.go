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

func TestUnleasedSweepResultsBatchRoundTrip(t *testing.T) {
	rttMicro := uint64(1420)
	lossPct := 0.0
	respNano := uint64(850_000)

	orig := &edgev1.UnleasedSweepResultsBatchV1{
		ExecutionId:              uuidv7(0x51),
		SweepGroupId:             uuidv7(0x52),
		ConfigVersion:            "cfg-unleased-v1",
		NetworkCidr:              "192.0.2.0/24",
		Sequence:                 42,
		BatchStartedAtUnixNano:   uint64(fixedNanos),
		BatchCompletedAtUnixNano: uint64(fixedNanos + 2_500_000_000),
		LastSweepUnixNano:        uint64(fixedNanos + 2_500_000_000),
		ObservedAtUnixNano:       fixedNanos + 1_000_000_000,
		ChunkIndex:               0,
		TotalChunks:              1,
		IsFinal:                  true,
		IsCancelled:              false,
		ExpectedTotalHosts:       254,
		AvailableHosts:           2,
		ConfiguredModeBits:       uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP | edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN),
		TestedChecks: []*edgev1.SweepTestV1{
			{
				Mode:     edgev1.SweepMode_SWEEP_MODE_ICMP,
				Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
			},
			{
				Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_SYN,
				Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
				Port:     22,
			},
			{
				Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_SYN,
				Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
				Port:     443,
			},
		},
		ExecutionSource: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		Hosts: []*edgev1.SweepHostObservationV1{
			{
				Address:             []byte{192, 0, 2, 10},
				Hostname:            "host-a.example.com",
				ObservedAtDeltaNano: 125_000_000,
				ResultModeBits:      uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP | edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN),
				ModeRevision:        1,
				Icmp: &edgev1.SweepIcmpSummaryV1{
					Outcome:        edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
					TargetReached:  true,
					RoundTripMicro: &rttMicro,
					PacketLossPct:  &lossPct,
					Sent:           3,
					Received:       3,
				},
				Tcp: &edgev1.SweepTcpSummaryV1{
					Outcome:     edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
					TestedCount: 2,
					OpenCount:   2,
				},
				OpenPorts: []*edgev1.SweepOpenPortV1{
					{
						TestedCheckIndex: 1,
						ResponseTimeNano: &respNano,
						Service:          "ssh",
					},
					{
						TestedCheckIndex: 2,
						ResponseTimeNano: &respNano,
						Service:          "https",
					},
				},
			},
			{
				Address:             []byte{192, 0, 2, 11},
				Hostname:            "host-b.example.com",
				ObservedAtDeltaNano: 240_000_000,
				ResultModeBits:      uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP | edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN),
				ModeRevision:        1,
				PortErrors: []*edgev1.SweepPortErrorV1{
					{
						TestedCheckIndex: 1,
						ErrorCode:        "connection_refused",
					},
				},
			},
		},
		PortCounts: []*edgev1.UnleasedSweepPortCountV1{
			{Port: 22, Available: 1},
			{Port: 443, Available: 1},
		},
		ScannerStats: &edgev1.UnleasedSweepScannerStatsV1{
			Protocol:             "tcp",
			AddressFamily:        "ipv4",
			ScannerPath:          "tpacket_v3",
			PacketsSent:          508,
			PacketsRecv:          12,
			PacketsDropped:       1,
			RingBlocksProcessed:  64,
			RingBlocksDropped:    0,
			RetriesAttempted:     4,
			RetriesSuccessful:    2,
			RetriesDropped:       0,
			PortsAllocated:       508,
			PortsReleased:        508,
			PortExhaustionCount:  0,
			RateLimitDeferrals:   5,
			RateLimitWaits:       2,
			SourcePortWaits:      0,
			RateLimitWaitTimeMs:  12,
			SourcePortWaitTimeMs: 0,
			RxDropRatePercent:    0.19,
			DialsStarted:         4,
			DialsSucceeded:       2,
			DialTimeouts:         1,
			DialResets:           1,
			DialResourceErrors:   0,
			ActiveDials:          0,
			MaxActiveDials:       4,
			QueueDepth:           0,
			MaxQueueDepth:        8,
		},
		BannerGrabSummary: &edgev1.UnleasedSweepBannerGrabSummaryV1{
			CandidatesTotal:      4,
			ProbesTotal:          2,
			Inflight:             0,
			QueueDepth:           0,
			MatchBatchesTotal:    1,
			MatchBatchBytesTotal: 512,
			BytesReceivedTotal:   1024,
			SkippedFreshTotal:    1,
			SkippedBackoffTotal:  1,
			MatchesTotal:         2,
			EmptyResponseTotal:   0,
			ConnectionResetTotal: 0,
			TimeoutTotal:         0,
			ErrorsTotal:          0,
		},
	}

	raw, err := proto.Marshal(orig)
	if err != nil {
		t.Fatalf("proto.Marshal(UnleasedSweepResultsBatchV1): %v", err)
	}

	var decoded edgev1.UnleasedSweepResultsBatchV1
	if err := proto.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("proto.Unmarshal(UnleasedSweepResultsBatchV1): %v", err)
	}

	if !proto.Equal(orig, &decoded) {
		t.Fatalf("round-trip mismatch:\ngot:  %+v\nwant: %+v", &decoded, orig)
	}

	if got := decoded.GetScannerStats().GetPortsAllocated(); got != 508 {
		t.Fatalf("ScannerStats.PortsAllocated = %d, want 508", got)
	}
	if got := decoded.GetBannerGrabSummary().GetMatchesTotal(); got != 2 {
		t.Fatalf("BannerGrabSummary.MatchesTotal = %d, want 2", got)
	}
	if got := len(decoded.GetHosts()); got != 2 {
		t.Fatalf("len(Hosts) = %d, want 2", got)
	}
	if got := len(decoded.GetPortCounts()); got != 2 {
		t.Fatalf("len(PortCounts) = %d, want 2", got)
	}
	const (
		hostAInstant = fixedNanos + 1_000_000_000 + 125_000_000
		hostBInstant = fixedNanos + 1_000_000_000 + 240_000_000
	)
	if got := decoded.GetObservedAtUnixNano() + decoded.GetHosts()[0].GetObservedAtDeltaNano(); got != hostAInstant {
		t.Fatalf("host A instant = %d, want %d", got, hostAInstant)
	}
	if got := decoded.GetObservedAtUnixNano() + decoded.GetHosts()[1].GetObservedAtDeltaNano(); got != hostBInstant {
		t.Fatalf("host B instant = %d, want %d", got, hostBInstant)
	}
	if int64(decoded.GetBatchStartedAtUnixNano())+125_000_000 == hostAInstant ||
		int64(decoded.GetBatchCompletedAtUnixNano())+125_000_000 == hostAInstant ||
		int64(decoded.GetLastSweepUnixNano())+125_000_000 == hostAInstant {
		t.Fatal("host A instant is a summary clock plus delta")
	}
}

func TestUnleasedSweepProtoDeclaresNoProto3OptionalScalars(t *testing.T) {
	var checkMessages func(msgs protoreflect.MessageDescriptors)
	checkMessages = func(msgs protoreflect.MessageDescriptors) {
		for i := 0; i < msgs.Len(); i++ {
			msg := msgs.Get(i)
			fields := msg.Fields()
			for j := 0; j < fields.Len(); j++ {
				field := fields.Get(j)
				if field.HasOptionalKeyword() {
					t.Errorf("%s.%s declares proto3 optional; unleased_sweep.proto must not add optional scalars outside presence_corpus.txt",
						msg.Name(), field.Name())
				}
			}
			checkMessages(msg.Messages())
		}
	}

	checkMessages(edgev1.File_edge_v1_unleased_sweep_proto.Messages())
}
