/*
 * Copyright 2025 Carver Automation Corporation.
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

package mtr

import (
	"math"
	"net"
	"testing"
	"time"
)

func TestHopResult_BasicStatistics(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	// Add samples: 10ms, 20ms, 30ms
	hop.AddSample(10 * time.Millisecond)
	hop.AddSample(20 * time.Millisecond)
	hop.AddSample(30 * time.Millisecond)

	if hop.Sent != 3 {
		t.Errorf("Sent = %d, want 3", hop.Sent)
	}

	if hop.Received != 3 {
		t.Errorf("Received = %d, want 3", hop.Received)
	}

	// Mean should be 20ms = 20000us
	avg := hop.AvgUs()
	if avg != 20000 {
		t.Errorf("AvgUs = %d, want 20000", avg)
	}

	// Min = 10ms = 10000us
	if hop.Best != 10000 {
		t.Errorf("Best = %d, want 10000", hop.Best)
	}

	// Max = 30ms = 30000us
	if hop.Worst != 30000 {
		t.Errorf("Worst = %d, want 30000", hop.Worst)
	}

	// Last = 30ms = 30000us
	if hop.Last != 30000 {
		t.Errorf("Last = %d, want 30000", hop.Last)
	}
}

func TestHopResult_StdDev(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	// Add samples with known stddev
	samples := []time.Duration{
		10 * time.Millisecond,
		20 * time.Millisecond,
		30 * time.Millisecond,
		40 * time.Millisecond,
		50 * time.Millisecond,
	}

	for _, s := range samples {
		hop.AddSample(s)
	}

	// Expected stddev for [10000, 20000, 30000, 40000, 50000]
	// Mean = 30000, Variance = (sum of squared diffs) / (n-1)
	// = (400000000 + 100000000 + 0 + 100000000 + 400000000) / 4 = 250000000
	// StdDev = sqrt(250000000) ≈ 15811
	stddev := hop.StdDevUs()
	expected := int64(math.Round(math.Sqrt(250000000)))

	if abs64(stddev-expected) > 1 {
		t.Errorf("StdDevUs = %d, want %d", stddev, expected)
	}
}

func TestHopResult_LossCalculation(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	// Send 4, receive 3 => 25% loss
	hop.AddSample(10 * time.Millisecond)
	hop.AddSample(20 * time.Millisecond)
	hop.AddSample(30 * time.Millisecond)
	hop.AddSample(-1) // timeout

	loss := hop.LossPct()
	if math.Abs(loss-25.0) > 0.01 {
		t.Errorf("LossPct = %f, want 25.0", loss)
	}
}

func TestHopResult_LossExcludesInFlight(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	hop.AddSample(10 * time.Millisecond)
	hop.AddSample(-1) // timeout

	// Simulate 1 in-flight
	hop.mu.Lock()
	hop.InFlight = 1
	hop.mu.Unlock()

	// Sent=2, Received=1, InFlight=1
	// effective = 2 - 1 = 1
	// loss = 100 * (1 - 1/1) = 0%
	loss := hop.LossPct()
	if math.Abs(loss) > 0.01 {
		t.Errorf("LossPct = %f, want 0.0 (in-flight excluded)", loss)
	}
}

func TestHopResult_Jitter(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	// 10ms, 20ms, 15ms, 25ms
	hop.AddSample(10 * time.Millisecond)
	hop.AddSample(20 * time.Millisecond) // jitter: |20000-10000| = 10000
	hop.AddSample(15 * time.Millisecond) // jitter: |15000-20000| = 5000
	hop.AddSample(25 * time.Millisecond) // jitter: |25000-15000| = 10000

	// Avg jitter = (10000 + 5000 + 10000) / 3 = 8333
	jitter := hop.JitterUs()
	if abs64(jitter-8333) > 1 {
		t.Errorf("JitterUs = %d, want 8333", jitter)
	}

	// Worst jitter = 10000
	if hop.JitterWorstUs() != 10000 {
		t.Errorf("JitterWorstUs = %d, want 10000", hop.JitterWorstUs())
	}
}

func TestHopResult_ECMP(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	ip1 := net.ParseIP("10.0.0.1")
	ip2 := net.ParseIP("10.0.0.2")
	ip3 := net.ParseIP("10.0.0.1") // duplicate

	hop.AddAddress(ip1)
	hop.AddAddress(ip2)
	hop.AddAddress(ip3) // should be deduplicated

	if !hop.Addr.Equal(ip1) {
		t.Errorf("Addr = %s, want %s", hop.Addr, ip1)
	}

	if len(hop.ECMPAddrs) != 1 {
		t.Errorf("ECMPAddrs len = %d, want 1", len(hop.ECMPAddrs))
	}

	if !hop.ECMPAddrs[0].Equal(ip2) {
		t.Errorf("ECMPAddrs[0] = %s, want %s", hop.ECMPAddrs[0], ip2)
	}
}

func TestHopResult_RingBuffer(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 3) // small ring buffer

	hop.AddSample(10 * time.Millisecond)
	hop.AddSample(20 * time.Millisecond)
	hop.AddSample(30 * time.Millisecond)
	hop.AddSample(40 * time.Millisecond) // overwrites first

	samples := hop.Samples()
	if len(samples) != 3 {
		t.Fatalf("Samples len = %d, want 3", len(samples))
	}

	// Should be [20000, 30000, 40000] (oldest first after wrap)
	expected := []int64{20000, 30000, 40000}
	for i, want := range expected {
		if samples[i] != want {
			t.Errorf("Samples[%d] = %d, want %d", i, samples[i], want)
		}
	}
}

func TestHopResult_Snapshot(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(3, 10)
	hop.AddAddress(net.ParseIP("192.168.1.1"))
	hop.Hostname = "router.local"
	hop.ASN = ASNInfo{ASN: 15169, Org: "GOOGLE"}
	hop.MPLSLabels = []MPLSLabel{{Label: 12345, Exp: 0, S: true, TTL: 1}}

	hop.AddSample(5 * time.Millisecond)
	hop.AddSample(10 * time.Millisecond)

	snap := hop.Snapshot()

	if snap.HopNumber != 3 {
		t.Errorf("HopNumber = %d, want 3", snap.HopNumber)
	}

	if snap.Addr != "192.168.1.1" {
		t.Errorf("Addr = %s, want 192.168.1.1", snap.Addr)
	}

	if snap.Hostname != "router.local" {
		t.Errorf("Hostname = %s, want router.local", snap.Hostname)
	}

	if snap.ASN.ASN != 15169 {
		t.Errorf("ASN = %d, want 15169", snap.ASN.ASN)
	}

	if len(snap.MPLSLabels) != 1 || snap.MPLSLabels[0].Label != 12345 {
		t.Errorf("MPLSLabels unexpected: %+v", snap.MPLSLabels)
	}

	if snap.Sent != 2 || snap.Received != 2 {
		t.Errorf("Sent/Received = %d/%d, want 2/2", snap.Sent, snap.Received)
	}
}

func TestHopResult_NoSamples(t *testing.T) {
	t.Parallel()

	hop := NewHopResult(1, 10)

	if hop.AvgUs() != 0 {
		t.Errorf("AvgUs = %d, want 0", hop.AvgUs())
	}

	if hop.StdDevUs() != 0 {
		t.Errorf("StdDevUs = %d, want 0", hop.StdDevUs())
	}

	if hop.LossPct() != 0 {
		t.Errorf("LossPct = %f, want 0", hop.LossPct())
	}

	if hop.Samples() != nil {
		t.Errorf("Samples should be nil")
	}
}
