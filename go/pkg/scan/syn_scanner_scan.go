//go:build linux
// +build linux

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

package scan

import (
	"context"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"golang.org/x/sys/unix"
)

// Scan performs SYN scanning on the given targets
//
//nolint:gocyclo // Complex scanning logic with multiple execution paths and error handling
func (s *SYNScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterSYNTargets(targets)
	resultCh := make(chan models.Result, len(tcpTargets))

	if len(tcpTargets) == 0 {
		close(resultCh)
		return resultCh, nil
	}

	scanCtx, cancel := context.WithCancel(ctx)

	// Create wake eventfd (optional, gated by env SR_SYN_USE_EVENTFD=1)
	if s.wakeFD == 0 {
		if os.Getenv("SR_SYN_USE_EVENTFD") == "1" {
			fd, err := unix.Eventfd(0, 0)
			if err == nil {
				_ = unix.SetNonblock(fd, true)
				s.wakeFD = fd
				s.logger.Debug().Msg("Using eventfd for ring wakeups")
			} else {
				// Fall back to timeout-based poll
				s.logger.Debug().Err(err).Msg("eventfd unavailable; using timeout-based ring polling")
			}
		}
	}

	scanStartTime := time.Now()

	// Start telemetry logging tied to scan lifecycle
	go s.logTelemetry(scanCtx)

	// Initialize state for the new scan and atomically set up the scan
	s.mu.Lock()

	if s.cancel != nil {
		s.mu.Unlock()
		cancel() // Ensure we don't leak the context
		return nil, ErrScanAlreadyRunning
	}

	s.ResetStats()

	s.cancel = cancel
	s.readersWG.Add(1) // MUST come before Stop() can see non-nil cancel

	// init retry queue for this scan
	s.retryCh = make(chan retryItem, retryQueueSize)

	// start retry scheduler (and wait for it in teardown)
	s.readersWG.Add(1)

	go func() {
		defer s.readersWG.Done()

		s.runRetryQueue(scanCtx)
	}()

	s.results = make(map[string]models.Result, len(tcpTargets))
	s.portTargetMap = make(map[uint16]string, len(tcpTargets))
	s.targetPorts = make(map[string][]uint16, len(tcpTargets))
	s.targetIP = make(map[string]string, len(tcpTargets))

	s.mu.Unlock()

	// Stream results immediately to resultCh (deduped so the final pass won't resend)
	emitted := make(map[string]struct{}, len(tcpTargets))

	var emittedMu sync.Mutex

	// Dedicated emitter to avoid per-result goroutines.
	// Buffered to the exact number of TCP targets; the callback enqueues at most once per target.
	emitCh := make(chan models.Result, len(tcpTargets))
	stopEmit := make(chan struct{})
	emitterDone := make(chan struct{})

	// Single goroutine drains emitCh -> resultCh, then closes resultCh after a stop signal + drain.
	go func() {
		defer close(emitterDone)

		for {
			select {
			case r := <-emitCh:
				// Forward to consumer
				resultCh <- r

				// Tee to user callback here (not in ring threads)
				if cbAny := s.userCallback.Load(); cbAny != nil {
					if cb, _ := cbAny.(func(models.Result)); cb != nil {
						cb(r)
					}
				}
			case <-stopEmit:
				// Drain any residual items and close the results channel exactly once.
				for {
					select {
					case r := <-emitCh:
						resultCh <- r

						if cbAny := s.userCallback.Load(); cbAny != nil {
							if cb, _ := cbAny.(func(models.Result)); cb != nil {
								cb(r)
							}
						}
					default:
						close(resultCh)

						return
					}
				}
			}
		}
	}()

	s.mu.Lock()
	s.resultCallback = func(r models.Result) {
		key := fmt.Sprintf("%s:%d", r.Target.Host, r.Target.Port)

		emittedMu.Lock()

		if _, seen := emitted[key]; seen {
			emittedMu.Unlock()
			return
		}

		emitted[key] = struct{}{}

		emittedMu.Unlock()

		// Non-blocking in practice: emitCh capacity == len(tcpTargets) and we enqueue ≤1 per target.
		emitCh <- r
	}

	s.mu.Unlock()

	// Start ring readers (one goroutine per ring) — manage with scanner-level WG

	go func() {
		defer s.readersWG.Done()

		s.listenForReplies(scanCtx)
	}()

	// Start worker pool to send SYN packets
	workCh := make(chan models.Target, s.concurrency)

	var senderWg sync.WaitGroup

	for i := 0; i < s.concurrency; i++ {
		senderWg.Add(1)

		go func() {
			defer senderWg.Done()

			s.worker(scanCtx, workCh)
		}()
	}

	// Feed targets to workers
	go func() {
		for _, t := range tcpTargets {
			select {
			case workCh <- t:
			case <-scanCtx.Done():
				return
			}
		}

		close(workCh)
	}()

	// Aggregate
	go func() {
		senderWg.Wait()

		// Shorter grace for late replies
		grace := s.timeout / timeoutGraceDivisor
		if grace > defaultGracePeriod {
			grace = defaultGracePeriod
		}

		time.Sleep(grace)

		cancel()
		// Wake any blocking ring readers once after cancel
		if s.wakeFD > 0 {
			var one [8]byte

			one[7] = 1
			_, _ = unix.Write(s.wakeFD, one[:])
		}

		s.readersWG.Wait()

		// Fallback: emit anything not yet streamed (via emitter so user callback is tee'd)
		s.mu.Lock()

		for _, t := range tcpTargets {
			key := fmt.Sprintf("%s:%d", t.Host, t.Port)

			emittedMu.Lock()

			if _, seen := emitted[key]; seen {
				emittedMu.Unlock()
				continue
			}

			emitted[key] = struct{}{}

			emittedMu.Unlock()

			r, ok := s.results[key]
			if !ok {
				r = models.Result{
					Target:    t,
					Available: false,
					Error:     ErrScanTimedOut,
					FirstSeen: time.Now(),
					LastSeen:  time.Now(),
				}
			} else if !r.Available && r.Error == nil {
				r.Error = ErrScanTimedOut
			}

			// Release lock while enqueueing; emitter handles backpressure and user callback tee.
			s.mu.Unlock()

			emitCh <- r

			s.mu.Lock()
		}

		// Stop future callback enqueues and finish the emitter cleanly.
		s.resultCallback = nil
		s.mu.Unlock()

		// Log final telemetry for scan completion (especially useful for short scans)
		scanDuration := time.Since(scanStartTime)
		// One last PACKET_STATISTICS read so drops are up-to-date
		s.sampleKernelStats()
		stats := s.GetStats()
		s.logger.Info().
			Dur("scanDuration", scanDuration).
			Int("targetCount", len(tcpTargets)).
			Uint64("packetsSent", stats.PacketsSent).
			Uint64("packetsRecv", stats.PacketsRecv).
			Uint64("packetsDropped", stats.PacketsDropped).
			Uint64("rateLimitDeferrals", stats.RateLimitDeferrals).
			Uint64("rateLimitWaits", stats.RateLimitWaits).
			Uint64("sourcePortWaits", stats.SourcePortWaits).
			Uint64("retriesAttempted", stats.RetriesAttempted).
			Uint64("retriesDropped", stats.RetriesDropped).
			Msg("Scan completed")

		close(stopEmit) // signal emitter to drain and close resultCh
		<-emitterDone   // wait for emitter to finish

		s.mu.Lock()

		if s.cancel != nil {
			s.cancel = nil
		}

		// Proactively release any leftover port mappings and clear per-scan maps
		toRelease := make([]uint16, 0, len(s.portTargetMap))
		for sp := range s.portTargetMap {
			toRelease = append(toRelease, sp)
		}

		// Reset maps to allow GC of large per-scan state
		s.portTargetMap = make(map[uint16]string)
		s.targetPorts = make(map[string][]uint16)
		s.targetIP = make(map[string]string)
		s.results = make(map[string]models.Result)
		s.portDeadline = make(map[uint16]time.Time)
		s.retryCh = nil
		// Close wakeFD now that readers have exited
		if s.wakeFD > 0 {
			_ = unix.Close(s.wakeFD)
			s.wakeFD = 0
		}

		s.mu.Unlock()

		// Release ports outside the lock
		for _, sp := range toRelease {
			s.portAlloc.Release(sp)
			atomic.AddUint64(&s.stats.PortsReleased, 1)
		}
	}()

	return resultCh, nil
}

func filterSYNTargets(targets []models.Target) []models.Target {
	var filtered []models.Target

	for _, t := range targets {
		if t.Mode == models.ModeTCP {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
