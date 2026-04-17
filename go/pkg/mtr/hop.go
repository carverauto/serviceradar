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
	"sync"
	"time"
)

// MPLSLabel represents a single MPLS label stack entry extracted from
// RFC 4884 ICMP extension objects.
type MPLSLabel struct {
	Label int  `json:"label"`
	Exp   int  `json:"exp"`
	S     bool `json:"s"`
	TTL   int  `json:"ttl"`
}

// ASNInfo holds Autonomous System information for a hop IP.
type ASNInfo struct {
	ASN int    `json:"asn,omitempty"`
	Org string `json:"org,omitempty"`
}

// HopResult holds the accumulated statistics for a single hop in an MTR trace.
type HopResult struct {
	mu sync.RWMutex

	// HopNumber is the TTL distance (1-indexed).
	HopNumber int `json:"hop_number"`

	// Addr is the primary responding IP address.
	Addr net.IP `json:"addr,omitempty"`

	// Hostname is the reverse-DNS name for Addr.
	Hostname string `json:"hostname,omitempty"`

	// ECMPAddrs holds additional responding IPs (ECMP paths).
	ECMPAddrs []net.IP `json:"ecmp_addrs,omitempty"`

	// ASN holds the Autonomous System information.
	ASN ASNInfo `json:"asn,omitzero"`

	// MPLSLabels holds MPLS label stack entries from ICMP extensions.
	MPLSLabels []MPLSLabel `json:"mpls_labels,omitempty"`

	// Sent is the total number of probes sent.
	Sent int `json:"sent"`

	// Received is the number of probe responses received.
	Received int `json:"received"`

	// InFlight is the number of probes awaiting response.
	InFlight int `json:"-"`

	// Last is the most recent RTT in microseconds.
	Last int64 `json:"last_us,omitempty"`

	// Best is the minimum observed RTT in microseconds.
	Best int64 `json:"min_us,omitempty"`

	// Worst is the maximum observed RTT in microseconds.
	Worst int64 `json:"max_us,omitempty"`

	// statistics fields for Welford's online algorithm
	mean float64 // running mean
	m2   float64 // sum of squares of differences from mean

	// Jitter tracking
	prevRTT            int64 // previous RTT for jitter calc
	jitterSum          float64
	jitterCount        int
	jitterWorst        int64
	jitterInterarrival float64 // RFC 1889 interarrival jitter

	// Ring buffer of recent RTT samples (microseconds).
	ringBuf  []int64
	ringPos  int
	ringFull bool
	ringSize int
}

// NewHopResult creates a new HopResult for the given hop number.
func NewHopResult(hopNumber int, ringBufferSize int) *HopResult {
	if ringBufferSize <= 0 {
		ringBufferSize = DefaultRingBufferSize
	}

	return &HopResult{
		HopNumber: hopNumber,
		ringBuf:   make([]int64, ringBufferSize),
		ringSize:  ringBufferSize,
	}
}

// Reset clears accumulated hop state while reusing internal buffers.
func (h *HopResult) Reset(hopNumber int, ringBufferSize int) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if ringBufferSize <= 0 {
		ringBufferSize = DefaultRingBufferSize
	}

	h.HopNumber = hopNumber
	h.Addr = nil
	h.Hostname = ""
	h.ECMPAddrs = h.ECMPAddrs[:0]
	h.ASN = ASNInfo{}
	h.MPLSLabels = h.MPLSLabels[:0]
	h.Sent = 0
	h.Received = 0
	h.InFlight = 0
	h.Last = 0
	h.Best = 0
	h.Worst = 0
	h.mean = 0
	h.m2 = 0
	h.prevRTT = 0
	h.jitterSum = 0
	h.jitterCount = 0
	h.jitterWorst = 0
	h.jitterInterarrival = 0
	h.ringPos = 0
	h.ringFull = false

	if h.ringSize != ringBufferSize || len(h.ringBuf) != ringBufferSize {
		h.ringBuf = make([]int64, ringBufferSize)
		h.ringSize = ringBufferSize
	}
}

// AddSample records a new probe result. rtt is the round-trip time.
// Pass rtt < 0 to record a sent-but-not-received probe (timeout).
func (h *HopResult) AddSample(rtt time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.Sent++

	if rtt < 0 {
		// Probe timed out — count as sent but not received.
		return
	}

	us := rtt.Microseconds()
	h.Received++
	h.Last = us

	if h.Received == 1 {
		h.Best = us
		h.Worst = us
	}
	if h.Received > 1 && us < h.Best {
		h.Best = us
	}
	if h.Received > 1 && us > h.Worst {
		h.Worst = us
	}
	// Welford's online algorithm for mean and variance.
	n := float64(h.Received)
	delta := float64(us) - h.mean
	h.mean += delta / n
	delta2 := float64(us) - h.mean
	h.m2 += delta * delta2

	// Jitter calculation.
	if h.Received > 1 {
		j := abs64(us - h.prevRTT)

		h.jitterSum += float64(j)
		h.jitterCount++

		if j > h.jitterWorst {
			h.jitterWorst = j
		}

		// RFC 1889 interarrival jitter:
		//   J(i) = J(i-1) + (|D(i-1,i)| - J(i-1)) / 16
		h.jitterInterarrival += (float64(j) - h.jitterInterarrival) / 16.0
	}

	h.prevRTT = us

	// Ring buffer.
	h.ringBuf[h.ringPos] = us
	h.ringPos++
	if h.ringPos >= h.ringSize {
		h.ringPos = 0
		h.ringFull = true
	}
}

// AddResponse records a probe response for a probe that was already counted
// as sent when dispatched by the tracer.
func (h *HopResult) AddResponse(rtt time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if rtt < 0 {
		return
	}

	us := rtt.Microseconds()
	h.Received++
	h.Last = us

	if h.Received == 1 {
		h.Best = us
		h.Worst = us
	}
	if h.Received > 1 && us < h.Best {
		h.Best = us
	}
	if h.Received > 1 && us > h.Worst {
		h.Worst = us
	}

	// Welford's online algorithm for mean and variance.
	n := float64(h.Received)
	delta := float64(us) - h.mean
	h.mean += delta / n
	delta2 := float64(us) - h.mean
	h.m2 += delta * delta2

	// Jitter calculation.
	if h.Received > 1 {
		j := abs64(us - h.prevRTT)

		h.jitterSum += float64(j)
		h.jitterCount++

		if j > h.jitterWorst {
			h.jitterWorst = j
		}

		// RFC 1889 interarrival jitter:
		//   J(i) = J(i-1) + (|D(i-1,i)| - J(i-1)) / 16
		h.jitterInterarrival += (float64(j) - h.jitterInterarrival) / 16.0
	}

	h.prevRTT = us

	// Ring buffer.
	h.ringBuf[h.ringPos] = us
	h.ringPos++
	if h.ringPos >= h.ringSize {
		h.ringPos = 0
		h.ringFull = true
	}
}

// FinalizeTimeouts marks all in-flight probes as completed timeouts.
func (h *HopResult) FinalizeTimeouts() {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.InFlight = 0
}

// AddAddress records a responding IP for this hop.
// The first address becomes the primary; subsequent unique addresses
// are appended to ECMPAddrs.
func (h *HopResult) AddAddress(addr net.IP) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.Addr == nil {
		h.Addr = addr
		return
	}

	if h.Addr.Equal(addr) {
		return
	}

	for _, a := range h.ECMPAddrs {
		if a.Equal(addr) {
			return
		}
	}

	h.ECMPAddrs = append(h.ECMPAddrs, addr)
}

// SetMPLS records MPLS label stack entries for this hop.
func (h *HopResult) SetMPLS(labels []MPLSLabel) {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.MPLSLabels = labels
}

// AvgUs returns the mean RTT in microseconds.
func (h *HopResult) AvgUs() int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if h.Received == 0 {
		return 0
	}

	return int64(math.Round(h.mean))
}

// StdDevUs returns the standard deviation of RTT in microseconds.
func (h *HopResult) StdDevUs() int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if h.Received < 2 {
		return 0
	}

	variance := h.m2 / float64(h.Received-1)

	return int64(math.Round(math.Sqrt(variance)))
}

// LossPct returns the packet loss percentage, excluding in-flight probes.
func (h *HopResult) LossPct() float64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	effective := h.Sent - h.InFlight
	if effective <= 0 {
		return 0
	}

	return 100.0 * (1.0 - float64(h.Received)/float64(effective))
}

// JitterUs returns the average jitter in microseconds.
func (h *HopResult) JitterUs() int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if h.jitterCount == 0 {
		return 0
	}

	return int64(math.Round(h.jitterSum / float64(h.jitterCount)))
}

// JitterWorstUs returns the worst observed jitter in microseconds.
func (h *HopResult) JitterWorstUs() int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	return h.jitterWorst
}

// JitterInterarrivalUs returns the RFC 1889 interarrival jitter in microseconds.
func (h *HopResult) JitterInterarrivalUs() int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	return int64(math.Round(h.jitterInterarrival))
}

// Samples returns a copy of the ring buffer contents (oldest first).
func (h *HopResult) Samples() []int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if h.Received == 0 {
		return nil
	}

	var result []int64
	if h.ringFull {
		result = make([]int64, h.ringSize)
		copy(result, h.ringBuf[h.ringPos:])
		copy(result[h.ringSize-h.ringPos:], h.ringBuf[:h.ringPos])
		return result
	}

	result = make([]int64, h.ringPos)
	copy(result, h.ringBuf[:h.ringPos])

	return result
}

// Snapshot returns a read-only copy of the hop result for serialization.
func (h *HopResult) Snapshot() HopSnapshot {
	h.mu.RLock()
	defer h.mu.RUnlock()

	snap := HopSnapshot{
		HopNumber:  h.HopNumber,
		Hostname:   h.Hostname,
		ASN:        h.ASN,
		MPLSLabels: h.MPLSLabels,
		Sent:       h.Sent,
		Received:   h.Received,
		LossPct:    h.lossPctLocked(),
		LastUs:     h.Last,
		AvgUs:      int64(math.Round(h.mean)),
		MinUs:      h.Best,
		MaxUs:      h.Worst,
	}

	if h.Addr != nil {
		snap.Addr = h.Addr.String()
	}

	if h.Received >= 2 {
		variance := h.m2 / float64(h.Received-1)
		snap.StdDevUs = int64(math.Round(math.Sqrt(variance)))
	}

	if h.jitterCount > 0 {
		snap.JitterUs = int64(math.Round(h.jitterSum / float64(h.jitterCount)))
		snap.JitterWorstUs = h.jitterWorst
		snap.JitterInterarrivalUs = int64(math.Round(h.jitterInterarrival))
	}

	if len(h.ECMPAddrs) > 0 {
		snap.ECMPAddrs = make([]string, len(h.ECMPAddrs))
		for i, a := range h.ECMPAddrs {
			snap.ECMPAddrs[i] = a.String()
		}
	}

	return snap
}

func (h *HopResult) lossPctLocked() float64 {
	effective := h.Sent - h.InFlight
	if effective <= 0 {
		return 0
	}

	return 100.0 * (1.0 - float64(h.Received)/float64(effective))
}

// HopSnapshot is a serializable, read-only view of a HopResult.
type HopSnapshot struct {
	HopNumber            int         `json:"hop_number"`
	Addr                 string      `json:"addr,omitempty"`
	Hostname             string      `json:"hostname,omitempty"`
	ECMPAddrs            []string    `json:"ecmp_addrs,omitempty"`
	ASN                  ASNInfo     `json:"asn,omitzero"`
	MPLSLabels           []MPLSLabel `json:"mpls_labels,omitempty"`
	Sent                 int         `json:"sent"`
	Received             int         `json:"received"`
	LossPct              float64     `json:"loss_pct"`
	LastUs               int64       `json:"last_us,omitempty"`
	AvgUs                int64       `json:"avg_us,omitempty"`
	MinUs                int64       `json:"min_us,omitempty"`
	MaxUs                int64       `json:"max_us,omitempty"`
	StdDevUs             int64       `json:"stddev_us,omitempty"`
	JitterUs             int64       `json:"jitter_us,omitempty"`
	JitterWorstUs        int64       `json:"jitter_worst_us,omitempty"`
	JitterInterarrivalUs int64       `json:"jitter_interarrival_us,omitempty"`
}

// TraceResult is the complete result of an MTR trace, ready for serialization.
type TraceResult struct {
	Target        string        `json:"target"`
	TargetIP      string        `json:"target_ip"`
	TargetReached bool          `json:"target_reached"`
	TotalHops     int           `json:"total_hops"`
	Protocol      string        `json:"protocol"`
	IPVersion     int           `json:"ip_version"`
	PacketSize    int           `json:"packet_size"`
	Hops          []HopSnapshot `json:"hops"`
	AgentID       string        `json:"agent_id,omitempty"`
	GatewayID     string        `json:"gateway_id,omitempty"`
	Timestamp     int64         `json:"timestamp"`
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}

	return x
}
