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
	"fmt"
	"math/rand/v2"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// syntheticSweepBatch is an invented sweep observation batch of the shape a
// leased ICMP/TCP sweep emits: documentation-range addresses, example.com names.
func syntheticSweepBatch(t testing.TB, hosts int) []byte {
	t.Helper()
	batch := &edgev1.SweepObservationBatchV1{
		ExecutionId: d32(0x11)[:16], SweepGroupId: d32(0x12)[:16], AssignmentEpoch: 3, BatchSequence: 1,
		ObservedAtUnixNano: 1_800_000_000_000_000_000, ExecutionPlanId: d32(0x13)[:16], ExecutionPlanSha256: d32(0x14),
		TargetRangeId: d32(0x15)[:16], TargetRangeSha256: d32(0x16), ConfiguredModeBits: 5,
		TestedChecks: []*edgev1.SweepTestV1{
			{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
			{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
		},
	}
	for i := range hosts {
		reached := i%3 != 0
		host := &edgev1.SweepHostObservationV1{
			Address:             []byte{192, 0, 2, byte(i)},
			Hostname:            fmt.Sprintf("host%03d.example.com", i),
			ObservedAtDeltaNano: int64(i) * 1_250_000,
			ResultModeBits:      5,
			Icmp:                &edgev1.SweepIcmpSummaryV1{TargetReached: reached, Sent: 3},
			Tcp:                 &edgev1.SweepTcpSummaryV1{TestedCount: 1},
		}
		if reached {
			host.Icmp.Received = 3
			host.Icmp.RoundTripMicro = proto.Uint64(uint64(180 + i))
			host.Tcp.OpenCount = 1
			host.OpenPorts = []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(uint64(400_000 + i)), Service: "https"}}
		} else {
			host.PortErrors = []*edgev1.SweepPortErrorV1{{TestedCheckIndex: 1, ErrorCode: "timeout"}}
		}
		batch.Hosts = append(batch.Hosts, host)
	}
	body, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func randomBody(n int) []byte {
	r := rand.New(rand.NewChaCha8([32]byte{7}))
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(r.Uint32())
	}
	return b
}

func recordPayloadInputs(t testing.TB) []struct {
	name string
	body []byte
	want edgev1.EdgeRecordCompression
} {
	return []struct {
		name string
		body []byte
		want edgev1.EdgeRecordCompression
	}{
		// A frame header alone outweighs what a tiny body could save.
		{"small", []byte("canonical-contract-payload-bytes"), edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE},
		{"representative", syntheticSweepBatch(t, 256), edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD},
		{"incompressible", randomBody(64 << 10), edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE},
		// Expands past the frozen 100:1 admission ratio, so it must stay NONE.
		{"highly_repetitive", bytes.Repeat([]byte{0}, 256<<10), edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE},
	}
}

func TestEncodeRecordPayloadChoosesAdmissibleSmallerEncoding(t *testing.T) {
	for _, tc := range recordPayloadInputs(t) {
		t.Run(tc.name, func(t *testing.T) {
			codec, payload, err := EncodeRecordPayload(tc.body)
			if err != nil {
				t.Fatal(err)
			}
			if codec != tc.want {
				t.Fatalf("codec = %v (payload %d of body %d bytes), want %v", codec, len(payload), len(tc.body), tc.want)
			}
			switch codec {
			case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD:
				if len(payload) >= len(tc.body) {
					t.Fatalf("zstd payload %d bytes is not smaller than body %d", len(payload), len(tc.body))
				}
				decoded, err := DecompressZstdPayload(payload, uint32(len(tc.body)))
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(decoded, tc.body) {
					t.Fatal("decompressed payload differs from the body")
				}
			default:
				if !bytes.Equal(payload, tc.body) {
					t.Fatal("NONE payload is not the body")
				}
			}

			r := validRecord(t)
			sum := sha256.Sum256(payload)
			r.Compression, r.Payload, r.PayloadSha256 = codec, payload, sum[:]
			r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(tc.body))
			r.ProductionCapability = productionCap(t, r)
			reseal(r)
			if err := ValidateRecord(r); err != nil {
				t.Fatalf("record carrying the encoded payload is not admissible: %v", err)
			}
			again, err := CanonicalRecordBytes(r)
			if err != nil {
				t.Fatal(err)
			}
			decodedRecord := &edgev1.EdgeRecordV1{}
			if err := proto.Unmarshal(again, decodedRecord); err != nil || ValidateRecord(decodedRecord) != nil {
				t.Fatalf("canonical bytes do not round-trip to an admissible record: %v", err)
			}
		})
	}
}

func BenchmarkEncodeRecordPayload(b *testing.B) {
	for _, tc := range recordPayloadInputs(b) {
		b.Run(tc.name, func(b *testing.B) {
			b.SetBytes(int64(len(tc.body)))
			var encoded int
			for b.Loop() {
				_, payload, err := EncodeRecordPayload(tc.body)
				if err != nil {
					b.Fatal(err)
				}
				encoded = len(payload)
			}
			b.ReportMetric(float64(encoded), "payload_bytes")
			b.ReportMetric(float64(encoded)/float64(len(tc.body)), "payload/body")
		})
	}
}
