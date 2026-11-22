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

package netperf

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"
	"sync/atomic"
)

// ResponderSnapshot captures the Hub Responder's utilization gauges and counters.
type ResponderSnapshot struct {
	ActiveSessions      uint64
	SessionsTotal       uint64
	BusyRejectionsTotal uint64
	BytesTotal          uint64
}

type admissionController struct {
	mu                    sync.Mutex
	maxConcurrentSessions uint32
	maxTotalBandwidthBps  uint64
	activeSessions        uint32
	reservedBandwidthBps  uint64

	sessionsTotal       atomic.Uint64
	busyRejectionsTotal atomic.Uint64
	bytesTotal          atomic.Uint64
}

func newAdmissionController(maxSessions uint32, maxBandwidthBps uint64) *admissionController {
	sessions, bw := normalizeResponderLimits(maxSessions, maxBandwidthBps)
	return &admissionController{
		maxConcurrentSessions: sessions,
		maxTotalBandwidthBps:  bw,
	}
}

func normalizeResponderLimits(maxSessions uint32, maxBandwidthBps uint64) (uint32, uint64) {
	switch {
	case maxSessions == 0:
		maxSessions = DefaultMaxConcurrentSessions
	case maxSessions > MaxResponderSessions:
		maxSessions = MaxResponderSessions
	}

	switch {
	case maxBandwidthBps == 0:
		maxBandwidthBps = DefaultMaxTotalBandwidthBps
	case maxBandwidthBps < MinBandwidthBps:
		maxBandwidthBps = MinBandwidthBps
	case maxBandwidthBps > MaxResponderBandwidthBps:
		maxBandwidthBps = MaxResponderBandwidthBps
	}

	return maxSessions, maxBandwidthBps
}

func (a *admissionController) updateLimits(maxSessions uint32, maxBandwidthBps uint64) {
	sessions, bw := normalizeResponderLimits(maxSessions, maxBandwidthBps)
	a.mu.Lock()
	a.maxConcurrentSessions = sessions
	a.maxTotalBandwidthBps = bw
	a.mu.Unlock()
}

func (a *admissionController) tryAcquire(bandwidthBps uint64) (bool, uint32, string) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.activeSessions >= a.maxConcurrentSessions {
		a.busyRejectionsTotal.Add(1)
		return false, jitteredRetryAfterMs(), fmt.Sprintf(
			"responder concurrent session limit reached (%d/%d)",
			a.activeSessions, a.maxConcurrentSessions,
		)
	}
	if a.reservedBandwidthBps+bandwidthBps > a.maxTotalBandwidthBps {
		a.busyRejectionsTotal.Add(1)
		return false, jitteredRetryAfterMs(), fmt.Sprintf(
			"responder bandwidth budget exceeded (%d + %d > %d bps)",
			a.reservedBandwidthBps, bandwidthBps, a.maxTotalBandwidthBps,
		)
	}

	a.activeSessions++
	a.reservedBandwidthBps += bandwidthBps
	a.sessionsTotal.Add(1)
	return true, 0, ""
}

func (a *admissionController) release(bandwidthBps uint64) {
	a.mu.Lock()
	if a.activeSessions > 0 {
		a.activeSessions--
	}
	if a.reservedBandwidthBps >= bandwidthBps {
		a.reservedBandwidthBps -= bandwidthBps
	} else {
		a.reservedBandwidthBps = 0
	}
	a.mu.Unlock()
}

func (a *admissionController) addBytes(n uint64) {
	if n > 0 {
		a.bytesTotal.Add(n)
	}
}

func (a *admissionController) snapshot() ResponderSnapshot {
	a.mu.Lock()
	active := uint64(a.activeSessions)
	a.mu.Unlock()

	return ResponderSnapshot{
		ActiveSessions:      active,
		SessionsTotal:       a.sessionsTotal.Load(),
		BusyRejectionsTotal: a.busyRejectionsTotal.Load(),
		BytesTotal:          a.bytesTotal.Load(),
	}
}

func jitteredRetryAfterMs() uint32 {
	span := uint64(MaxRetryAfterMs - MinRetryAfterMs + 1)
	var raw [8]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return (MinRetryAfterMs + MaxRetryAfterMs) / 2
	}
	val := binary.BigEndian.Uint64(raw[:]) % span
	return MinRetryAfterMs + uint32(val)
}
