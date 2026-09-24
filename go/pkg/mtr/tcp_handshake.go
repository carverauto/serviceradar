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
	"context"
	"math"
	"sync"
	"time"
)

// tcpHandshake tracks the destination handshake phase of a TCP trace: after
// path probing, a fixed number of SYN "attempts" go to the target's TTL, and
// each unanswered attempt is re-sent up to the configured retries.
type tcpHandshake struct {
	mu       sync.Mutex
	ttl      int
	attempts []handshakeAttempt
	bySeq    map[int]handshakeSend
	updateCh chan struct{}

	synSent     int
	retransmits int
	duplicates  int
}

type handshakeAttempt struct {
	answered      bool
	afterRetx     bool
	synAck        bool
	rst           bool
	rtt           time.Duration
	transmissions int
}

type handshakeSend struct {
	attempt int
	retry   bool
	sentAt  time.Time
}

func newTCPHandshake(ttl, attempts int) *tcpHandshake {
	return &tcpHandshake{
		ttl:      ttl,
		attempts: make([]handshakeAttempt, attempts),
		bySeq:    make(map[int]handshakeSend, attempts*2), //nolint:mnd
		updateCh: make(chan struct{}, 1),
	}
}

// reserve registers seq as in flight for attempt before the SYN is written, so
// a reply cannot arrive before the phase knows the sequence. It does not count
// the send: confirm does that after the write, and release drops a reservation
// whose SYN never left the host. A send is a retransmission only when the
// attempt already had a successful transmission, so a first SYN that leaves
// after earlier local send failures is not counted as a retransmission.
func (h *tcpHandshake) reserve(seq, attempt int, at time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.bySeq[seq] = handshakeSend{
		attempt: attempt,
		retry:   h.attempts[attempt].transmissions > 0,
		sentAt:  at,
	}
}

// confirm records a reserved SYN that left the host.
func (h *tcpHandshake) confirm(seq int) {
	h.mu.Lock()
	defer h.mu.Unlock()

	send, ok := h.bySeq[seq]
	if !ok {
		return
	}

	h.attempts[send.attempt].transmissions++
	h.synSent++

	if send.retry {
		h.retransmits++
	}
}

// release drops a reserved sequence whose SYN was never sent.
func (h *tcpHandshake) release(seq int) {
	h.mu.Lock()
	defer h.mu.Unlock()

	delete(h.bySeq, seq)
}

// record credits a reply to the attempt its sequence belongs to. It returns
// false when seq is not one of the phase's SYNs.
func (h *tcpHandshake) record(reply *TCPReply) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	send, ok := h.bySeq[reply.Seq]
	if !ok {
		return false
	}

	attempt := &h.attempts[send.attempt]
	if attempt.answered {
		h.duplicates++
		return true
	}

	attempt.answered = true
	attempt.afterRetx = send.retry
	attempt.synAck = reply.SYNACK
	attempt.rst = reply.RST
	attempt.rtt = reply.RecvTime.Sub(send.sentAt)

	select {
	case h.updateCh <- struct{}{}:
	default:
	}

	return true
}

// unanswered lists attempts that have not been answered yet.
func (h *tcpHandshake) unanswered() []int {
	h.mu.Lock()
	defer h.mu.Unlock()

	pending := make([]int, 0, len(h.attempts))
	for i := range h.attempts {
		if !h.attempts[i].answered {
			pending = append(pending, i)
		}
	}

	return pending
}

// waitForAnswers blocks until every attempt is answered, timeout passes, or
// ctx is done.
func (h *tcpHandshake) waitForAnswers(ctx context.Context, timeout time.Duration) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for len(h.unanswered()) > 0 {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			return
		case <-h.updateCh:
		}
	}
}

// stats summarizes the phase. ackMismatch is counted by the tracer, because a
// mismatched acknowledgement cannot be attributed to any attempt.
func (h *tcpHandshake) stats(ackMismatch int) *TCPHandshakeStats {
	h.mu.Lock()
	defer h.mu.Unlock()

	stats := &TCPHandshakeStats{
		TTL:              h.ttl,
		Attempts:         len(h.attempts),
		SYNSent:          h.synSent,
		Retransmits:      h.retransmits,
		AckMismatch:      ackMismatch,
		SYNACKDuplicates: h.duplicates,
	}

	var sumUs int64

	answered := 0

	for _, attempt := range h.attempts {
		if !attempt.answered {
			if attempt.transmissions > 0 {
				stats.Unanswered++
			}
			continue
		}

		answered++
		if attempt.synAck {
			stats.SYNACKReceived++
		}
		if attempt.rst {
			stats.RSTReceived++
		}
		if attempt.afterRetx {
			stats.AnsweredAfterRetx++
		}

		us := attempt.rtt.Microseconds()
		sumUs += us

		if stats.RTTMinUs == 0 || us < stats.RTTMinUs {
			stats.RTTMinUs = us
		}
		if us > stats.RTTMaxUs {
			stats.RTTMaxUs = us
		}
	}

	tried := answered + stats.Unanswered
	if tried > 0 {
		stats.DropPct = 100.0 * float64(stats.Unanswered) / float64(tried)
	}
	if answered > 0 {
		stats.RTTAvgUs = int64(math.Round(float64(sumUs) / float64(answered)))
	}

	return stats
}

// runTCPHandshake sends the destination handshake phase for a crafted-SYN
// TCP trace. It runs after path probing, while the receive loops are still
// running, and is bounded by (1 + retries) probe timeouts or ctx.
func (t *Tracer) runTCPHandshake(ctx context.Context) {
	if t.tcpFlow == nil || !t.tcpFlow.Crafted() || ctx.Err() != nil {
		return
	}

	ttl := t.targetHopNumber()
	if ttl == 0 {
		ttl = t.opts.MaxHops
	}

	attempts := max(t.opts.ProbesPerHop, 1)
	retries := min(max(t.opts.TCPSynRetries, 0), MaxTCPSynRetries)
	timeout := t.opts.Timeout

	if timeout <= 0 {
		timeout = DefaultTimeout
	}

	hs := newTCPHandshake(ttl, attempts)

	t.handshakeMu.Lock()
	t.handshake = hs
	t.handshakeMu.Unlock()

	pending := make([]int, attempts)
	for i := range pending {
		pending[i] = i
	}

	for round := 0; round <= retries && len(pending) > 0; round++ {
		wait := roundWait(ctx, timeout, retries+1-round)

		for _, attempt := range pending {
			if ctx.Err() != nil {
				return
			}

			seq := t.allocateSeq()

			hs.reserve(seq, attempt, time.Now())

			if err := t.tcpFlow.SendSYN(ttl, seq); err != nil {
				t.lastSendErr = err
				hs.release(seq)
				t.logger.Debug().Err(err).Int("ttl", ttl).Msg("send handshake SYN failed")
				continue
			}

			hs.confirm(seq)

			if !waitForProbeInterval(ctx, t.opts.ProbeInterval) {
				return
			}
		}

		hs.waitForAnswers(ctx, wait)
		pending = hs.unanswered()
	}
}

// roundWait is how long a handshake round waits for answers: the probe
// timeout, or the round's share of what is left of ctx when that is shorter.
func roundWait(ctx context.Context, timeout time.Duration, roundsLeft int) time.Duration {
	deadline, ok := ctx.Deadline()
	if !ok || roundsLeft <= 0 {
		return timeout
	}

	return min(timeout, time.Until(deadline)/time.Duration(roundsLeft))
}

// recordHandshakeReply routes a reply to the handshake phase when it answers
// one of the phase's SYNs.
func (t *Tracer) recordHandshakeReply(reply *TCPReply) bool {
	t.handshakeMu.Lock()
	hs := t.handshake
	t.handshakeMu.Unlock()

	return hs != nil && hs.record(reply)
}

// handshakeResult summarizes the phase, estimating the target's own response
// time from the last transit hop that answered below the handshake TTL.
func (t *Tracer) handshakeResult() *TCPHandshakeStats {
	t.handshakeMu.Lock()
	hs := t.handshake
	t.handshakeMu.Unlock()

	if hs == nil {
		return nil
	}

	stats := hs.stats(int(t.ackMismatch.Load()))

	if transit := t.lastTransitAvgUs(stats.TTL); transit > 0 && stats.RTTAvgUs > 0 {
		response := max(stats.RTTAvgUs-transit, 0)
		stats.ServerResponseUs = &response
	}

	return stats
}

// lastTransitAvgUs is the RTT average of the deepest hop below ttl that
// answered and is not the target itself.
func (t *Tracer) lastTransitAvgUs(ttl int) int64 {
	for i := min(ttl-1, len(t.hops)) - 1; i >= 0; i-- {
		hop := t.hops[i]
		if hop == nil {
			continue
		}

		hop.mu.RLock()
		transit := hop.Received > 0 && hop.Addr != nil && !hop.Addr.Equal(t.targetIP)
		avg := hop.mean
		hop.mu.RUnlock()

		if transit {
			return int64(math.Round(avg))
		}
	}

	return 0
}
