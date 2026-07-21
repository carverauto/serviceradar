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
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"
)

// The committed golden fixtures are decoded by the Elixir cross-language test
// (elixir/serviceradar_core/test/serviceradar/proto/edge_v1_golden_test.exs) to
// prove byte + semantic compatibility across Go and Elixir. Regenerate with:
//
//	SR_UPDATE_GOLDEN=1 go test ./proto/edge/v1/
const (
	goldenBatch = "testdata/sweep_observation_batch_golden.bin"
	goldenTrace = "testdata/mtr_trace_event_golden.bin"
	goldenAck   = "testdata/edge_result_ack_golden.bin"
)

// uuidv7 returns a deterministic, structurally-valid RFC 9562 UUIDv7 (version
// nibble 7, variant bits 10) so fixtures never use bytes that would be rejected
// by canonical-UUID validation.
func uuidv7(seed byte) []byte {
	out := make([]byte, 16)
	for i := range out {
		out[i] = seed + byte(i)
	}
	out[6] = (out[6] & 0x0F) | 0x70 // version 7
	out[8] = (out[8] & 0x3F) | 0x80 // variant 10
	return out
}

// canonicalBatch exercises the sweep contract: UUIDv7 identifiers, 4/16-byte
// addresses, presence set-vs-absent, the tested-check/open-port indirection, and
// power-of-two result_mode_bits (ICMP|TCP_CONNECT vs MTR).
func canonicalBatch() *SweepObservationBatchV1 {
	return &SweepObservationBatchV1{
		ExecutionId:         uuidv7(0x10),
		SweepGroupId:        uuidv7(0x20),
		ExecutionShard:      3,
		AssignmentEpoch:     7,
		BatchSequence:       1,
		ObservedAtUnixNano:  1_784_600_000_000_000_000,
		ExecutionPlanId:     uuidv7(0x30),
		ExecutionPlanSha256: bytes.Repeat([]byte{0xAB}, 32),
		TargetRangeId:       uuidv7(0x40),
		TargetRangeSha256:   bytes.Repeat([]byte{0xCD}, 32),
		TestedChecks: []*SweepTestV1{
			{Mode: SweepMode_SWEEP_MODE_ICMP, Protocol: TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
			{Mode: SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
		},
		// configured = ICMP | TCP_CONNECT | MTR = 1 | 4 | 8 = 13
		ConfiguredModeBits:   uint32(SweepModeBit_SWEEP_MODE_BIT_ICMP | SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT | SweepModeBit_SWEEP_MODE_BIT_MTR),
		AvailabilityPolicyId: uuidv7(0x50),
		Source:               SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE,
		SourceRunId:          uuidv7(0x60),
		Hosts: []*SweepHostObservationV1{
			{
				Address:             []byte{10, 0, 0, 1}, // IPv4 = 4 bytes
				Hostname:            "host-a",
				ObservedAtDeltaNano: 1500,
				// this fragment carries ICMP + TCP_CONNECT terminal results
				ResultModeBits: uint32(SweepModeBit_SWEEP_MODE_BIT_ICMP | SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT),
				ModeRevision:   1,
				Icmp: &SweepIcmpSummaryV1{
					Outcome:        SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
					TargetReached:  true,
					RoundTripMicro: proto.Uint64(1200), // presence: measured
					Sent:           3,
					Received:       3,
				},
				Tcp: &SweepTcpSummaryV1{
					Outcome:     SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
					TestedCount: 1,
					OpenCount:   1,
				},
				OpenPorts: []*SweepOpenPortV1{
					{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(3_200_000), Service: "https"},
				},
			},
			{
				Address:        bytes.Repeat([]byte{0xFE}, 16), // IPv6 = 16 bytes
				Hostname:       "host-b",
				ResultModeBits: uint32(SweepModeBit_SWEEP_MODE_BIT_MTR),
				ModeRevision:   2,
				Mtr: &SweepMtrSummaryV1{
					TraceId:       uuidv7(0x70),
					Outcome:       MtrOutcome_MTR_OUTCOME_REACHED,
					TargetReached: true,
					FinalRttMicro: proto.Uint64(2500),
					TotalHops:     8,
					// PacketLossPct deliberately unset (absent != 0.0)
				},
			},
		},
	}
}

// canonicalTrace exercises the MTR contract: SCHEDULED_CHECK source + check_id
// correlation, and presence-safe hop timings including jitter_worst /
// jitter_interarrival.
func canonicalTrace() *MtrTraceEventV1 {
	return &MtrTraceEventV1{
		TraceId:            uuidv7(0x80),
		EventId:            uuidv7(0x90),
		Source:             SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		CheckId:            uuidv7(0xA0),
		ObservedAtUnixNano: 1_784_600_000_000_000_001,
		Attempted:          true,
		Outcome:            MtrOutcome_MTR_OUTCOME_REACHED,
		Target:             "example.net",
		ResolvedAddress:    []byte{192, 0, 2, 1},
		Protocol:           TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
		IpVersion:          4,
		PacketSize:         60,
		TargetReached:      true,
		TotalHops:          2,
		Hops: []*MtrTraceHopV1{
			{
				HopNumber:               1,
				Address:                 []byte{10, 0, 0, 254},
				Sent:                    3,
				Received:                3,
				AvgMicro:                proto.Uint64(500),
				JitterMicro:             proto.Uint64(40),
				JitterWorstMicro:        proto.Uint64(90),
				JitterInterarrivalMicro: proto.Uint64(12),
			},
			{
				HopNumber: 2,
				Address:   []byte{192, 0, 2, 1},
				Sent:      3,
				Received:  3,
				AvgMicro:  proto.Uint64(1800),
				// jitter fields absent on this hop (presence: not sampled)
			},
		},
	}
}

func canonicalAck() *EdgeResultAck {
	return &EdgeResultAck{
		SpoolId:                 uuidv7(0xB0),
		ResolvedThroughSequence: 42,
		SessionNonce:            uuidv7(0xC0),
		Dispositions: []*EdgeResultDisposition{
			{Sequence: 41, EventId: uuidv7(0xD0), Kind: EdgeResultDispositionKind_EDGE_RESULT_DISPOSITION_KIND_ACCEPTED},
			{Sequence: 42, EventId: uuidv7(0xE0), Kind: EdgeResultDispositionKind_EDGE_RESULT_DISPOSITION_KIND_REJECTED, RejectionCode: "schema_version_unsupported"},
		},
	}
}

func goldenRoundTrip(t *testing.T, path string, msg proto.Message) []byte {
	t.Helper()
	encoded, err := proto.MarshalOptions{Deterministic: true}.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal %s: %v", path, err)
	}
	if os.Getenv("SR_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(path, encoded, 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s (run SR_UPDATE_GOLDEN=1 to create): %v", path, err)
	}
	if !bytes.Equal(encoded, want) {
		t.Fatalf("%s: deterministic encoding drifted from golden (%d vs %d)", path, len(encoded), len(want))
	}
	return want
}

func TestSweepObservationBatchGolden(t *testing.T) {
	want := goldenRoundTrip(t, goldenBatch, canonicalBatch())

	var got SweepObservationBatchV1
	if err := proto.Unmarshal(want, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.ExecutionId) != 16 {
		t.Fatalf("execution_id must be 16 bytes, got %d", len(got.ExecutionId))
	}
	if len(got.Hosts) != 2 {
		t.Fatalf("hosts = %d, want 2", len(got.Hosts))
	}
	if len(got.Hosts[0].Address) != 4 || len(got.Hosts[1].Address) != 16 {
		t.Fatal("address widths (4/16) not preserved")
	}
	if got.Hosts[0].Icmp.RoundTripMicro == nil {
		t.Fatal("icmp round_trip_micro presence lost")
	}
	if got.Hosts[1].Mtr.PacketLossPct != nil {
		t.Fatal("mtr packet_loss_pct should be absent (presence), not zero")
	}
	// power-of-two mode bits are unambiguous.
	wantBits := uint32(SweepModeBit_SWEEP_MODE_BIT_ICMP | SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	if got.Hosts[0].ResultModeBits != wantBits {
		t.Fatalf("host[0] result_mode_bits = %d, want %d (ICMP|TCP_CONNECT)", got.Hosts[0].ResultModeBits, wantBits)
	}
	if got.Hosts[1].ResultModeBits != uint32(SweepModeBit_SWEEP_MODE_BIT_MTR) {
		t.Fatalf("host[1] result_mode_bits = %d, want %d (MTR)", got.Hosts[1].ResultModeBits, SweepModeBit_SWEEP_MODE_BIT_MTR)
	}
}

func TestMtrTraceEventGolden(t *testing.T) {
	want := goldenRoundTrip(t, goldenTrace, canonicalTrace())

	var got MtrTraceEventV1
	if err := proto.Unmarshal(want, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Source != SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK {
		t.Fatalf("scheduled-check source not representable: %v", got.Source)
	}
	if len(got.CheckId) != 16 {
		t.Fatal("check_id correlation lost")
	}
	h0 := got.Hops[0]
	if h0.JitterWorstMicro == nil || h0.JitterInterarrivalMicro == nil {
		t.Fatal("hop[0] jitter_worst/interarrival presence lost")
	}
	if got.Hops[1].JitterWorstMicro != nil {
		t.Fatal("hop[1] jitter_worst should be absent (presence)")
	}
}

func TestEdgeResultAckGolden(t *testing.T) {
	want := goldenRoundTrip(t, goldenAck, canonicalAck())

	var got EdgeResultAck
	if err := proto.Unmarshal(want, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.SessionNonce) != 16 {
		t.Fatal("ack session_nonce binding lost")
	}
	if len(got.Dispositions) != 2 {
		t.Fatalf("dispositions = %d, want 2", len(got.Dispositions))
	}
	if got.Dispositions[1].Kind != EdgeResultDispositionKind_EDGE_RESULT_DISPOSITION_KIND_REJECTED {
		t.Fatal("rejected disposition not preserved")
	}
	if got.Dispositions[1].RejectionCode != "schema_version_unsupported" {
		t.Fatalf("rejection_code = %q", got.Dispositions[1].RejectionCode)
	}
}
