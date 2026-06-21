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
	"net"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
)

// NetworkSweeper implements both Sweeper and SweepService interfaces.
type NetworkSweeper struct {
	config            *models.Config
	icmpScanner       scan.Scanner
	tcpScanner        scan.Scanner // SYN scanner (fast but breaks conntrack)
	tcpConnectScanner scan.Scanner // TCP connect scanner (safe for conntrack)
	store             Store
	processor         ResultProcessor
	deviceRegistry    DeviceRegistryService
	logger            logger.Logger
	mu                sync.RWMutex
	runMu             sync.Mutex
	done              chan struct{}
	stopped           bool
	lastSweep         time.Time
	// Device result aggregation for multi-IP devices
	deviceResults   map[string]*DeviceResultAggregator
	resultsMu       sync.Mutex
	tickerReset     chan struct{}
	bannerMu        sync.RWMutex
	bannerPhase     *banner_grab.Engine
	lastBannerStats *models.BannerGrabStats
	bannerHandler   BannerObservationHandler
	sweepInProgress bool
	lastSummary     *models.SweepSummary
}

// DeviceResultAggregator aggregates scan results for a device with multiple IPs
type DeviceResultAggregator struct {
	DeviceID    string
	Results     []*models.Result
	ExpectedIPs []string
	Metadata    map[string]interface{}
	AgentID     string
	GatewayID   string
	Partition   string
	mu          sync.Mutex
}

// Start begins periodic sweeping.
func (s *NetworkSweeper) Start(ctx context.Context) error {
	s.logger.Info().Dur("interval", s.config.Interval).Msg("Starting network sweeper")

	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping start")
		return nil
	default:
	}

	s.ensureScannersInitialized()

	initialCtx, initialCancel := context.WithTimeout(ctx, scanTimeout)
	if err := s.runSweepWithLock(initialCtx); err != nil {
		initialCancel()

		s.logger.Error().Err(err).Msg("Initial sweep failed")
	} else {
		s.logger.Info().Msg("Initial sweep completed successfully")
	}

	initialCancel()

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	s.logger.Debug().Dur("interval", s.config.Interval).Msg("Entering sweep loop")

	for {
		select {
		case <-ctx.Done():
			s.logger.Info().Msg("Context canceled, stopping sweeper")

			return ctx.Err()
		case <-done:
			s.logger.Info().Msg("Received done signal, stopping sweeper")

			return nil
		case <-s.tickerReset:
			s.mu.RLock()
			newInterval := s.config.Interval
			s.mu.RUnlock()
			s.logger.Info().Dur("newInterval", newInterval).Msg("Resetting sweep ticker due to interval change")
			ticker.Reset(newInterval)
		case t := <-ticker.C:
			s.logger.Debug().Time("tickTime", t).Msg("Ticker fired, starting periodic sweep")

			sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
			if err := s.runSweepWithLock(sweepCtx); err != nil {
				s.logger.Error().Err(err).Msg("Periodic sweep failed")
			} else {
				s.logger.Debug().Msg("Periodic sweep completed successfully")
			}

			sweepCancel()

		}
	}
}

// RunOnce triggers a single sweep cycle immediately.
func (s *NetworkSweeper) RunOnce(ctx context.Context) error {
	done := s.ensureControlChannels()

	select {
	case <-done:
		s.logger.Info().Msg("Sweep already stopped, skipping run-once")
		return nil
	default:
	}

	s.ensureScannersInitialized()

	sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
	defer sweepCancel()

	if err := s.runSweepWithLock(sweepCtx); err != nil {
		s.logger.Error().Err(err).Msg("Run-once sweep failed")
		return err
	}

	return nil
}

// Stop gracefully stops sweeping.
func (s *NetworkSweeper) Stop() error {
	s.logger.Info().Msg("Stopping network sweeper")

	var done chan struct{}
	alreadyStopped := false
	var icmpScanner scan.Scanner
	var tcpScanner scan.Scanner
	var tcpConnectScanner scan.Scanner

	s.mu.Lock()
	alreadyStopped = s.stopped
	s.stopped = true
	done = s.done
	icmpScanner = s.icmpScanner
	s.icmpScanner = nil
	tcpScanner = s.tcpScanner
	s.tcpScanner = nil
	tcpConnectScanner = s.tcpConnectScanner
	s.tcpConnectScanner = nil
	s.mu.Unlock()

	switch {
	case done == nil:
		s.logger.Debug().Msg("Sweep service already stopped")
	case alreadyStopped:
		s.logger.Debug().Msg("Sweep service already stopped")
	default:
		close(done)
	}

	if icmpScanner != nil {
		if err := icmpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop ICMP scanner")
		}
	}

	if tcpScanner != nil {
		if err := tcpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop TCP scanner")
		}
	}

	if tcpConnectScanner != nil {
		if err := tcpConnectScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop TCP connect scanner")
		}
	}

	return nil
}

func (s *NetworkSweeper) ensureControlChannels() chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.done == nil {
		s.done = make(chan struct{})
		if s.stopped {
			close(s.done)
		}
	}

	return s.done
}

func (s *NetworkSweeper) ensureScannersInitialized() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.icmpScanner == nil {
		s.icmpScanner = initializeICMPScanner(s.config, s.logger)
	}

	if s.tcpScanner == nil {
		s.tcpScanner = initializeTCPScanner(s.config, s.logger)
	}

	if s.tcpConnectScanner == nil {
		s.tcpConnectScanner = initializeTCPConnectScanner(s.config, s.logger)
	}
}

// GetStatus returns current sweep status.
func (s *NetworkSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	s.mu.RLock()
	inProgress := s.sweepInProgress
	cachedSummary := cloneSweepSummary(s.lastSummary)
	s.mu.RUnlock()

	if inProgress && cachedSummary != nil {
		return cachedSummary, nil
	}
	if inProgress {
		return &models.SweepSummary{LastSweep: 0}, nil
	}

	summary, err := s.store.GetSweepSummary(ctx)
	if err != nil {
		return nil, err
	}

	s.mu.RLock()
	lastSweep := s.lastSweep
	s.mu.RUnlock()

	if lastSweep.IsZero() {
		// The store summary is updated as individual scanner results arrive. Do not
		// expose that in-progress timestamp as a completed sweep marker, or the
		// agent push loop can stream partial ICMP/TCP snapshots as final results.
		summary.LastSweep = 0
	} else {
		summary.LastSweep = lastSweep.Unix()
	}

	return summary, nil
}

func cloneSweepSummary(summary *models.SweepSummary) *models.SweepSummary {
	if summary == nil {
		return nil
	}

	clone := *summary
	clone.Ports = append([]models.PortCount(nil), summary.Ports...)
	clone.Hosts = make([]models.HostResult, 0, len(summary.Hosts))

	for i := range summary.Hosts {
		clone.Hosts = append(clone.Hosts, models.DeepCopyHostResult(&summary.Hosts[i]))
	}

	return &clone
}

// GetResults retrieves sweep results based on filter.
func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	s.logger.Debug().Interface("filter", filter).Msg("Getting results with filter")

	return s.store.GetResults(ctx, filter)
}

// GetConfig returns current sweeper configuration.
func (s *NetworkSweeper) GetConfig() models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return *s.config
}

// GetScannerStats returns aggregated scanner statistics from the TCP scanner.
// Returns nil if the scanner doesn't support statistics.
func (s *NetworkSweeper) GetScannerStats() *models.ScannerStats {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Check if the TCP scanner supports stats (SYN scanner does)
	if statsProvider, ok := s.tcpScanner.(scan.StatsProvider); ok {
		scanStats := statsProvider.GetStats()
		addressFamily := scannerStatsAddressFamily(s.tcpScanner)
		scannerPath := scannerStatsPath(s.tcpScanner)

		// Calculate drop rate
		var rxDropRate float64
		if scanStats.PacketsRecv > 0 {
			rxDropRate = float64(scanStats.PacketsDropped) / float64(scanStats.PacketsRecv) * 100.0
		}

		return &models.ScannerStats{
			Protocol:             scannerProtocolTCP,
			AddressFamily:        addressFamily,
			ScannerPath:          scannerPath,
			PacketsSent:          scanStats.PacketsSent,
			PacketsRecv:          scanStats.PacketsRecv,
			PacketsDropped:       scanStats.PacketsDropped,
			RingBlocksProcessed:  scanStats.RingBlocksProcessed,
			RingBlocksDropped:    scanStats.RingBlocksDropped,
			RetriesAttempted:     scanStats.RetriesAttempted,
			RetriesSuccessful:    scanStats.RetriesSuccessful,
			RetriesDropped:       scanStats.RetriesDropped,
			PortsAllocated:       scanStats.PortsAllocated,
			PortsReleased:        scanStats.PortsReleased,
			PortExhaustionCount:  scanStats.PortExhaustion,
			RateLimitDeferrals:   scanStats.RateLimitDeferrals,
			RateLimitWaits:       scanStats.RateLimitWaits,
			SourcePortWaits:      scanStats.SourcePortWaits,
			RateLimitWaitTimeMs:  scanStats.RateLimitWaitNanos / uint64(time.Millisecond),
			SourcePortWaitTimeMs: scanStats.SourcePortWaitNanos / uint64(time.Millisecond),
			RxDropRatePercent:    rxDropRate,
			DialsStarted:         scanStats.DialsStarted,
			DialsSucceeded:       scanStats.DialsSucceeded,
			DialTimeouts:         scanStats.DialTimeouts,
			DialResets:           scanStats.DialResets,
			DialResourceErrors:   scanStats.DialResourceErrors,
			ActiveDials:          scanStats.ActiveDials,
			MaxActiveDials:       scanStats.MaxActiveDials,
			QueueDepth:           scanStats.QueueDepth,
			MaxQueueDepth:        scanStats.MaxQueueDepth,
		}
	}

	return nil
}

// scanAndProcess runs a scan and processes its results.
func (s *NetworkSweeper) scanAndProcess(ctx context.Context, wg *sync.WaitGroup,
	scanner scan.Scanner, targets []models.Target, scanType string) error {
	defer wg.Done()

	return s.scanAndProcessBatch(ctx, scanner, targets, scanType)
}

func (s *NetworkSweeper) scanAndProcessBatch(ctx context.Context, scanner scan.Scanner, targets []models.Target, scanType string) error {
	s.logger.Debug().Str("scanType", scanType).Msg("Running scan")

	results, err := scanner.Scan(ctx, targets)
	if err != nil {
		s.logger.Error().Err(err).Str("scanType", scanType).Msg("Scan failed")

		return err
	}

	return s.processResultsStream(ctx, results, scanType)
}

// processResultsStream processes results from a scanner stream with batching.
func (s *NetworkSweeper) processResultsStream(ctx context.Context, results <-chan models.Result, scanType string) error {
	count := 0
	success := 0

	// Batch processing configuration
	const batchSize = 1000

	resultBatch := make([]models.Result, 0, batchSize)

	// Process results as they arrive, respecting context timeout
	for {
		select {
		case result, ok := <-results:
			if !ok {
				return s.handleStreamComplete(ctx, resultBatch, scanType, count, success)
			}

			if err := s.submitBannerGrabCandidate(ctx, result); err != nil {
				return err
			}

			count, success = s.processSingleResult(&result, &resultBatch, count, success)
			if err := s.processBatchIfFull(ctx, &resultBatch, scanType, count, success); err != nil {
				return err
			}

		case <-ctx.Done():
			return s.handleContextDone(ctx, resultBatch, scanType, count, success)
		}
	}
}

type activeBannerGrabPhase struct {
	engine *banner_grab.Engine
	done   <-chan error
}

func (s *NetworkSweeper) startBannerGrabPhase(ctx context.Context) *activeBannerGrabPhase {
	if !s.config.BannerGrab.Enabled {
		return nil
	}

	engine := banner_grab.New(banner_grab.ConfigFromModel(s.config.BannerGrab))
	observations := engine.Start(ctx)

	handler := s.bannerHandler
	if handler == nil {
		handler = s.drainBannerGrabObservations
	}

	done := make(chan error, 1)
	go func() {
		done <- handler(ctx, s.config.BannerGrab, engine, observations)
	}()

	s.bannerMu.Lock()
	s.bannerPhase = engine
	s.lastBannerStats = nil
	s.bannerMu.Unlock()

	s.logger.Info().
		Strs("protocols", s.config.BannerGrab.Protocols).
		Int("maxGlobalConcurrency", s.config.BannerGrab.MaxGlobalConcurrency).
		Int("maxCandidateQueue", s.config.BannerGrab.MaxCandidateQueue).
		Msg("Started banner-grab phase")

	return &activeBannerGrabPhase{
		engine: engine,
		done:   done,
	}
}

func (s *NetworkSweeper) finishBannerGrabPhase(phase *activeBannerGrabPhase) error {
	if phase == nil {
		return nil
	}

	phase.engine.Stop()
	err := <-phase.done
	stats := phase.engine.Stats()

	s.bannerMu.Lock()
	if s.bannerPhase == phase.engine {
		s.bannerPhase = nil
	}
	s.lastBannerStats = bannerGrabStatsFromEngine(stats)
	s.bannerMu.Unlock()

	s.logger.Info().
		Uint64("candidates", stats.CandidatesTotal).
		Uint64("probes", stats.ProbesTotal).
		Uint64("observations", stats.ObservationsTotal).
		Uint64("bytesReceived", stats.BannerBytesTotal).
		Uint64("timeouts", stats.TimeoutTotal).
		Uint64("connectionResets", stats.ConnectionResetTotal).
		Uint64("emptyResponses", stats.EmptyResponseTotal).
		Uint64("errors", stats.ErrorsTotal).
		Uint64("maxQueueDepth", stats.MaxQueueDepth).
		Msg("Finished banner-grab phase")

	return err
}

func (s *NetworkSweeper) abortBannerGrabPhase(phase *activeBannerGrabPhase) {
	if phase == nil {
		return
	}

	phase.engine.Stop()
	<-phase.done

	s.bannerMu.Lock()
	if s.bannerPhase == phase.engine {
		s.bannerPhase = nil
	}
	s.bannerMu.Unlock()
}

func (s *NetworkSweeper) GetBannerGrabStats() *models.BannerGrabStats {
	s.bannerMu.RLock()
	engine := s.bannerPhase
	lastStats := s.lastBannerStats
	s.bannerMu.RUnlock()

	if engine != nil {
		return bannerGrabStatsFromEngine(engine.Stats())
	}
	if lastStats == nil {
		return nil
	}

	stats := *lastStats
	return &stats
}

func (s *NetworkSweeper) submitBannerGrabCandidate(ctx context.Context, result models.Result) error {
	s.bannerMu.RLock()
	engine := s.bannerPhase
	s.bannerMu.RUnlock()

	if engine == nil {
		return nil
	}

	return engine.SubmitResult(ctx, result)
}

func (s *NetworkSweeper) drainBannerGrabObservations(
	ctx context.Context,
	_ models.BannerGrab,
	_ *banner_grab.Engine,
	observations <-chan banner_grab.BannerObservation,
) error {
	count := 0

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case _, ok := <-observations:
			if !ok {
				if count > 0 {
					s.logger.Debug().Int("observations", count).Msg("Drained banner-grab observations without netprobe handler")
				}

				return nil
			}

			count++
		}
	}
}

func bannerGrabStatsFromEngine(stats banner_grab.Stats) *models.BannerGrabStats {
	return &models.BannerGrabStats{
		CandidatesTotal:      stats.CandidatesTotal,
		ProbesTotal:          stats.ProbesTotal,
		InFlight:             stats.InFlight,
		QueueDepth:           stats.QueueDepth,
		MatchBatchesTotal:    stats.MatchBatchesTotal,
		MatchBatchBytesTotal: stats.MatchBatchBytesTotal,
		BannerBytesTotal:     stats.BannerBytesTotal,
		SkippedFreshTotal:    stats.SkippedFreshTotal,
		SkippedBackoffTotal:  stats.SkippedBackoffTotal,
		MatchesTotal:         stats.MatchesTotal,
		EmptyResponseTotal:   stats.EmptyResponseTotal,
		ConnectionResetTotal: stats.ConnectionResetTotal,
		TimeoutTotal:         stats.TimeoutTotal,
		ErrorsTotal:          stats.ErrorsTotal,
	}
}

// handleStreamComplete handles completion when the results channel is closed.
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

func (s *NetworkSweeper) runBatchedSweep(ctx context.Context, targetEstimate int) error {
	s.mu.RLock()
	icmpScanner := s.icmpScanner
	tcpScanner := s.tcpScanner
	tcpConnectScanner := s.tcpConnectScanner
	s.mu.RUnlock()
	icmpCaps := scannerCapabilities(icmpScanner)
	tcpCaps := scannerCapabilities(tcpScanner)
	tcpConnectCaps := scannerCapabilities(tcpConnectScanner)

	s.resultsMu.Lock()
	s.deviceResults = make(map[string]*DeviceResultAggregator)
	s.resultsMu.Unlock()

	bannerPhase := s.startBannerGrabPhase(ctx)
	finishedBannerPhase := false
	defer func() {
		if !finishedBannerPhase {
			s.abortBannerGrabPhase(bannerPhase)
		}
	}()

	runner := &sweepBatchRunner{
		sweeper:           s,
		ctx:               ctx,
		icmpScanner:       icmpScanner,
		tcpScanner:        tcpScanner,
		tcpConnectScanner: tcpConnectScanner,
		icmpTargets:       make([]models.Target, 0, defaultTargetBatch),
		tcpTargets:        make([]models.Target, 0, defaultTargetBatch),
		tcpConnectTargets: make([]models.Target, 0, defaultTargetBatch),
	}

	if tcpStream, ok, err := s.startStreamingScan(ctx, tcpScanner, scannerProtocolTCP, targetEstimate); err != nil {
		return err
	} else if ok {
		runner.tcpStream = tcpStream
	}

	if tcpConnectStream, ok, err := s.startStreamingScan(ctx, tcpConnectScanner, "tcp_connect", targetEstimate); err != nil {
		return err
	} else if ok {
		runner.tcpConnectStream = tcpConnectStream
	}

	s.logger.Info().
		Int("estimatedTargets", targetEstimate).
		Int("batchSize", defaultTargetBatch).
		Bool("tcpStreaming", runner.tcpStream != nil).
		Bool("tcpConnectStreaming", runner.tcpConnectStream != nil).
		Bool("icmpScannerAvailable", icmpScanner != nil).
		Bool("tcpScannerAvailable", tcpScanner != nil).
		Bool("tcpConnectScannerAvailable", tcpConnectScanner != nil).
		Bool("icmpIPv4Available", icmpCaps.ICMPv4).
		Bool("icmpIPv6Available", icmpCaps.ICMPv6).
		Bool("tcpRawSYNIPv4Available", tcpCaps.RawSYNIPv4).
		Bool("tcpRawSYNIPv6Available", tcpCaps.RawSYNIPv6).
		Bool("tcpConnectIPv4Available", tcpConnectCaps.TCPConnectIPv4).
		Bool("tcpConnectIPv6Available", tcpConnectCaps.TCPConnectIPv6).
		Msg("Starting batched sweep")

	if err := s.generateTargetsBatched(runner.addTarget); err != nil {
		runner.closeStreams()
		return fmt.Errorf("failed to generate batched targets: %w", err)
	}

	if err := runner.flushAll(); err != nil {
		return err
	}

	err := s.finishBannerGrabPhase(bannerPhase)
	finishedBannerPhase = true
	if err != nil {
		return err
	}

	s.finalizeDeviceAggregators(ctx)

	s.logger.Info().
		Int("estimatedTargets", targetEstimate).
		Int("icmpTargets", runner.icmpCount).
		Int("tcpTargets", runner.tcpCount).
		Int("tcpConnectTargets", runner.tcpConnectCount).
		Int("ipv4Targets", runner.ipv4Count).
		Int("ipv6Targets", runner.ipv6Count).
		Int("ipv6TCPConnectFallbackTargets", runner.ipv6TCPConnectFallbackCount).
		Msg("Batched sweep completed successfully")

	return nil
}

type sweepTargetStream struct {
	ctx         context.Context
	targets     chan models.Target
	scanErrs    <-chan error
	processDone <-chan error
	closeOnce   sync.Once
}

func (h *sweepTargetStream) add(target models.Target) error {
	select {
	case h.targets <- target:
		return nil
	case <-h.ctx.Done():
		return h.ctx.Err()
	}
}

func (h *sweepTargetStream) closeAndWait() error {
	h.closeOnce.Do(func() {
		close(h.targets)
	})

	var firstErr error

	if err := <-h.processDone; err != nil {
		firstErr = err
	}

	for err := range h.scanErrs {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	return firstErr
}

func (h *sweepTargetStream) closeOnly() {
	h.closeOnce.Do(func() {
		close(h.targets)
	})
}

func (s *NetworkSweeper) startStreamingScan(
	ctx context.Context,
	scanner scan.Scanner,
	scanType string,
	targetEstimate int,
) (*sweepTargetStream, bool, error) {
	streamingScanner, ok := scanner.(scan.StreamingScanner)
	if !ok {
		return nil, false, nil
	}

	targetCh := make(chan models.Target, defaultTargetBatch)
	results, scanErrs, err := streamingScanner.ScanStream(ctx, targetCh, scan.StreamOptions{
		TargetEstimate: targetEstimate,
		BatchSize:      defaultTargetBatch,
	})
	if err != nil {
		close(targetCh)

		return nil, false, err
	}

	processDone := make(chan error, 1)
	go func() {
		processDone <- s.processResultsStream(ctx, results, scanType)
	}()

	return &sweepTargetStream{
		ctx:         ctx,
		targets:     targetCh,
		scanErrs:    scanErrs,
		processDone: processDone,
	}, true, nil
}

type sweepBatchRunner struct {
	sweeper                     *NetworkSweeper
	ctx                         context.Context
	icmpScanner                 scan.Scanner
	tcpScanner                  scan.Scanner
	tcpConnectScanner           scan.Scanner
	tcpStream                   *sweepTargetStream
	tcpConnectStream            *sweepTargetStream
	icmpTargets                 []models.Target
	tcpTargets                  []models.Target
	tcpConnectTargets           []models.Target
	icmpCount                   int
	tcpCount                    int
	tcpConnectCount             int
	ipv4Count                   int
	ipv6Count                   int
	ipv6TCPConnectFallbackCount int
}

func (r *sweepBatchRunner) addTarget(target models.Target) error {
	r.recordRoute(target)

	switch target.Mode {
	case models.ModeICMP:
		r.icmpTargets = append(r.icmpTargets, target)
		r.icmpCount++
		if len(r.icmpTargets) >= defaultTargetBatch {
			if err := r.flushMode("icmp", r.icmpScanner, &r.icmpTargets); err != nil {
				return err
			}
		}
	case models.ModeTCP:
		if r.tcpStream != nil {
			r.tcpCount++

			return r.tcpStream.add(target)
		}

		r.tcpTargets = append(r.tcpTargets, target)
		r.tcpCount++
		if len(r.tcpTargets) >= defaultTargetBatch {
			if err := r.flushMode(scannerProtocolTCP, r.tcpScanner, &r.tcpTargets); err != nil {
				return err
			}
		}
	case models.ModeTCPConnect:
		if r.tcpConnectStream != nil {
			r.tcpConnectCount++

			return r.tcpConnectStream.add(target)
		}

		r.tcpConnectTargets = append(r.tcpConnectTargets, target)
		r.tcpConnectCount++
		if len(r.tcpConnectTargets) >= defaultTargetBatch {
			if err := r.flushMode("tcp_connect", r.tcpConnectScanner, &r.tcpConnectTargets); err != nil {
				return err
			}
		}
	}

	return nil
}

func (r *sweepBatchRunner) recordRoute(target models.Target) {
	if target.Metadata == nil {
		return
	}

	switch target.Metadata[metadataAddressFamily] {
	case addressFamilyIPv4:
		r.ipv4Count++
	case addressFamilyIPv6:
		r.ipv6Count++
	}

	if fallback, ok := target.Metadata[metadataIPv6RawSYNFallback].(bool); ok && fallback {
		r.ipv6TCPConnectFallbackCount++
	}
}

func (r *sweepBatchRunner) flushAll() error {
	if err := r.flushMode("icmp", r.icmpScanner, &r.icmpTargets); err != nil {
		return err
	}

	if err := r.flushMode(scannerProtocolTCP, r.tcpScanner, &r.tcpTargets); err != nil {
		return err
	}

	if err := r.flushMode("tcp_connect", r.tcpConnectScanner, &r.tcpConnectTargets); err != nil {
		return err
	}

	if r.tcpStream != nil {
		if err := r.tcpStream.closeAndWait(); err != nil {
			return err
		}
	}

	if r.tcpConnectStream != nil {
		return r.tcpConnectStream.closeAndWait()
	}

	return nil
}

func (r *sweepBatchRunner) closeStreams() {
	if r.tcpStream != nil {
		r.tcpStream.closeOnly()
	}

	if r.tcpConnectStream != nil {
		r.tcpConnectStream.closeOnly()
	}
}

func (r *sweepBatchRunner) flushMode(scanType string, scanner scan.Scanner, targets *[]models.Target) error {
	if len(*targets) == 0 {
		return nil
	}

	if scanner == nil {
		r.sweeper.logger.Warn().
			Str("scanType", scanType).
			Int("targets", len(*targets)).
			Msg("Targets found but scanner is not available, skipping scan batch")
		*targets = (*targets)[:0]

		return nil
	}

	batch := *targets
	*targets = (*targets)[:0]

	return r.sweeper.scanAndProcessBatch(r.ctx, scanner, batch, scanType)
}

// processResult processes a single scan result.
func (s *NetworkSweeper) processResult(ctx context.Context, result *models.Result) error {
	ctx, cancel := context.WithTimeout(ctx, defaultResultTimeout)
	defer cancel()

	// Process basic result handling
	if err := s.processBasicResult(ctx, result); err != nil {
		return err
	}

	// Check if this result should be aggregated for a multi-IP device
	if s.shouldAggregateResult(result) {
		s.addResultToAggregator(result)
		return nil // Don't process immediately through device registry
	}

	// Process through unified device registry for all results (both available and unavailable)
	if s.deviceRegistry != nil {
		if err := s.processDeviceRegistry(result); err != nil {
			// Log error but don't fail the entire operation
			s.logger.Error().Err(err).Str("host", result.Target.Host).Msg("Failed to process sweep result through device registry")
		}
	}

	return nil
}

// processBasicResult handles the basic processing and saving of the result.
func (s *NetworkSweeper) processBasicResult(ctx context.Context, result *models.Result) error {
	// Process through existing pipeline
	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("processor error: %w", err)
	}

	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("store error: %w", err)
	}

	return nil
}

const (
	defaultName = "default"
)

// extractAgentInfo extracts agent/gateway/partition information from config and metadata.
func (s *NetworkSweeper) extractAgentInfo(result *models.Result) (agentID, gatewayID, partition string) {
	// Get agent/gateway info from config first, then try metadata
	agentID = defaultName
	gatewayID = defaultName
	partition = defaultName

	// Use config values if available
	if s.config.AgentID != "" {
		agentID = s.config.AgentID
	}

	if s.config.GatewayID != "" {
		gatewayID = s.config.GatewayID
	}

	if s.config.Partition != "" {
		partition = s.config.Partition
	}

	// Extract from metadata if available (metadata can override config)
	if result.Target.Metadata != nil {
		if id, ok := result.Target.Metadata["agent_id"].(string); ok && id != "" {
			agentID = id
		}

		if id, ok := result.Target.Metadata["gateway_id"].(string); ok && id != "" {
			gatewayID = id
		}

		if p, ok := result.Target.Metadata["partition"].(string); ok && p != "" {
			partition = p
		}
	}

	return agentID, gatewayID, partition
}

// createDeviceUpdate creates a DeviceUpdate from a Result.
func (*NetworkSweeper) createDeviceUpdate(result *models.Result, agentID, gatewayID, partition string) *models.DeviceUpdate {
	// Always generate a valid device ID with partition
	deviceID := fmt.Sprintf("%s:%s", partition, result.Target.Host)

	return &models.DeviceUpdate{
		AgentID:     agentID,
		GatewayID:   gatewayID,
		Partition:   partition,
		DeviceID:    deviceID,
		Source:      models.DiscoverySourceSweep,
		IP:          result.Target.Host,
		Timestamp:   result.LastSeen,
		IsAvailable: result.Available,
		Metadata:    make(map[string]string),
		Confidence:  models.GetSourceConfidence(models.DiscoverySourceSweep),
	}
}

// convertMetadataToStringMap converts metadata to a string map.
func convertMetadataToStringMap(deviceUpdate *models.DeviceUpdate, metadata map[string]interface{}) {
	if metadata == nil {
		return
	}

	for key, value := range metadata {
		if strVal, ok := value.(string); ok {
			deviceUpdate.Metadata[key] = strVal
		} else {
			deviceUpdate.Metadata[key] = fmt.Sprintf("%v", value)
		}
	}
}

// addAdditionalMetadata adds additional metadata to the DeviceUpdate.
func addAdditionalMetadata(deviceUpdate *models.DeviceUpdate, result *models.Result) {
	// Add sweep mode to metadata
	deviceUpdate.Metadata["sweep_mode"] = string(result.Target.Mode)
	if result.Target.Port > 0 {
		deviceUpdate.Metadata["port"] = fmt.Sprintf("%d", result.Target.Port)
	}

	// Add timing metadata
	deviceUpdate.Metadata["response_time"] = result.RespTime.String()
	deviceUpdate.Metadata["packet_loss"] = fmt.Sprintf("%.2f", result.PacketLoss)
}

// processDeviceRegistry processes the sweep result through the device registry.
func (s *NetworkSweeper) processDeviceRegistry(result *models.Result) error {
	agentID, gatewayID, partition := s.extractAgentInfo(result)
	deviceUpdate := s.createDeviceUpdate(result, agentID, gatewayID, partition)

	// Convert metadata to string map
	convertMetadataToStringMap(deviceUpdate, result.Target.Metadata)

	// Add additional metadata
	addAdditionalMetadata(deviceUpdate, result)

	// Use background context to avoid cancellation
	bgCtx := context.Background()

	return s.deviceRegistry.UpdateDevice(bgCtx, deviceUpdate)
}

// generateTargetsForNetwork creates targets for a legacy network configuration
func (s *NetworkSweeper) generateTargetsForNetwork(network string) ([]models.Target, int, error) {
	_, supported, err := s.effectiveSweepModesForCIDR(network, s.config.SweepModes)
	if err != nil {
		return nil, 0, err
	}
	if !supported {
		return nil, 0, nil
	}

	hostCount, err := countCIDRHosts(network)
	if err != nil {
		return nil, 0, err
	}
	if err := validateCIDRExpansion(network, hostCount); err != nil {
		return nil, 0, err
	}

	ips, err := scan.ExpandCIDR(network)
	if err != nil {
		return nil, 0, fmt.Errorf("failed to expand CIDR %s: %w", network, err)
	}

	var targets []models.Target

	metadata := map[string]interface{}{
		"network":     network,
		"total_hosts": len(ips),
		"source":      "legacy_networks",
	}

	for _, ip := range ips {
		targets = append(targets, s.createTargetsForIP(ip, s.config.SweepModes, metadata)...)
	}

	return targets, len(ips), nil
}

// generateTargetsForDeviceTarget creates targets for a device target configuration
func (s *NetworkSweeper) generateTargetsForDeviceTarget(deviceTarget *models.DeviceTarget) (targets []models.Target, hostCount int) {
	// Use device-specific sweep modes if available, otherwise fall back to global
	sweepModes := deviceTarget.SweepModes
	if len(sweepModes) == 0 {
		s.logger.Debug().
			Str("device", deviceTarget.Network).
			Msg("Device target has no sweep modes, using global config")

		sweepModes = s.config.SweepModes
	}

	effectiveModes, supported, err := s.effectiveSweepModesForCIDR(deviceTarget.Network, sweepModes)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to classify device target IP family, skipping")

		return targets, hostCount
	}
	if !supported {
		return targets, hostCount
	}

	estimatedHostCount, err := countCIDRHosts(deviceTarget.Network)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to count device target CIDR, skipping")

		return targets, hostCount
	}
	if err := validateCIDRExpansion(deviceTarget.Network, estimatedHostCount); err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Device target CIDR is too broad for sweep expansion, skipping")

		return targets, hostCount
	}

	// Always expand and use the primary network (e.g., a single /32).
	// We intentionally ignore any additional IP lists in metadata (e.g., "all_ips").
	ips, err := scan.ExpandCIDR(deviceTarget.Network)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("network", deviceTarget.Network).
			Str("query_label", deviceTarget.QueryLabel).
			Msg("Failed to expand device target CIDR, skipping")

		return targets, hostCount
	}

	targetIPs := ips

	metadata := map[string]interface{}{
		"network":     deviceTarget.Network,
		"total_hosts": len(targetIPs),
		"source":      deviceTarget.Source,
		"query_label": deviceTarget.QueryLabel,
	}

	// Add device target metadata to the scan metadata (for tracking only)
	for k, v := range deviceTarget.Metadata {
		metadata[k] = v
	}

	s.logger.Debug().
		Str("device", deviceTarget.Network).
		Strs("sweep_modes", func() []string {
			modes := make([]string, 0, len(effectiveModes))
			for _, m := range effectiveModes {
				modes = append(modes, string(m))
			}
			return modes
		}()).
		Int("ip_count", len(targetIPs)).
		Int("port_count", len(s.config.Ports)).
		Msg("Generating targets for device")

	for _, ip := range targetIPs {
		targets = append(targets, s.createTargetsForIP(ip, sweepModes, metadata)...)
	}

	hostCount = len(targetIPs)

	return targets, hostCount
}

func (s *NetworkSweeper) generateTargetsBatched(consume func(models.Target) error) error {
	totalHostCount := 0

	for _, network := range s.config.Networks {
		_, supported, err := s.effectiveSweepModesForCIDR(network, s.config.SweepModes)
		if err != nil {
			return fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}
		if !supported {
			continue
		}

		hostCount, err := countCIDRHosts(network)
		if err != nil {
			return fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}
		if err := validateCIDRExpansion(network, hostCount); err != nil {
			return err
		}

		metadata := map[string]interface{}{
			"network":     network,
			"total_hosts": hostCount,
			"source":      "legacy_networks",
		}

		visited, err := forEachCIDRHost(network, func(ip string) error {
			return s.emitTargetsForIP(ip, s.config.SweepModes, metadata, consume)
		})
		if err != nil {
			return fmt.Errorf("failed to generate targets for CIDR %s: %w", network, err)
		}

		totalHostCount += visited
	}

	for _, deviceTarget := range s.config.DeviceTargets {
		hostCount, err := countCIDRHosts(deviceTarget.Network)
		if err != nil {
			s.logger.Warn().
				Err(err).
				Str("network", deviceTarget.Network).
				Str("query_label", deviceTarget.QueryLabel).
				Msg("Failed to parse device target CIDR, skipping")

			continue
		}

		metadata := map[string]interface{}{
			"network":     deviceTarget.Network,
			"total_hosts": hostCount,
			"source":      deviceTarget.Source,
			"query_label": deviceTarget.QueryLabel,
		}

		for k, v := range deviceTarget.Metadata {
			metadata[k] = v
		}

		sweepModes := deviceTarget.SweepModes
		if len(sweepModes) == 0 {
			s.logger.Debug().
				Str("device", deviceTarget.Network).
				Msg("Device target has no sweep modes, using global config")

			sweepModes = s.config.SweepModes
		}

		_, supported, err := s.effectiveSweepModesForCIDR(deviceTarget.Network, sweepModes)
		if err != nil {
			return fmt.Errorf("failed to parse device CIDR %s: %w", deviceTarget.Network, err)
		}
		if !supported {
			continue
		}
		if err := validateCIDRExpansion(deviceTarget.Network, hostCount); err != nil {
			return err
		}

		visited, err := forEachCIDRHost(deviceTarget.Network, func(ip string) error {
			return s.emitTargetsForIP(ip, sweepModes, metadata, consume)
		})
		if err != nil {
			return fmt.Errorf("failed to generate targets for device CIDR %s: %w", deviceTarget.Network, err)
		}

		totalHostCount += visited
	}

	s.logger.Info().
		Int("networkCount", len(s.config.Networks)).
		Int("deviceTargetCount", len(s.config.DeviceTargets)).
		Int("totalHosts", totalHostCount).
		Ints("configuredPorts", s.config.Ports).
		Strs("globalSweepModes", func() []string {
			modes := make([]string, 0, len(s.config.SweepModes))
			for _, m := range s.config.SweepModes {
				modes = append(modes, string(m))
			}
			return modes
		}()).
		Msg("Generated batched targets from networks and device targets")

	return nil
}

func forEachCIDRHost(cidr string, fn func(string) error) (int, error) {
	baseIP, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return 0, err
	}

	ones, _ := ipNet.Mask.Size()
	currentIP := append(net.IP(nil), baseIP.Mask(ipNet.Mask)...)
	count := 0

	for ; ipNet.Contains(currentIP); incCIDRIP(currentIP) {
		if currentIP.To4() != nil && ones != 32 {
			if currentIP.Equal(ipNet.IP) || isCIDRBroadcast(currentIP, ipNet) {
				continue
			}
		}

		if err := fn(currentIP.String()); err != nil {
			return count, err
		}

		count++
	}

	return count, nil
}

func incCIDRIP(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
}

func isCIDRBroadcast(ip net.IP, ipNet *net.IPNet) bool {
	broadcast := make(net.IP, len(ip))
	for i := range ip {
		broadcast[i] = ipNet.IP[i] | ^ipNet.Mask[i]
	}

	return ip.Equal(broadcast)
}

// createTargetsForIP creates targets for a specific IP using the given sweep modes
func (s *NetworkSweeper) createTargetsForIP(ip string, sweepModes []models.SweepMode, metadata map[string]interface{}) []models.Target {
	var targets []models.Target

	_ = s.emitTargetsForIP(ip, sweepModes, metadata, func(target models.Target) error {
		targets = append(targets, target)
		return nil
	})

	return targets
}

func (s *NetworkSweeper) emitTargetsForIP(
	ip string,
	sweepModes []models.SweepMode,
	metadata map[string]interface{},
	emit func(models.Target) error,
) error {
	requestedModes := sweepModes
	rawSYNIPv6Available := s.rawSYNIPv6Available()
	effectiveModes := effectiveSweepModesForIPWithRawSYN(ip, requestedModes, rawSYNIPv6Available)

	if containsMode(effectiveModes, models.ModeICMP) {
		target := scan.TargetFromIP(ip, models.ModeICMP)
		target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeICMP, rawSYNIPv6Available)
		if err := emit(target); err != nil {
			return err
		}
	}

	if containsMode(effectiveModes, models.ModeTCP) {
		for _, port := range s.config.Ports {
			target := scan.TargetFromIP(ip, models.ModeTCP, port)
			target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeTCP, rawSYNIPv6Available)
			if err := emit(target); err != nil {
				return err
			}
		}
	}

	if containsMode(effectiveModes, models.ModeTCPConnect) {
		for _, port := range s.config.Ports {
			target := scan.TargetFromIP(ip, models.ModeTCPConnect, port)
			target.Metadata = metadataForTarget(metadata, ip, requestedModes, models.ModeTCPConnect, rawSYNIPv6Available)
			if err := emit(target); err != nil {
				return err
			}
		}
	}

	return nil
}

func metadataForTarget(
	base map[string]interface{},
	ip string,
	requestedModes []models.SweepMode,
	effectiveMode models.SweepMode,
	rawSYNIPv6Available bool,
) map[string]interface{} {
	metadata := make(map[string]interface{}, len(base)+6)
	for key, value := range base {
		metadata[key] = value
	}

	addressFamily := addressFamilyIPv4
	if isIPv6String(ip) {
		addressFamily = addressFamilyIPv6
	}

	requestedMode := effectiveMode
	ipv6TCPFallback := false

	if addressFamily == addressFamilyIPv6 &&
		effectiveMode == models.ModeTCPConnect &&
		containsMode(requestedModes, models.ModeTCP) &&
		(!rawSYNIPv6Available || !containsMode(requestedModes, models.ModeTCPConnect)) {
		requestedMode = models.ModeTCP
		ipv6TCPFallback = true
	}

	scannerPath := string(effectiveMode)
	if ipv6TCPFallback {
		scannerPath = scannerPathTCPConnectIPv6SYN
	}

	metadata[metadataAddressFamily] = addressFamily
	metadata["requested_sweep_modes"] = sweepModeStrings(requestedModes)
	metadata["requested_sweep_mode"] = string(requestedMode)
	metadata["effective_sweep_mode"] = string(effectiveMode)
	metadata["scanner_path"] = scannerPath
	metadata[metadataIPv6RawSYNFallback] = ipv6TCPFallback

	return metadata
}

func sweepModeStrings(modes []models.SweepMode) []string {
	strings := make([]string, 0, len(modes))
	for _, mode := range modes {
		strings = append(strings, string(mode))
	}

	return strings
}

func isIPv6String(ip string) bool {
	parsed := net.ParseIP(ip)
	return parsed != nil && parsed.To4() == nil
}

type targetRouteSummary struct {
	ipv4Targets                   int
	ipv6Targets                   int
	ipv6TCPConnectFallbackTargets int
}

func summarizeTargetRoutes(targets []models.Target) targetRouteSummary {
	var summary targetRouteSummary

	for _, target := range targets {
		if target.Metadata == nil {
			continue
		}

		switch target.Metadata[metadataAddressFamily] {
		case addressFamilyIPv4:
			summary.ipv4Targets++
		case addressFamilyIPv6:
			summary.ipv6Targets++
		}

		if fallback, ok := target.Metadata[metadataIPv6RawSYNFallback].(bool); ok && fallback {
			summary.ipv6TCPConnectFallbackTargets++
		}
	}

	return summary
}

func scannerCapabilities(scanner scan.Scanner) scan.ScannerCapabilities {
	if provider, ok := scanner.(scan.CapabilityProvider); ok {
		return provider.Capabilities()
	}

	return scan.ScannerCapabilities{}
}

func scannerStatsAddressFamily(scanner scan.Scanner) string {
	caps := scannerCapabilities(scanner)

	if caps.RawSYNIPv4 || caps.RawSYNIPv6 {
		switch {
		case caps.RawSYNIPv4 && caps.RawSYNIPv6:
			return addressFamilyDualStack
		case caps.RawSYNIPv6:
			return addressFamilyIPv6
		default:
			return addressFamilyIPv4
		}
	}

	if caps.TCPConnectIPv4 || caps.TCPConnectIPv6 {
		switch {
		case caps.TCPConnectIPv4 && caps.TCPConnectIPv6:
			return addressFamilyDualStack
		case caps.TCPConnectIPv6:
			return addressFamilyIPv6
		default:
			return addressFamilyIPv4
		}
	}

	return addressFamilyUnknown
}

func scannerStatsPath(scanner scan.Scanner) string {
	caps := scannerCapabilities(scanner)
	if caps.RawSYNIPv4 || caps.RawSYNIPv6 {
		return scannerPathRawSYN
	}
	if caps.TCPConnectIPv4 || caps.TCPConnectIPv6 {
		return scannerPathTCPConnect
	}

	return addressFamilyUnknown
}

func (s *NetworkSweeper) rawSYNIPv6Available() bool {
	return scannerCapabilities(s.tcpScanner).RawSYNIPv6
}

func (s *NetworkSweeper) effectiveSweepModesForCIDR(cidr string, sweepModes []models.SweepMode) ([]models.SweepMode, bool, error) {
	baseIP, _, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, false, err
	}

	modes := effectiveSweepModes(baseIP.To4() == nil, sweepModes, s.rawSYNIPv6Available())

	return modes, len(modes) > 0, nil
}

func effectiveSweepModesForIPWithRawSYN(ip string, sweepModes []models.SweepMode, rawSYNIPv6Available bool) []models.SweepMode {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return sweepModes
	}

	return effectiveSweepModes(parsed.To4() == nil, sweepModes, rawSYNIPv6Available)
}

func effectiveSweepModes(ipv6 bool, sweepModes []models.SweepMode, rawSYNIPv6Available bool) []models.SweepMode {
	if !ipv6 {
		return sweepModes
	}

	modes := make([]models.SweepMode, 0, len(sweepModes))
	if containsMode(sweepModes, models.ModeICMP) {
		modes = append(modes, models.ModeICMP)
	}

	if rawSYNIPv6Available && containsMode(sweepModes, models.ModeTCP) {
		modes = append(modes, models.ModeTCP)
	}

	if containsMode(sweepModes, models.ModeTCPConnect) || (!rawSYNIPv6Available && containsMode(sweepModes, models.ModeTCP)) {
		modes = append(modes, models.ModeTCPConnect)
	}

	return modes
}

func validateCIDRExpansion(cidr string, hostCount int) error {
	baseIP, _, err := net.ParseCIDR(cidr)
	if err != nil {
		return err
	}

	if baseIP.To4() == nil && hostCount > defaultTargetBatch {
		return fmt.Errorf("%w: %s expands to %d hosts, above limit %d", errIPv6CIDRTooLarge, cidr, hostCount, defaultTargetBatch)
	}

	return nil
}

// generateTargets creates scan targets from the configuration.
func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	var targets []models.Target

	totalHostCount := 0

	// Process legacy networks with global sweep modes (for backward compatibility)
	for _, network := range s.config.Networks {
		networkTargets, hostCount, err := s.generateTargetsForNetwork(network)
		if err != nil {
			return nil, err
		}

		targets = append(targets, networkTargets...)
		totalHostCount += hostCount
	}

	// Process device targets with per-device sweep modes (from sync service)
	for _, deviceTarget := range s.config.DeviceTargets {
		deviceTargets, hostCount := s.generateTargetsForDeviceTarget(&deviceTarget)

		targets = append(targets, deviceTargets...)
		totalHostCount += hostCount
	}

	s.logger.Info().
		Int("targetsGenerated", len(targets)).
		Int("networkCount", len(s.config.Networks)).
		Int("deviceTargetCount", len(s.config.DeviceTargets)).
		Int("totalHosts", totalHostCount).
		Ints("configuredPorts", s.config.Ports).
		Strs("globalSweepModes", func() []string {
			modes := make([]string, 0, len(s.config.SweepModes))
			for _, m := range s.config.SweepModes {
				modes = append(modes, string(m))
			}
			return modes
		}()).
		Msg("Generated targets from networks and device targets")

	return targets, nil
}

// containsMode checks if a mode is in a slice of modes.
func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}

// processBatchedResults processes a batch of results efficiently
func (s *NetworkSweeper) processBatchedResults(ctx context.Context, batch []models.Result) error {
	if len(batch) == 0 {
		return nil
	}

	// Pre-allocate context with timeout for the entire batch
	batchCtx, cancel := context.WithTimeout(ctx, time.Duration(len(batch))*defaultResultTimeout)
	defer cancel()

	// Track batch statistics
	errors := 0
	aggregated := 0
	deviceRegistryUpdates := 0

	// Process each result in the batch
	for i := range batch {
		result := &batch[i]

		// Process basic result handling (store, processor)
		if err := s.processBasicResult(batchCtx, result); err != nil {
			s.logger.Error().Err(err).
				Str("host", result.Target.Host).
				Msg("Failed to process basic result in batch")

			errors++

			continue
		}

		// Check if this result should be aggregated for a multi-IP device
		if s.shouldAggregateResult(result) {
			s.addResultToAggregator(result)

			aggregated++

			continue // Don't process immediately through device registry
		}

		// Process through unified device registry for non-aggregated results
		if s.deviceRegistry != nil {
			if err := s.processDeviceRegistry(result); err != nil {
				s.logger.Error().Err(err).
					Str("host", result.Target.Host).
					Msg("Failed to process result through device registry in batch")

				errors++

				continue
			}

			deviceRegistryUpdates++
		}
	}

	// Log only on errors to reduce log volume at scale
	if errors > 0 {
		s.logger.Warn().
			Int("batchSize", len(batch)).
			Int("errors", errors).
			Int("aggregated", aggregated).
			Int("deviceRegistryUpdates", deviceRegistryUpdates).
			Msg("Batch result processing completed with errors")
	}

	return nil
}

// prepareDeviceAggregators initializes result aggregators for devices with multiple IPs
func (s *NetworkSweeper) prepareDeviceAggregators(targets []models.Target) {
	s.resultsMu.Lock()
	defer s.resultsMu.Unlock()

	// Clear previous aggregators
	s.deviceResults = make(map[string]*DeviceResultAggregator)

	// Group targets by device
	deviceTargets := make(map[string][]models.Target)
	deviceMetadata := make(map[string]map[string]interface{})

	for _, target := range targets {
		deviceID := s.extractDeviceID(target)
		if deviceID != "" {
			deviceTargets[deviceID] = append(deviceTargets[deviceID], target)

			if len(deviceMetadata[deviceID]) == 0 && target.Metadata != nil {
				deviceMetadata[deviceID] = target.Metadata
			}
		}
	}

	// Create aggregators for devices with multiple IPs
	for deviceID, targets := range deviceTargets {
		if len(targets) <= 1 {
			continue
		}

		expectedIPs := make([]string, 0, len(targets))
		for _, t := range targets {
			expectedIPs = append(expectedIPs, t.Host)
		}

		agentID, gatewayID, partition := s.extractAgentInfoFromMetadata(deviceMetadata[deviceID])

		s.deviceResults[deviceID] = &DeviceResultAggregator{
			DeviceID:    deviceID,
			Results:     make([]*models.Result, 0, len(targets)),
			ExpectedIPs: expectedIPs,
			Metadata:    deviceMetadata[deviceID],
			AgentID:     agentID,
			GatewayID:   gatewayID,
			Partition:   partition,
		}

		s.logger.Debug().
			Str("deviceID", deviceID).
			Strs("expectedIPs", expectedIPs).
			Msg("Created device result aggregator for multi-IP device")
	}
}

// extractDeviceID extracts a unique device identifier from target metadata
func (*NetworkSweeper) extractDeviceID(target models.Target) string {
	if target.Metadata == nil {
		return ""
	}

	// Try armis_device_id first
	if armisID, ok := target.Metadata["armis_device_id"]; ok {
		switch v := armisID.(type) {
		case string:
			if v != "" {
				return "armis:" + v
			}
		case int:
			return fmt.Sprintf("armis:%d", v)
		case int64:
			return fmt.Sprintf("armis:%d", v)
		case float64:
			return fmt.Sprintf("armis:%d", int64(v))
		}
	}

	// Try integration_id
	if integrationID, ok := target.Metadata["integration_id"]; ok {
		switch v := integrationID.(type) {
		case string:
			if v != "" {
				return "integration:" + v
			}
		case int:
			return fmt.Sprintf("integration:%d", v)
		case int64:
			return fmt.Sprintf("integration:%d", v)
		case float64:
			return fmt.Sprintf("integration:%d", int64(v))
		}
	}

	return ""
}

// extractAgentInfoFromMetadata extracts agent info from metadata
func (s *NetworkSweeper) extractAgentInfoFromMetadata(metadata map[string]interface{}) (agentID, gatewayID, partition string) {
	agentID = defaultName
	gatewayID = defaultName
	partition = defaultName

	if s.config.AgentID != "" {
		agentID = s.config.AgentID
	}

	if s.config.GatewayID != "" {
		gatewayID = s.config.GatewayID
	}

	if s.config.Partition != "" {
		partition = s.config.Partition
	}

	if metadata != nil {
		if id, ok := metadata["agent_id"].(string); ok && id != "" {
			agentID = id
		}

		if id, ok := metadata["gateway_id"].(string); ok && id != "" {
			gatewayID = id
		}

		if p, ok := metadata["partition"].(string); ok && p != "" {
			partition = p
		}
	}

	return agentID, gatewayID, partition
}

// shouldAggregateResult checks if a result should be aggregated
func (s *NetworkSweeper) shouldAggregateResult(result *models.Result) bool {
	deviceID := s.extractDeviceID(result.Target)
	if deviceID == "" {
		return false
	}

	s.resultsMu.Lock()
	defer s.resultsMu.Unlock()

	_, exists := s.deviceResults[deviceID]

	return exists
}

// addResultToAggregator adds a result to the appropriate aggregator
func (s *NetworkSweeper) addResultToAggregator(result *models.Result) {
	deviceID := s.extractDeviceID(result.Target)
	if deviceID == "" {
		return
	}

	s.resultsMu.Lock()
	defer s.resultsMu.Unlock()

	if aggregator, exists := s.deviceResults[deviceID]; exists {
		aggregator.mu.Lock()
		aggregator.Results = append(aggregator.Results, result)
		aggregator.mu.Unlock()

		s.logger.Debug().
			Str("deviceID", deviceID).
			Str("ip", result.Target.Host).
			Bool("available", result.Available).
			Msg("Added result to device aggregator")
	}
}

// finalizeDeviceAggregators processes all aggregated results and updates devices
func (s *NetworkSweeper) finalizeDeviceAggregators(ctx context.Context) {
	s.resultsMu.Lock()

	aggregators := make([]*DeviceResultAggregator, 0, len(s.deviceResults))

	for _, aggregator := range s.deviceResults {
		aggregators = append(aggregators, aggregator)
	}

	s.resultsMu.Unlock()

	for _, aggregator := range aggregators {
		s.processAggregatedResults(ctx, aggregator)
	}
}

// processAggregatedResults processes the aggregated results for a device
func (s *NetworkSweeper) processAggregatedResults(_ context.Context, aggregator *DeviceResultAggregator) {
	aggregator.mu.Lock()
	defer aggregator.mu.Unlock()

	if len(aggregator.Results) == 0 {
		s.logger.Debug().
			Str("groupKey", aggregator.DeviceID).
			Int("expectedIPs", len(aggregator.ExpectedIPs)).
			Msg("No results collected for device aggregator")

		return
	}

	// Find the primary IP result (first available, or first if none available)
	var primaryResult *models.Result

	for _, result := range aggregator.Results {
		if result.Available {
			primaryResult = result
			break
		}
	}

	if primaryResult == nil {
		primaryResult = aggregator.Results[0]
	}

	// Create device update based on primary result
	deviceID := fmt.Sprintf("%s:%s", aggregator.Partition, primaryResult.Target.Host)
	deviceUpdate := &models.DeviceUpdate{
		AgentID:     aggregator.AgentID,
		GatewayID:   aggregator.GatewayID,
		Partition:   aggregator.Partition,
		DeviceID:    deviceID,
		Source:      models.DiscoverySourceSweep,
		IP:          primaryResult.Target.Host,
		Timestamp:   primaryResult.LastSeen,
		IsAvailable: primaryResult.Available,
		Metadata:    make(map[string]string),
		Confidence:  models.GetSourceConfidence(models.DiscoverySourceSweep),
	}

	// Convert original metadata to string map
	convertMetadataToStringMap(deviceUpdate, aggregator.Metadata)

	// Add aggregated scan results to metadata
	s.addAggregatedScanResults(deviceUpdate, aggregator.Results)

	// Use background context to avoid cancellation
	bgCtx := context.Background()

	// Only update device registry if it's configured
	if s.deviceRegistry != nil {
		if err := s.deviceRegistry.UpdateDevice(bgCtx, deviceUpdate); err != nil {
			s.logger.Error().
				Err(err).
				Str("deviceID", aggregator.DeviceID).
				Msg("Failed to update device with aggregated scan results")
		} else {
			s.logger.Info().
				Str("deviceID", aggregator.DeviceID).
				Int("resultCount", len(aggregator.Results)).
				Str("primaryIP", primaryResult.Target.Host).
				Bool("deviceAvailable", primaryResult.Available).
				Msg("Successfully updated device with aggregated scan results")
		}
	} else {
		s.logger.Debug().
			Str("deviceID", aggregator.DeviceID).
			Msg("Device registry not configured, skipping device update")
	}
}

// addAggregatedScanResults adds scan results for all IPs to device metadata
func (*NetworkSweeper) addAggregatedScanResults(deviceUpdate *models.DeviceUpdate, results []*models.Result) {
	const aggDetailThreshold = 100 // keep tests with small sets passing; production large sets skip details

	total := len(results)
	if total == 0 {
		setEmptyResults(deviceUpdate)
		return
	}

	if total > aggDetailThreshold {
		setCountsOnlyResults(deviceUpdate, results, total)
		return
	}

	setDetailedResults(deviceUpdate, results, total)
}

// setEmptyResults sets metadata for empty results
func setEmptyResults(deviceUpdate *models.DeviceUpdate) {
	deviceUpdate.Metadata["scan_result_count"] = "0"
	deviceUpdate.Metadata["scan_available_count"] = "0"
	deviceUpdate.Metadata["scan_unavailable_count"] = "0"
	deviceUpdate.Metadata["scan_availability_percent"] = "0.0"
	deviceUpdate.IsAvailable = false
}

// setCountsOnlyResults sets metadata for large result sets (counts only)
func setCountsOnlyResults(deviceUpdate *models.DeviceUpdate, results []*models.Result, total int) {
	availableCount := 0

	for _, r := range results {
		if r.Available {
			availableCount++
		}
	}

	unavailableCount := total - availableCount
	deviceUpdate.Metadata["scan_result_count"] = fmt.Sprintf("%d", total)
	deviceUpdate.Metadata["scan_available_count"] = fmt.Sprintf("%d", availableCount)
	deviceUpdate.Metadata["scan_unavailable_count"] = fmt.Sprintf("%d", unavailableCount)
	deviceUpdate.Metadata["scan_detail_truncated"] = "true"
	deviceUpdate.Metadata["scan_availability_percent"] = fmt.Sprintf("%.1f", float64(availableCount)/float64(total)*100)
	deviceUpdate.IsAvailable = availableCount > 0
}

// setDetailedResults sets detailed metadata for small result sets
func setDetailedResults(deviceUpdate *models.DeviceUpdate, results []*models.Result, total int) {
	builders := initializeBuilders(total)
	states := &buildStates{
		firstIP:          true,
		firstAvailable:   true,
		firstUnavailable: true,
		firstICMP:        true,
		firstTCP:         true,
	}
	availableCount := 0

	for _, result := range results {
		processIPLists(result, builders, states)

		if result.Available {
			availableCount++
		}

		processScanDetails(result, builders, states)
	}

	setBuiltMetadata(deviceUpdate, builders, total, availableCount)
}

// buildStates tracks first-time flags for string building
type buildStates struct {
	firstIP, firstAvailable, firstUnavailable, firstICMP, firstTCP bool
}

// scanBuilders holds string builders for different result categories
type scanBuilders struct {
	allIPs, availableIPs, unavailableIPs, icmp, tcp *strings.Builder
}

// initializeBuilders creates and pre-allocates string builders
func initializeBuilders(total int) *scanBuilders {
	builders := &scanBuilders{
		allIPs:         &strings.Builder{},
		availableIPs:   &strings.Builder{},
		unavailableIPs: &strings.Builder{},
		icmp:           &strings.Builder{},
		tcp:            &strings.Builder{},
	}

	// Pre-allocate builders with estimated capacity
	builders.allIPs.Grow(total * 13)
	builders.availableIPs.Grow(total * 13 / 2)
	builders.unavailableIPs.Grow(total * 13 / 2)
	builders.icmp.Grow(total * 60 / 2)
	builders.tcp.Grow(total * 60 / 2)

	return builders
}

// processIPLists builds IP lists based on availability
func processIPLists(result *models.Result, builders *scanBuilders, states *buildStates) {
	// Build all IPs list
	if !states.firstIP {
		builders.allIPs.WriteByte(',')
	}

	builders.allIPs.WriteString(result.Target.Host)

	if states.firstIP {
		states.firstIP = false
	}

	if result.Available {
		if !states.firstAvailable {
			builders.availableIPs.WriteByte(',')
		}

		builders.availableIPs.WriteString(result.Target.Host)

		if states.firstAvailable {
			states.firstAvailable = false
		}
	} else {
		if !states.firstUnavailable {
			builders.unavailableIPs.WriteByte(',')
		}

		builders.unavailableIPs.WriteString(result.Target.Host)

		if states.firstUnavailable {
			states.firstUnavailable = false
		}
	}
}

// processScanDetails builds detailed scan result strings
func processScanDetails(result *models.Result, builders *scanBuilders, states *buildStates) {
	switch result.Target.Mode {
	case models.ModeICMP:
		buildICMPDetails(result, builders.icmp, &states.firstICMP)
	case models.ModeTCP:
		buildTCPDetails(result, builders.tcp, &states.firstTCP)
	case models.ModeTCPConnect:
		buildTCPDetails(result, builders.tcp, &states.firstTCP)
	}
}

// buildScanDetails builds scan details for either ICMP or TCP
func buildScanDetails(result *models.Result, builder *strings.Builder, protocol string, firstFlag *bool) {
	if !*firstFlag {
		builder.WriteByte(';')
	}

	builder.WriteString(result.Target.Host)
	builder.WriteByte(':')
	builder.WriteString(protocol)
	builder.WriteString(":available=")

	if result.Available {
		builder.WriteString("true")
	} else {
		builder.WriteString("false")
	}

	builder.WriteString(":response_time=")
	builder.WriteString(result.RespTime.String())
	builder.WriteString(":packet_loss=")
	fmt.Fprintf(builder, "%.2f", result.PacketLoss)

	if *firstFlag {
		*firstFlag = false
	}
}

// buildICMPDetails builds ICMP scan details
func buildICMPDetails(result *models.Result, builder *strings.Builder, firstICMP *bool) {
	buildScanDetails(result, builder, "icmp", firstICMP)
}

// buildTCPDetails builds TCP scan details
func buildTCPDetails(result *models.Result, builder *strings.Builder, firstTCP *bool) {
	buildScanDetails(result, builder, scannerProtocolTCP, firstTCP)
}

// setBuiltMetadata assigns built strings to device metadata
func setBuiltMetadata(deviceUpdate *models.DeviceUpdate, builders *scanBuilders, total, availableCount int) {
	deviceUpdate.Metadata["scan_all_ips"] = builders.allIPs.String()
	deviceUpdate.Metadata["scan_available_ips"] = builders.availableIPs.String()
	deviceUpdate.Metadata["scan_unavailable_ips"] = builders.unavailableIPs.String()
	deviceUpdate.Metadata["scan_result_count"] = fmt.Sprintf("%d", total)
	deviceUpdate.Metadata["scan_available_count"] = fmt.Sprintf("%d", availableCount)
	deviceUpdate.Metadata["scan_unavailable_count"] = fmt.Sprintf("%d", total-availableCount)

	if builders.icmp.Len() > 0 {
		deviceUpdate.Metadata["scan_icmp_results"] = builders.icmp.String()
	}

	if builders.tcp.Len() > 0 {
		deviceUpdate.Metadata["scan_tcp_results"] = builders.tcp.String()
	}

	deviceUpdate.Metadata["scan_availability_percent"] = fmt.Sprintf("%.1f", float64(availableCount)/float64(total)*100)
	deviceUpdate.IsAvailable = availableCount > 0
}
