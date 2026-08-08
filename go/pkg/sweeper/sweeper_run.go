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

	return nil
}

func (s *NetworkSweeper) runSweepWithLock(ctx context.Context) error {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	return s.runSweep(ctx)
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	startedAt := time.Now()
	s.markSweepStarted()
	defer s.markSweepFinished()

	targetEstimate := estimateTargetCount(s.config)
	if targetEstimate > defaultTargetBatch {
		if err := s.runBatchedSweep(ctx, targetEstimate); err != nil {
			return err
		}

		return s.completeSuccessfulSweep(ctx, startedAt)
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
			// MTR is handled by the agent's ad-hoc scan path, not this persistent
			// sweeper run.
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

	bannerPhase := s.startBannerGrabPhase(ctx)
	finishedBannerPhase := false
	defer func() {
		if !finishedBannerPhase {
			s.abortBannerGrabPhase(bannerPhase)
		}
	}()

	var wg sync.WaitGroup

	errChan := make(chan error, 3) // Buffer for ICMP, TCP, and TCP connect errors

	if len(icmpTargets) > 0 && icmpScanner != nil {
		wg.Add(1)

		go func() {
			if err := s.scanAndProcess(ctx, &wg, icmpScanner, icmpTargets, "icmp"); err != nil {
				errChan <- err
			}
		}()
	} else if len(icmpTargets) > 0 {
		s.logger.Warn().Int("icmpTargets", len(icmpTargets)).Msg("ICMP targets found but ICMP scanner is not available, skipping ICMP scan")
	}

	if len(tcpTargets) > 0 && tcpScanner != nil {
		wg.Add(1)

		go func() {
			if err := s.scanAndProcess(ctx, &wg, tcpScanner, tcpTargets, scannerProtocolTCP); err != nil {
				errChan <- err
			}
		}()
	} else if len(tcpTargets) > 0 {
		s.logger.Warn().Int("tcpTargets", len(tcpTargets)).Msg("TCP targets found but TCP scanner is not available, skipping TCP scan")
	}

	if len(tcpConnectTargets) > 0 && tcpConnectScanner != nil {
		wg.Add(1)

		go func() {
			if err := s.scanAndProcess(ctx, &wg, tcpConnectScanner, tcpConnectTargets, "tcp_connect"); err != nil {
				errChan <- err
			}
		}()
	} else if len(tcpConnectTargets) > 0 {
		s.logger.Warn().Int("tcpConnectTargets", len(tcpConnectTargets)).Msg("TCP connect targets found but TCP connect scanner is not available, skipping TCP connect scan")
	}

	wg.Wait()
	close(errChan)

	// Check for any errors
	for err := range errChan {
		return err
	}

	err = s.finishBannerGrabPhase(bannerPhase)
	finishedBannerPhase = true
	if err != nil {
		return err
	}

	// Finalize and process aggregated device results
	s.finalizeDeviceAggregators(ctx)

	s.logger.Info().Msg("Sweep completed successfully")

	return s.completeSuccessfulSweep(ctx, startedAt)
}

func (s *NetworkSweeper) markSweepStarted() {
	s.mu.Lock()
	s.sweepInProgress = true
	s.mu.Unlock()
}

func (s *NetworkSweeper) markSweepFinished() {
	s.mu.Lock()
	s.sweepInProgress = false
	s.mu.Unlock()
}

func (s *NetworkSweeper) completeSuccessfulSweep(ctx context.Context, startedAt time.Time) error {
	if s.store != nil {
		age := time.Since(startedAt)
		if age > 0 {
			if err := s.store.PruneResults(ctx, age); err != nil {
				return fmt.Errorf("failed to prune pre-sweep results: %w", err)
			}
		}
	}

	completedAt := time.Now()

	if s.store != nil {
		summary, err := s.store.GetSweepSummary(ctx)
		if err != nil {
			return fmt.Errorf("failed to cache sweep summary: %w", err)
		}

		summary.LastSweep = completedAt.Unix()

		s.mu.Lock()
		s.lastSweep = completedAt
		s.lastSummary = cloneSweepSummary(summary)
		s.mu.Unlock()

		return nil
	}

	s.mu.Lock()
	s.lastSweep = completedAt
	s.lastSummary = nil
	s.mu.Unlock()

	return nil
}
