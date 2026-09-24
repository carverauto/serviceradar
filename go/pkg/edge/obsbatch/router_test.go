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

package obsbatch

import (
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func tcpChecks(port uint32) []*edgev1.SweepTestV1 {
	return []*edgev1.SweepTestV1{
		{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		{Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: port},
	}
}

func TestRouterSeparatesDistinctDictionaries(t *testing.T) {
	base := Context{ExecutionID: make([]byte, 16), Source: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP}
	r := NewRouter(base, Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20})

	// Two hosts on the icmp-only dict, one on the icmp+tcp/443 dict.
	if _, err := r.Add(icmpChecks(), host("a", 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Add(tcpChecks(443), host("b", 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Add(icmpChecks(), host("c", 0)); err != nil {
		t.Fatal(err)
	}

	batches := r.Flush()
	if len(batches) != 2 {
		t.Fatalf("expected 2 batches (one per dictionary), got %d", len(batches))
	}

	byChecks := map[int]int{} // tested-check count -> host count
	for _, b := range batches {
		byChecks[len(b.TestedChecks)] += len(b.Hosts)
	}
	if byChecks[1] != 2 {
		t.Fatalf("icmp-only dict should carry 2 hosts, got %d", byChecks[1])
	}
	if byChecks[2] != 1 {
		t.Fatalf("icmp+tcp dict should carry 1 host, got %d", byChecks[2])
	}
}

func TestRouterSamePortSameDictSameBatch(t *testing.T) {
	base := Context{ExecutionID: make([]byte, 16)}
	r := NewRouter(base, Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20})

	_, _ = r.Add(tcpChecks(80), host("a", 0))
	_, _ = r.Add(tcpChecks(80), host("b", 0))

	batches := r.Flush()
	if len(batches) != 1 {
		t.Fatalf("identical dictionaries must share one batch, got %d", len(batches))
	}
	if len(batches[0].Hosts) != 2 {
		t.Fatalf("batch = %d hosts, want 2", len(batches[0].Hosts))
	}
}

// Finding usp-03/P1: batches from different dictionaries must share one
// contiguous batch-sequence space so a terminal can prove [1,N] with no
// collisions.
func TestRouterSharesOneContiguousSequenceSpace(t *testing.T) {
	base := Context{ExecutionID: make([]byte, 16)}
	// Tight target so each host flushes its own batch, interleaving dictionaries.
	r := NewRouter(base, Limits{ByteTarget: 1, ByteHard: 1 << 20})

	var seqs []uint64
	collect := func(bs []*edgev1.SweepObservationBatchV1) {
		for _, b := range bs {
			seqs = append(seqs, b.GetBatchSequence())
		}
	}
	for i := 0; i < 6; i++ {
		out, err := r.Add(icmpChecks(), host("i", 0))
		if err != nil {
			t.Fatal(err)
		}
		collect(out)
		out, err = r.Add(tcpChecks(443), host("t", 0))
		if err != nil {
			t.Fatal(err)
		}
		collect(out)
	}
	collect(r.Flush())

	seen := map[uint64]bool{}
	var max uint64
	for _, s := range seqs {
		if s == 0 {
			t.Fatal("batch_sequence must start at 1, saw 0")
		}
		if seen[s] {
			t.Fatalf("duplicate batch_sequence %d across dictionaries", s)
		}
		seen[s] = true
		if s > max {
			max = s
		}
	}
	// Contiguous [1,max] with no gaps.
	if int(max) != len(seqs) {
		t.Fatalf("sequence space not contiguous: max=%d over %d batches", max, len(seqs))
	}
	for i := uint64(1); i <= max; i++ {
		if !seen[i] {
			t.Fatalf("gap in sequence space at %d", i)
		}
	}
}

// Finding usp-03/P1: the router must bound how many dictionaries it keeps open,
// evicting (flushing) the least-recently-used rather than retaining one host per
// dictionary for the whole execution.
func TestRouterBoundsActiveDictionaries(t *testing.T) {
	base := Context{ExecutionID: make([]byte, 16)}
	r := NewRouter(base, Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxActiveDicts: 4})

	evicted := 0
	// Each distinct port is a distinct dictionary; feed far more than the cap.
	for port := uint32(1); port <= 50; port++ {
		out, err := r.Add(tcpChecks(port), host("h", 0))
		if err != nil {
			t.Fatal(err)
		}
		for _, b := range out {
			evicted += len(b.Hosts)
		}
	}
	if r.ActiveDicts() > 4 {
		t.Fatalf("active dictionaries = %d, must stay <= 4", r.ActiveDicts())
	}
	if evicted == 0 {
		t.Fatal("expected LRU eviction flushes as dictionaries exceeded the bound")
	}
	// Every host must still be accounted for across evicted + final batches.
	total := evicted
	for _, b := range r.Flush() {
		total += len(b.Hosts)
	}
	if total != 50 {
		t.Fatalf("accounted %d hosts across evicted+final batches, want 50", total)
	}
}
