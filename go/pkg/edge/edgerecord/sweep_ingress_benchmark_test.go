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

// The ONE bounded BODY-PIPELINE benchmark (task 1.17). Four stages, a small fixture matrix,
// and nothing else: rejection labels, width guards and malformed hand-built structs are
// correctness tests, not benchmarks.
//
// THIS IS NOT PRODUCTION INGRESS, and its numbers are not a capacity figure. Stage 1 is
// `proto.Unmarshal` alone; stage 4 is unmarshal + body validation + the private join. There
// is NO extraction, NO `ValidateSweepRecord`, NO trust resolution, NO signature verification
// and NO decompression. What it supports is the SHAPE of the cost -- decode dominates, the
// work is linear -- not hosts/sec for a deployment.
//
// The risk this measures is REPEATED TRAVERSAL -- bytes parsed for wire hygiene and again
// for protobuf decode, then the host list walked by body validation and again by
// correlation. The individual comparisons are cheap; the walks are what multiply.
//
//	go test ./go/pkg/edge/edgerecord -run '^$' -bench '^BenchmarkSweepIngress$' \
//	  -benchmem -count=5 -benchtime=1s
package edgerecord

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// manifestName is one line per fixture: name, host count, sha256, byte length.
//
// The fixtures are GENERATED rather than committed -- 2000 hosts is ~136 KB and the matrix
// would be most of a megabyte. The manifest is what makes them SHARED: both runtimes build
// the bytes from the algorithm below and check them against the same digests, so a
// divergence makes the two sides' numbers incomparable and fails loudly instead of
// producing a quietly different workload.
//
// Resolved through `goldenPath`, the package's existing runfiles-aware helper. A bare
// relative path works under `go test` and FAILS under `bazel test`, where the file arrives
// via the `edge_testdata` data dep in the runfiles tree -- which would have made this a
// required test that cannot run in the build system that gates it.
const manifestName = "sweep_bench_manifest.txt"

// benchHost builds host i. Every host is DISTINCT: reusing one pointer 2000 times shares a
// single allocation and understates both memory and decode cost.
//
// mixed=false gives the ordinary ICMP+TCP_SYN shape. mixed=true cycles ICMP / TCP / MTR
// across hosts and attaches nested ports and errors, which is the realistic worst case.
func benchHost(i int, mixed bool) *edgev1.SweepHostObservationV1 {
	h := &edgev1.SweepHostObservationV1{
		Address:             []byte{10, byte(i >> 16), byte(i >> 8), byte(i)},
		Hostname:            fmt.Sprintf("host-%d", i),
		ObservedAtDeltaNano: int64(-1000 - i),
		ModeRevision:        uint32(i%7 + 1),
	}

	icmp := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
	tcpSyn := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN)
	mtr := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)

	newIcmp := func() *edgev1.SweepIcmpSummaryV1 {
		return &edgev1.SweepIcmpSummaryV1{
			Outcome:        edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
			TargetReached:  true,
			RoundTripMicro: proto.Uint64(uint64(900 + i)),
			PacketLossPct:  proto.Float64(0),
			Sent:           3,
			Received:       3,
		}
	}

	if !mixed {
		h.ResultModeBits = icmp | tcpSyn
		h.Icmp = newIcmp()
		h.Tcp = &edgev1.SweepTcpSummaryV1{
			Outcome:     edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
			TestedCount: 1,
			OpenCount:   1,
		}
		h.OpenPorts = []*edgev1.SweepOpenPortV1{
			{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(uint64(4000 + i)), Service: "https"},
		}

		return h
	}

	switch i % 3 {
	case 0:
		h.ResultModeBits = icmp
		h.Icmp = newIcmp()
	case 1:
		// BOTH TCP bits: open_ports references check 1 (TCP_SYN) and port_errors check 2
		// (TCP_CONNECT), and an entry may only name a check whose bit this fragment carries.
		h.ResultModeBits = tcpSyn | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
		h.Tcp = &edgev1.SweepTcpSummaryV1{
			Outcome:     edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS,
			TestedCount: 2,
			OpenCount:   1,
		}
		h.OpenPorts = []*edgev1.SweepOpenPortV1{
			{TestedCheckIndex: 1, ResponseTimeNano: proto.Uint64(uint64(4000 + i)), Service: "https"},
		}
		h.PortErrors = []*edgev1.SweepPortErrorV1{
			{TestedCheckIndex: 2, ErrorCode: "refused"},
		}
	default:
		h.ResultModeBits = mtr
		h.Mtr = &edgev1.SweepMtrSummaryV1{
			TraceId:       benchTraceID(i),
			Outcome:       edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
			TargetReached: true,
			FinalRttMicro: proto.Uint64(uint64(9000 + i)),
			PacketLossPct: proto.Float64(0),
			TotalHops:     uint32(i%12 + 1),
			ErrorCode:     "",
		}
	}

	return h
}

// benchUUID is a canonical UUIDv7-shaped identifier: version 7, RFC variant.
func benchUUID(seed byte) []byte {
	b := make([]byte, 16)
	b[0] = seed
	b[6] = 0x70
	b[8] = 0x80

	return b
}

// benchTraceID is a UUIDv7 whose 48-bit timestamp sits INSIDE the batch's signed collection
// window. A trace id with an arbitrary high seed overflows the window comparison, and
// correlation then rejects on the first MTR host -- measuring an early refusal rather than
// the full walk.
func benchTraceID(i int) []byte {
	ms := uint64(benchObservedUnixNano/1_000_000) - uint64(i%1000)
	b := make([]byte, 16)
	b[0] = byte(ms >> 40)
	b[1] = byte(ms >> 32)
	b[2] = byte(ms >> 24)
	b[3] = byte(ms >> 16)
	b[4] = byte(ms >> 8)
	b[5] = byte(ms)
	b[6] = 0x70
	b[8] = 0x80

	return b
}

const benchObservedUnixNano = 1_700_000_300_000_000_000

func benchBatch(hosts int, mixed bool) *edgev1.SweepObservationBatchV1 {
	checks := []*edgev1.SweepTestV1{
		{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_SYN, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 443},
	}
	bits := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) |
		uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN)

	if mixed {
		checks = append(checks,
			&edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: 8443},
			&edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_MTR, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		)
		bits |= uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT) |
			uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)
	}

	out := &edgev1.SweepObservationBatchV1{
		ExecutionId:          benchUUID(0x20),
		ExecutionPlanId:      benchUUID(0x21),
		TargetRangeId:        benchUUID(0x22),
		ExecutionPlanSha256:  d32domain(0x10),
		TargetRangeSha256:    d32domain(0x20),
		AvailabilityPolicyId: []byte("policy-1"),
		BatchSequence:        1,
		ObservedAtUnixNano:   benchObservedUnixNano,
		Source:               edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		SourceRunId:          benchUUID(0x23),
		ExecutionShard:       3,
		AssignmentEpoch:      5,
		ConfiguredModeBits:   bits,
		TestedChecks:         checks,
		Hosts:                make([]*edgev1.SweepHostObservationV1, 0, hosts),
	}

	for i := 0; i < hosts; i++ {
		out.Hosts = append(out.Hosts, benchHost(i, mixed))
	}

	return out
}

type benchFixture struct {
	name  string
	hosts int
	mixed bool
	// invalidLast breaks the LAST host, so the batch is only refused after a full traversal.
	invalidLast bool
	// wantBody is the sentinel body validation must return, or nil for a valid fixture.
	// Without this the evidence FAILS OPEN: a fixture degrading into an early rejection is
	// cheaper, so it reads as a speedup. That had already happened twice.
	wantBody error
}

// The bounded matrix. 32 MiB and 32 MiB + 1 are deliberately absent: they exercise the
// DECODER CEILING only, which the correctness suites already pin exactly, and generating
// 64 MiB per run buys nothing here.
//
//nolint:gochecknoglobals // immutable benchmark fixture table
var benchFixtures = []benchFixture{
	{name: "hosts_1", hosts: 1},
	{name: "hosts_100", hosts: 100},
	{name: "hosts_1000", hosts: 1000},
	{name: "hosts_2000", hosts: 2000},
	{name: "hosts_2000_mixed", hosts: 2000, mixed: true},
	{name: "hosts_2000_invalid_last", hosts: 2000, invalidLast: true, wantBody: ErrSweepAddress},
	{name: "hosts_2001_over_ceiling", hosts: MaxSweepHostsPerBatch + 1, wantBody: ErrSweepBounds},
}

func (f benchFixture) batch() *edgev1.SweepObservationBatchV1 {
	b := benchBatch(f.hosts, f.mixed)
	if f.invalidLast && len(b.Hosts) > 0 {
		b.Hosts[len(b.Hosts)-1].Address = []byte{1}
	}

	return b
}

func (f benchFixture) bytes(tb testing.TB) []byte {
	tb.Helper()

	raw, err := proto.Marshal(f.batch())
	if err != nil {
		tb.Fatalf("%s: marshal: %v", f.name, err)
	}

	return raw
}

// TestSweepBenchFixturesMatchManifest is the CROSS-RUNTIME contract for the benchmark
// inputs. It runs as an ordinary test so a drifting fixture fails CI even though the
// benchmarks themselves are not a gate.
//
//	Regenerate with: SWEEP_BENCH_WRITE_MANIFEST=1 go test ./go/pkg/edge/edgerecord \
//		-run TestSweepBenchFixturesMatchManifest
func TestSweepBenchFixturesMatchManifest(t *testing.T) {
	lines := make([]string, 0, len(benchFixtures))
	got := map[string]string{}

	for _, f := range benchFixtures {
		raw := f.bytes(t)
		sum := sha256.Sum256(raw)
		digest := hex.EncodeToString(sum[:])
		got[f.name] = fmt.Sprintf("%d %s %d", f.hosts, digest, len(raw))
		lines = append(lines, fmt.Sprintf("%s %s", f.name, got[f.name]))
	}

	sort.Strings(lines)
	body := strings.Join(lines, "\n") + "\n"

	path := goldenPath(manifestName)

	if os.Getenv("SWEEP_BENCH_WRITE_MANIFEST") == "1" {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatalf("write manifest: %v", err)
		}
		t.Logf("wrote %s", path)

		return
	}

	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read manifest (regenerate with SWEEP_BENCH_WRITE_MANIFEST=1): %v", err)
	}

	if string(want) != body {
		t.Fatalf("benchmark fixtures drifted from the manifest.\n got:\n%s\nwant:\n%s", body, want)
	}

	// EXACT membership: a manifest line with no fixture, or the reverse, means the two
	// runtimes are not measuring the same set.
	if n := len(strings.Split(strings.TrimSpace(string(want)), "\n")); n != len(benchFixtures) {
		t.Fatalf("manifest has %d entries, want %d", n, len(benchFixtures))
	}
}

// TestSweepBenchFixtureOutcomes is the TIMING-FREE half of the benchmark evidence, and the
// reason it does not fail open: every fixture is pinned to the outcome its measurement
// assumes. It is an ordinary test, so the required workflow runs it while the benchmarks
// themselves stay non-gating.
func TestSweepBenchFixtureOutcomes(t *testing.T) {
	for _, f := range benchFixtures {
		batch := f.batch()

		err := ValidateSweepObservationBatch(batch)
		switch {
		case f.wantBody == nil && err != nil:
			t.Fatalf("%s: body validation = %v, want valid -- the benchmark is measuring an "+
				"early rejection, not the work it claims", f.name, err)
		case f.wantBody != nil && !errors.Is(err, f.wantBody):
			t.Fatalf("%s: body validation = %v, want %v", f.name, err, f.wantBody)
		}

		// EVERY fixture is decoded and re-validated, INCLUDING the body-invalid ones: the
		// benchmark times `decode` and `composed` for those too, so leaving them unpinned
		// left exactly the hole this verifier exists to close -- a decode failure or a
		// changed post-decode outcome would be cheaper and pass unnoticed.
		var decoded edgev1.SweepObservationBatchV1
		if err := proto.Unmarshal(f.bytes(t), &decoded); err != nil {
			t.Fatalf("%s: decode failed, so the decode and composed stages are timing an "+
				"error path: %v", f.name, err)
		}

		postDecode := ValidateSweepObservationBatch(&decoded)
		switch {
		case f.wantBody == nil && postDecode != nil:
			t.Fatalf("%s: decoded copy is invalid (%v) though the in-memory batch is valid",
				f.name, postDecode)
		case f.wantBody != nil && !errors.Is(postDecode, f.wantBody):
			t.Fatalf("%s: composed stage would report %v, want %v", f.name, postDecode, f.wantBody)
		}

		// Correlation stays VALID-ONLY: it has a valid-body precondition, and the benchmark
		// does not time it for body-invalid fixtures either.
		if f.wantBody != nil {
			continue
		}

		if err := joinSweepAuthority(benchRecord(t, batch), batch); err != nil {
			t.Fatalf("%s: correlation = %v, want a full comparison", f.name, err)
		}
	}
}

// BenchmarkSweepIngress measures the FOUR stages separately, so a regression can be
// attributed to a stage rather than to "the ingress".
func BenchmarkSweepIngress(b *testing.B) {
	for _, f := range benchFixtures {
		raw := f.bytes(b)
		decoded := f.batch()

		// Stage 1: protobuf decode alone.
		b.Run(f.name+"/decode", func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(raw)))

			for i := 0; i < b.N; i++ {
				var msg edgev1.SweepObservationBatchV1
				if err := proto.Unmarshal(raw, &msg); err != nil {
					b.Fatal(err)
				}
			}
		})

		// Stage 2: body validation of an ALREADY-DECODED batch.
		b.Run(f.name+"/body_validate", func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(raw)))

			for i := 0; i < b.N; i++ {
				_ = ValidateSweepObservationBatch(decoded)
			}
		})

		// Stage 3: correlation against the enclosing record's signed authority.
		//
		// APPLICABLE STAGES ONLY. Correlation has a VALID-BODY precondition, so a
		// body-invalid fixture would time an early refusal -- cheaper, and therefore
		// readable as a speedup, with nothing to catch it: the verifier cannot pin an
		// outcome here without blessing behaviour outside that precondition.
		record := benchRecord(b, decoded)

		if f.wantBody == nil {
			b.Run(f.name+"/correlate", func(b *testing.B) {
				b.ReportAllocs()
				b.SetBytes(int64(len(raw)))

				for i := 0; i < b.N; i++ {
					_ = joinSweepAuthority(record, decoded)
				}
			})
		}

		// Stage 4: the BODY PIPELINE composed -- decode, then the walks that APPLY. For a
		// body-invalid fixture this is the bounded-rejection path, which is the point of
		// those fixtures; correlation is skipped for the reason above.
		b.Run(f.name+"/composed", func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(raw)))

			for i := 0; i < b.N; i++ {
				var msg edgev1.SweepObservationBatchV1
				if err := proto.Unmarshal(raw, &msg); err != nil {
					b.Fatal(err)
				}
				if err := ValidateSweepObservationBatch(&msg); err == nil {
					_ = joinSweepAuthority(record, &msg)
				}
			}
		})
	}
}

// benchRecord wraps a batch in a record whose signed source claims CORRELATE with it, so
// stage 3 measures the full comparison rather than an early rejection.
func benchRecord(tb testing.TB, batch *edgev1.SweepObservationBatchV1) *edgev1.EdgeRecordV1 {
	tb.Helper()

	claims := &edgev1.EdgeSourceClaimsV1{
		Kind:                        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		ContextId:                   batch.GetSourceRunId(),
		ScopeId:                     batch.GetTargetRangeId(),
		ScopeSha256:                 batch.GetTargetRangeSha256(),
		TargetRangeSha256:           batch.GetTargetRangeSha256(),
		ExecutionPlanSha256:         batch.GetExecutionPlanSha256(),
		CollectionNotBeforeUnixNano: batch.GetObservedAtUnixNano() - 1_000_000_000,
		CollectionExpiresUnixNano:   batch.GetObservedAtUnixNano() + 1_000_000_000,
	}

	return &edgev1.EdgeRecordV1{
		Compression: edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
		SourceAuthorization: &edgev1.EdgeSourceAuthorizationV1{
			Kind:        claims.GetKind(),
			ContextId:   claims.GetContextId(),
			ScopeId:     claims.GetScopeId(),
			ScopeSha256: claims.GetScopeSha256(),
			Capability: &edgev1.EdgeSignedCapabilityV1{
				Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: claims},
			},
		},
		ProducerContext: &edgev1.EdgeProducerContext{
			RunShard:       batch.GetExecutionShard(),
			AuthorityEpoch: proto.Uint64(batch.GetAssignmentEpoch()),
		},
	}
}
