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

package sweeper

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func (s *NetworkSweeper) handleStreamComplete(ctx context.Context, resultBatch []models.Result, scanType string, count, success int) error {
	// Channel closed, process final batch if any
	if len(resultBatch) > 0 {
		if err := s.processBatchedResults(ctx, resultBatch); err != nil {
			s.logger.Error().Err(err).Str("scanType", scanType).Msg("Failed to process final result batch")
		}
	}

	s.logger.Info().
		Str("scanType", scanType).
		Int("totalResults", count).
		Int("successful", success).
		Msg("Scan complete - all results received")

	return nil
}

// processSingleResult processes a single result and updates counters.
func (*NetworkSweeper) processSingleResult(result *models.Result, resultBatch *[]models.Result,
	count, success int) (newCount, newSuccess int) {
	count++

	if result.Available {
		success++
	}

	// Add to batch
	*resultBatch = append(*resultBatch, *result)

	return count, success
}

// processBatchIfFull processes a batch if it's full and resets the slice.
func (s *NetworkSweeper) processBatchIfFull(ctx context.Context, resultBatch *[]models.Result, scanType string, count, success int) error {
	const batchSize = 1000

	// Process batch when it's full
	if len(*resultBatch) >= batchSize {
		if err := s.processBatchedResults(ctx, *resultBatch); err != nil {
			s.logger.Error().Err(err).Str("scanType", scanType).Msg("Failed to process result batch")

			return err
		}

		// Reset batch slice but keep capacity to avoid reallocation
		*resultBatch = (*resultBatch)[:0]

		// Progress logging is noisy at scale; keep at debug level only
		s.logger.Debug().Str("scanType", scanType).Int("processed", count).Int("successful", success).Msg("Scan progress")
	}

	return nil
}

// handleContextDone handles completion when context is canceled/timeout.
func (s *NetworkSweeper) handleContextDone(ctx context.Context, resultBatch []models.Result, scanType string, count, success int) error {
	// Timeout reached, process any remaining batch
	if len(resultBatch) > 0 {
		if err := s.processBatchedResults(ctx, resultBatch); err != nil {
			s.logger.Error().Err(err).Str("scanType", scanType).Msg("Failed to process remaining result batch")
		}
	}

	s.logger.Info().Str("scanType", scanType).Int("totalResults", count).Int("successful", success).Msg("Scan complete - timeout reached")

	return ctx.Err()
}

// drainErrChan collects all errors from the (already-closed) channel and
// reports the first, along with whether every error was a context cancellation.
func drainErrChan(errChan <-chan error) (first error, allContext bool) {
	allContext = true

	for err := range errChan {
		if first == nil {
			first = err
		}

		if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
			allContext = false
		}
	}

	return first, allContext
}

// ErrSweepCancelled reports a run aborted by CancelRun. Its partial results are
// discarded rather than committed as a completed sweep.
var ErrSweepCancelled = errors.New("sweep run cancelled")

// sweepRun tracks the in-flight run so CancelRun can abort it.
type sweepRun struct {
	cancel    context.CancelFunc
	cancelled bool
}

type executionCheckKey struct{}

func WithExecutionCheck(ctx context.Context, check func() error) context.Context {
	return context.WithValue(ctx, executionCheckKey{}, check)
}

func CheckExecution(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if check, ok := ctx.Value(executionCheckKey{}).(func() error); ok {
		return check()
	}
	return nil
}

func (s *NetworkSweeper) runSweepWithLock(ctx context.Context) error {
	return s.runSweepWithExecution(ctx, "")
}

// runSweepWithExecution holds the sweep lock for one cycle and publishes
// executionID only if that cycle completes. A failed or stopped cycle leaves
// the previously published id in place.
func (s *NetworkSweeper) runSweepWithExecution(ctx context.Context, executionID string) error {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	if err := CheckExecution(ctx); err != nil {
		return err
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	run := &sweepRun{cancel: cancel}

	s.mu.Lock()
	s.activeRun = run
	s.runExecutionID = executionID
	s.mu.Unlock()

	err := s.runSweep(runCtx)

	s.mu.Lock()
	if s.activeRun == run {
		s.activeRun = nil
	}
	s.runExecutionID = ""
	cancelled := run.cancelled
	s.mu.Unlock()

	if cancelled {
		return ErrSweepCancelled
	}

	return err
}

// CancelRun aborts the in-flight sweep, if any, and reports whether one was
// running. The aborted run's partial results are never committed, so nothing
// further is streamed for it; scheduled sweeps continue at their interval.
func (s *NetworkSweeper) CancelRun() bool {
	s.mu.Lock()
	run := s.activeRun
	if run == nil {
		s.mu.Unlock()
		return false
	}

	alreadyCancelled := run.cancelled
	run.cancelled = true
	s.partialRunPending = true
	s.mu.Unlock()

	if !alreadyCancelled {
		s.logger.Info().Msg("Cancelling in-flight sweep on request")
		run.cancel()
	}

	return true
}

// cancelRequestedLocked reports whether the in-flight run was cancelled. The
// caller must hold s.mu.
func (s *NetworkSweeper) cancelRequestedLocked() bool {
	return s.activeRun != nil && s.activeRun.cancelled
}

// logRunError logs a failed run; a requested cancellation is not a failure.
func (s *NetworkSweeper) logRunError(err error, msg string) {
	if errors.Is(err, ErrSweepCancelled) {
		s.logger.Info().Msg("Sweep run cancelled on request")
		return
	}

	s.logger.Error().Err(err).Msg(msg)
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	startedAt := time.Now()
	s.markSweepStarted()
	defer s.markSweepFinished()

	targetEstimate := estimateTargetCount(s.config)
	if targetEstimate > defaultTargetBatch {
		if err := s.runBatchedSweep(ctx, targetEstimate); err != nil {
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				return s.completeCancelledSweep(ctx, startedAt)
			}

			return err
		}

		return s.completeSuccessfulSweep(ctx, startedAt, false)
	}

	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}
	routeSummary := summarizeTargetRoutes(targets)

	// Prepare device result aggregators for multi-IP devices
	s.prepareDeviceAggregators(targets)

	var icmpTargets, tcpTargets, tcpConnectTargets []models.Target

	for _, t := range targets {
		switch t.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, t)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, t)
		case models.ModeTCPConnect:
			tcpConnectTargets = append(tcpConnectTargets, t)
		case models.ModeMTR:
		}
	}

	s.mu.RLock()
	icmpScanner := s.icmpScanner
	tcpScanner := s.tcpScanner
	tcpConnectScanner := s.tcpConnectScanner
	s.mu.RUnlock()
	icmpCaps := scannerCapabilities(icmpScanner)
	tcpCaps := scannerCapabilities(tcpScanner)
	tcpConnectCaps := scannerCapabilities(tcpConnectScanner)

	// An empty config still finishes the run so previous results are pruned.
	// It must not claim that a scan started. A configured network that
	// expands to zero hosts is a real sweep and keeps the start log.
	nothingToScan := len(s.config.Networks) == 0 && len(s.config.DeviceTargets) == 0
	if nothingToScan {
		s.logger.Info().
			Int("networkCount", 0).
			Int("deviceTargetCount", 0).
			Msg("Nothing to scan")
	} else {
		s.logger.Info().
			Int("icmpTargets", len(icmpTargets)).
			Int("tcpTargets", len(tcpTargets)).
			Int("tcpConnectTargets", len(tcpConnectTargets)).
			Int("ipv4Targets", routeSummary.ipv4Targets).
			Int("ipv6Targets", routeSummary.ipv6Targets).
			Int("ipv6TCPConnectFallbackTargets", routeSummary.ipv6TCPConnectFallbackTargets).
			Bool("icmpScannerAvailable", icmpScanner != nil).
			Bool("tcpScannerAvailable", tcpScanner != nil).
			Bool("tcpConnectScannerAvailable", tcpConnectScanner != nil).
			Bool("icmpIPv4Available", icmpCaps.ICMPv4).
			Bool("icmpIPv6Available", icmpCaps.ICMPv6).
			Bool("tcpRawSYNIPv4Available", tcpCaps.RawSYNIPv4).
			Bool("tcpRawSYNIPv6Available", tcpCaps.RawSYNIPv6).
			Bool("tcpConnectIPv4Available", tcpConnectCaps.TCPConnectIPv4).
			Bool("tcpConnectIPv6Available", tcpConnectCaps.TCPConnectIPv6).
			Msg("Starting sweep")
	}

	bannerPhase := s.startBannerGrabPhase(ctx)
	finishedBannerPhase := false
	defer func() {
		if !finishedBannerPhase {
			s.abortBannerGrabPhase(bannerPhase)
		}
	}()

	var wg sync.WaitGroup

	errChan := make(chan error, 3) // Buffer for ICMP, TCP, and TCP connect errors

	if s.scannerReady("icmp", icmpScanner, len(icmpTargets)) {
		wg.Add(1)

		go s.scanAndProcess(ctx, &wg, errChan, icmpScanner, icmpTargets, "icmp")
	}

	if s.scannerReady(scannerProtocolTCP, tcpScanner, len(tcpTargets)) {
		wg.Add(1)

		go s.scanAndProcess(ctx, &wg, errChan, tcpScanner, tcpTargets, scannerProtocolTCP)
	}

	if s.scannerReady("tcp_connect", tcpConnectScanner, len(tcpConnectTargets)) {
		wg.Add(1)

		go s.scanAndProcess(ctx, &wg, errChan, tcpConnectScanner, tcpConnectTargets, "tcp_connect")
	}

	wg.Wait()
	close(errChan)

	if firstErr, allContext := drainErrChan(errChan); firstErr != nil {
		if allContext {
			return s.completeCancelledSweep(ctx, startedAt)
		}

		return firstErr
	}

	err = s.finishBannerGrabPhase(bannerPhase)
	finishedBannerPhase = true
	if err != nil {
		return err
	}

	// Finalize and process aggregated device results
	s.finalizeDeviceAggregators(ctx)

	if !nothingToScan {
		s.logger.Info().Msg("Sweep completed successfully")
	}

	return s.completeSuccessfulSweep(ctx, startedAt, false)
}

// completeCancelledSweep commits whatever partial results were gathered when
// the scan hit its wall-clock timeout, and marks the run as cancelled so
// callers can report the correct execution status. A run aborted by CancelRun
// is discarded instead.
func (s *NetworkSweeper) completeCancelledSweep(ctx context.Context, startedAt time.Time) error {
	s.mu.Lock()
	if s.cancelRequestedLocked() {
		s.mu.Unlock()
		return ErrSweepCancelled
	}
	s.mu.Unlock()

	return s.completeSuccessfulSweep(ctx, startedAt, true)
}

// WasCancelledSweep returns true when the most-recently-completed sweep was
// cut short by the configured scan timeout.
func (s *NetworkSweeper) WasCancelledSweep() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.lastSweepCancelled
}

func (s *NetworkSweeper) markSweepStarted() {
	s.mu.Lock()
	s.sweepInProgress = true
	s.lastSweepCancelled = false
	s.mu.Unlock()
}

func (s *NetworkSweeper) markSweepFinished() {
	s.mu.Lock()
	s.sweepInProgress = false
	s.mu.Unlock()
}

func (s *NetworkSweeper) completeSuccessfulSweep(ctx context.Context, startedAt time.Time, markCancelled bool) error {
	if s.store != nil {
		age := time.Since(startedAt)
		if age > 0 {
			if err := s.store.PruneResults(ctx, age); err != nil {
				return fmt.Errorf("failed to prune pre-sweep results: %w", err)
			}
		}
	}

	completedAt := time.Now()

	var summary *models.SweepSummary

	if s.store != nil {
		var err error

		summary, err = s.store.GetSweepSummary(ctx)
		if err != nil {
			return fmt.Errorf("failed to cache sweep summary: %w", err)
		}

		summary.LastSweep = completedAt.Unix()
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Committing and CancelRun share s.mu, so a run is either published here or
	// cancelled, never both. A published run can no longer be cancelled.
	if s.cancelRequestedLocked() {
		return ErrSweepCancelled
	}

	s.activeRun = nil
	s.partialRunPending = false
	s.lastExecutionID = s.runExecutionID
	if summary != nil {
		summary.ExecutionID = s.runExecutionID
	}
	s.lastSweep = completedAt
	s.lastSummary = cloneSweepSummary(summary)
	s.lastSweepCancelled = markCancelled

	return nil
}
