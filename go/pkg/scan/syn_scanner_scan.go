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
func (s *SYNScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	tcpTargets := filterSYNTargets(targets)
	resultCh := make(chan models.Result, len(tcpTargets))

	if len(tcpTargets) == 0 {
		close(resultCh)
		return resultCh, nil
	}

	// Fail fast rather than queue behind this scanner's own running scan.
	if s.scanRunning() {
		return nil, ErrScanAlreadyRunning
	}

	// Raw SYN scans sharing this scanner's gate run one at a time; the
	// teardown below releases the gate once this scan has stopped listening.
	gate := s.gate
	if err := s.waitForScanGate(ctx, gate); err != nil {
		return nil, err
	}

	scanCtx, cancel := context.WithCancel(ctx)

	s.ensureWakeFD()

	scanStartTime := time.Now()

	// Start telemetry logging tied to scan lifecycle
	go s.logTelemetry(scanCtx)

	if err := s.beginScan(scanCtx, cancel, len(tcpTargets)); err != nil {
		cancel() // Ensure we don't leak the context
		gate.release()

		return nil, err
	}

	emitter := newSYNResultEmitter(len(tcpTargets))
	go emitter.run(resultCh, s.teeToUserCallback)

	s.mu.Lock()
	s.resultCallback = emitter.emitOnce
	s.mu.Unlock()

	// Start ring readers (one goroutine per ring) — manage with scanner-level WG

	go func() {
		defer s.readersWG.Done()

		s.listenForReplies(scanCtx)
	}()

	senders := s.startSenders(scanCtx, tcpTargets)

	// Aggregate
	go func() {
		senders.Wait()

		s.stopListening(cancel)
		s.emitUnreportedResults(tcpTargets, emitter)
		s.logScanCompletion(time.Since(scanStartTime), len(tcpTargets))
		emitter.finish()
		s.releaseScanState()

		gate.release()
	}()

	return resultCh, nil
}

// ensureWakeFD creates the eventfd ring readers block on, when
// SR_SYN_USE_EVENTFD=1 asks for it; otherwise readers poll with a timeout.
func (s *SYNScanner) ensureWakeFD() {
	if s.wakeFD != 0 || os.Getenv("SR_SYN_USE_EVENTFD") != "1" {
		return
	}

	fd, err := unix.Eventfd(0, 0)
	if err != nil {
		// Fall back to timeout-based poll
		s.logger.Debug().Err(err).Msg("eventfd unavailable; using timeout-based ring polling")

		return
	}

	_ = unix.SetNonblock(fd, true)
	s.wakeFD = fd
	s.logger.Debug().Msg("Using eventfd for ring wakeups")
}

// beginScan atomically claims the scanner for a scan of targetCount targets:
// it starts capture, resets the per-scan state and starts the retry
// scheduler. It returns ErrScanAlreadyRunning if another scan holds the
// scanner.
func (s *SYNScanner) beginScan(scanCtx context.Context, cancel context.CancelFunc, targetCount int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cancel != nil {
		return ErrScanAlreadyRunning
	}

	if err := s.startCaptureLocked(); err != nil {
		return err
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

	s.results = make(map[string]models.Result, targetCount)
	s.portTargetMap = make(map[uint16]string, targetCount)
	s.targetPorts = make(map[string][]uint16, targetCount)
	s.targetIP = make(map[string]string, targetCount)

	return nil
}

// teeToUserCallback hands r to the user callback, if one is set. It runs on
// the emitter goroutine, never on a ring reader.
func (s *SYNScanner) teeToUserCallback(r models.Result) {
	if cbAny := s.userCallback.Load(); cbAny != nil {
		if cb, _ := cbAny.(func(models.Result)); cb != nil {
			cb(r)
		}
	}
}

// startSenders starts the worker pool that sends SYN packets and feeds it
// targets. The returned group completes once every worker has exited.
func (s *SYNScanner) startSenders(scanCtx context.Context, targets []models.Target) *sync.WaitGroup {
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
		for _, t := range targets {
			select {
			case workCh <- t:
			case <-scanCtx.Done():
				return
			}
		}

		close(workCh)
	}()

	return &senderWg
}

// stopListening waits a short grace for late replies, then cancels the scan,
// wakes and waits for the ring readers, and stops capturing. Capture stops
// before the final drop sample, so replies that arrive after the readers exit
// are neither queued nor counted as drops.
func (s *SYNScanner) stopListening(cancel context.CancelFunc) {
	// Shorter grace for late replies
	grace := min(s.timeout/timeoutGraceDivisor, defaultGracePeriod)

	time.Sleep(grace)

	cancel()
	// Wake any blocking ring readers once after cancel
	if s.wakeFD > 0 {
		var one [8]byte

		one[7] = 1
		_, _ = unix.Write(s.wakeFD, one[:])
	}

	s.readersWG.Wait()

	s.mu.Lock()
	s.stopCaptureLocked()
	s.mu.Unlock()
}

// emitUnreportedResults emits a result for every target the scan has not
// streamed yet: its recorded result, or a timeout. It then stops future
// callback enqueues.
func (s *SYNScanner) emitUnreportedResults(targets []models.Target, emitter *synResultEmitter) {
	s.mu.Lock()

	for _, t := range targets {
		key := fmt.Sprintf("%s:%d", t.Host, t.Port)
		if !emitter.claim(key) {
			continue
		}

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

		emitter.emitCh <- r

		s.mu.Lock()
	}

	// Stop future callback enqueues and finish the emitter cleanly.
	s.resultCallback = nil
	s.mu.Unlock()
}

// logScanCompletion logs the final telemetry of a scan, which is especially
// useful for short scans.
func (s *SYNScanner) logScanCompletion(scanDuration time.Duration, targetCount int) {
	// One last PACKET_STATISTICS read so drops are up-to-date
	s.sampleKernelStats()
	stats := s.GetStats()
	s.logger.Info().
		Dur("scanDuration", scanDuration).
		Int("targetCount", targetCount).
		Uint64("packetsSent", stats.PacketsSent).
		Uint64("packetsRecv", stats.PacketsRecv).
		Uint64("packetsDropped", stats.PacketsDropped).
		Uint64("rateLimitDeferrals", stats.RateLimitDeferrals).
		Uint64("rateLimitWaits", stats.RateLimitWaits).
		Uint64("sourcePortWaits", stats.SourcePortWaits).
		Uint64("retriesAttempted", stats.RetriesAttempted).
		Uint64("retriesDropped", stats.RetriesDropped).
		Msg("Scan completed")
}

// releaseScanState ends the scan: it clears the cancel func, resets the
// per-scan maps so their memory can be collected, closes the wake eventfd and
// releases any leftover source ports.
func (s *SYNScanner) releaseScanState() {
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
}

// synResultEmitter streams a scan's results to its consumer exactly once per
// target, from one goroutine, so ring readers never block on the consumer or
// run the user callback.
type synResultEmitter struct {
	mu      sync.Mutex
	emitted map[string]struct{}
	// emitCh is buffered to the exact number of TCP targets; claim admits at
	// most one result per target, so sends never block in practice.
	emitCh chan models.Result
	stop   chan struct{}
	done   chan struct{}
}

func newSYNResultEmitter(targetCount int) *synResultEmitter {
	return &synResultEmitter{
		emitted: make(map[string]struct{}, targetCount),
		emitCh:  make(chan models.Result, targetCount),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
}

// claim reports whether key has not been emitted yet, and marks it emitted.
func (e *synResultEmitter) claim(key string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()

	if _, seen := e.emitted[key]; seen {
		return false
	}

	e.emitted[key] = struct{}{}

	return true
}

// emitOnce queues r unless a result for its target was already emitted.
func (e *synResultEmitter) emitOnce(r models.Result) {
	if e.claim(fmt.Sprintf("%s:%d", r.Target.Host, r.Target.Port)) {
		e.emitCh <- r
	}
}

// run forwards queued results to resultCh, teeing each to tee, until finish is
// called; it then drains what is left and closes resultCh exactly once.
func (e *synResultEmitter) run(resultCh chan<- models.Result, tee func(models.Result)) {
	defer close(e.done)

	for {
		select {
		case r := <-e.emitCh:
			resultCh <- r
			tee(r)
		case <-e.stop:
			for {
				select {
				case r := <-e.emitCh:
					resultCh <- r
					tee(r)
				default:
					close(resultCh)

					return
				}
			}
		}
	}
}

// finish signals run to drain and close the results channel, and waits for it.
func (e *synResultEmitter) finish() {
	close(e.stop)
	<-e.done
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
