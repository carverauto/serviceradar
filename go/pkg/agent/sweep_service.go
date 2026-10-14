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

package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
	"github.com/google/uuid"
)

// SweepService implements Service for network scanning.
type SweepService struct {
	sweeper sweeper.SweepService // Use the full SweepService interface
	mu      sync.RWMutex
	config  *models.Config
	stats   *ScanStats
	logger  logger.Logger

	// Caching fields for sequence tracking
	cachedResults      *models.SweepSummary
	lastSweepTimestamp int64
	currentSequence    uint64

	// Execution context for result tracking
	sweepGroupID string // Current sweep group UUID from config
	executionID  string // Current execution UUID (generated per sweep cycle)
	configHash   string // Config hash for change detection

	// Lease execution state reported in status; empty state means the group
	// is on its local schedule.
	leaseState            string
	leaseNextSlotUnixNano int64
	leaseSlotsRemaining   int
}

// NewSweepService creates a new SweepService.
func NewSweepService(
	config *models.Config,
	log logger.Logger,
	opts ...sweeper.Option,
) (Service, error) {
	config = applyDefaultConfig(config)
	processor := sweeper.NewBaseProcessor(config, log)
	storeOptions := sweeper.StoreOptionsForConfig(config)
	store := sweeper.NewInMemoryStore(processor, log, storeOptions...)

	sweeperInstance, err := sweeper.NewNetworkSweeper(config, store, processor, nil, log, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to create network sweeper: %w", err)
	}

	// Initialize execution context from the provided config.
	// The sweep results payload includes `sweep_group_id`; without seeding this value
	// the core sweep ingestor cannot create the SweepGroupExecution row.
	sweepGroupID := strings.TrimSpace(config.SweepGroupID)

	return &SweepService{
		sweeper:            sweeperInstance,
		config:             config,
		stats:              newScanStats(),
		logger:             log,
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
		sweepGroupID:       sweepGroupID,
		configHash:         strings.TrimSpace(config.ConfigHash),
	}, nil
}

// Start begins the sweep service.
func (s *SweepService) Start(ctx context.Context) error {
	s.logger.Info().Msgf("Starting sweep service with interval %v", s.config.Interval)

	return s.sweeper.Start(ctx)
}

// Stop gracefully stops the sweep service.
func (s *SweepService) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping sweep service")

	err := s.sweeper.Stop() // NetworkSweeper handles closing channels
	if err != nil {
		return fmt.Errorf("failed to stop sweeper: %w", err)
	}

	return nil
}

// RunOnce triggers a single sweep outside the scheduled interval.
func (s *SweepService) RunOnce(ctx context.Context) error {
	runner, ok := s.sweeper.(interface{ RunOnce(context.Context) error })
	if !ok {
		return errSweepRunnerUnavailable
	}

	return runner.RunOnce(ctx)
}

// CancelRun aborts the in-flight sweep, reporting whether one was running.
func (s *SweepService) CancelRun() (bool, error) {
	canceller, ok := s.sweeper.(interface{ CancelRun() bool })
	if !ok {
		return false, errSweepRunnerUnavailable
	}

	return canceller.CancelRun(), nil
}

// RunOnceForExecution runs one sweep as the core-minted executionID (a leased
// slot). The sweeper publishes that id in the same update as the completed
// cycle's LastSweep. This service does not keep a single pending id: the next
// slot must not be able to relabel the previous cycle's results.
func (s *SweepService) RunOnceForExecution(ctx context.Context, executionID string) error {
	if runner, ok := s.sweeper.(interface {
		RunOnceWithExecution(context.Context, string) error
	}); ok {
		return runner.RunOnceWithExecution(ctx, executionID)
	}

	return s.RunOnce(ctx)
}

// SetLeaseDriven replaces the group's local ticker with leased-slot
// execution, or hands the group back to its local schedule.
func (s *SweepService) SetLeaseDriven(driven bool) {
	if scheduler, ok := s.sweeper.(interface{ SetManualSchedule(bool) }); ok {
		scheduler.SetManualSchedule(driven)
	}

	if !driven {
		s.SetLeaseState("", 0, 0)
	}
}

// SetLeaseState records the lease execution state shown in status payloads:
// "active" while slots remain, "exhausted" when none do, "" when unleased.
func (s *SweepService) SetLeaseState(state string, nextSlotUnixNano int64, slotsRemaining int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.leaseState = state
	s.leaseNextSlotUnixNano = nextSlotUnixNano
	s.leaseSlotsRemaining = slotsRemaining
}

// Name returns the service name.
func (*SweepService) Name() string {
	return networkSweepServiceName
}

// UpdateConfig updates the service configuration.
func (s *SweepService) UpdateConfig(config *models.Config) error {
	newConfig := applyDefaultConfig(config)

	s.logger.Info().
		Dur("newInterval", newConfig.Interval).
		Str("sweepGroupID", newConfig.SweepGroupID).
		Msg("Applying updated sweep config")

	// Update execution context for result tracking (takes its own lock)
	if newConfig.SweepGroupID != "" || newConfig.ConfigHash != "" {
		s.SetExecutionContext(newConfig.SweepGroupID, newConfig.ConfigHash)
	}

	s.mu.Lock()
	s.config = newConfig
	s.logger.Info().Msgf("Updated sweep config: %+v", newConfig)
	s.mu.Unlock()

	return s.sweeper.UpdateConfig(newConfig)
}

// GetStatus returns the current status of the sweep service (lightweight version without hosts).
func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	status, _, err := s.GetStatusWithMetricPayload(ctx)
	return status, err
}

// GetStatusWithMetricPayload returns the regular status payload plus typed data
// for building the canonical sweep MetricBatch without reparsing status JSON.
func (s *SweepService) GetStatusWithMetricPayload(ctx context.Context) (*proto.StatusResponse, map[string]any, error) {
	s.logger.Debug().Msg("Fetching sweep status")

	summary, err := s.sweeper.GetStatus(ctx)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep summary")
		return nil, nil, fmt.Errorf("failed to get sweep status: %w", err)
	}

	s.mu.RLock()
	network := ""
	definedCIDRs := 0
	if s.config != nil {
		network = strings.Join(s.config.Networks, ",")
		definedCIDRs = len(s.config.Networks)
	}
	bannerGrab := s.sweeper.GetBannerGrabStats()
	data := map[string]any{
		"network":         network,
		"total_hosts":     summary.TotalHosts,
		"available_hosts": summary.AvailableHosts,
		"last_sweep":      summary.LastSweep,
		"ports":           summary.Ports,
		"defined_cidrs":   definedCIDRs,
		"unique_ips":      s.stats.uniqueIPs,
		"sequence":        s.currentSequence,
	}
	if bannerGrab != nil {
		data["banner_grab"] = bannerGrab
	}
	var leaseReport map[string]any
	if s.leaseState != "" {
		leaseReport = sweepLeaseReport(s.leaseState, s.leaseNextSlotUnixNano, s.leaseSlotsRemaining, s.sweepGroupID)
		data["sweep_lease"] = leaseReport
	}
	s.mu.RUnlock()

	statusDoc := map[string]any{
		"network":       network,
		"last_sweep":    summary.LastSweep,
		"defined_cidrs": definedCIDRs,
		"sequence":      s.currentSequence,
		"status":        "collecting",
	}
	if leaseReport != nil {
		statusDoc["sweep_lease"] = []map[string]any{leaseReport}
	}
	statusJSON, err := json.Marshal(statusDoc)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal status")
		return nil, nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      statusJSON,
		ServiceName:  networkSweepServiceName,
		ServiceType:  "sweep",
		ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
	}, data, nil
}

func (s *SweepService) GetBannerGrabStats() *models.BannerGrabStats {
	return s.sweeper.GetBannerGrabStats()
}

func (s *SweepService) BannerGrabEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.config != nil && s.config.BannerGrab.Enabled
}

func (s *SweepService) Check(ctx context.Context, _ *proto.StatusRequest) (bool, json.RawMessage) {
	resp, err := s.GetStatus(ctx)
	if err != nil {
		return false, jsonError(err.Error())
	}

	return resp.Available, resp.Message
}

func (s *SweepService) Close() error {
	return s.Stop(context.Background())
}

// applyDefaultConfig sets default values for the config.
func applyDefaultConfig(config *models.Config) *models.Config {
	if config == nil {
		config = &models.Config{}
	}

	if len(config.SweepModes) == 0 {
		config.SweepModes = []models.SweepMode{models.ModeICMP, models.ModeTCP}
	}

	if config.Timeout == 0 {
		// Reduced from 5s to 2s for faster TCP scanning
		// Failed connections will timeout quicker, improving throughput
		config.Timeout = 2 * time.Second
	}

	if config.Concurrency == 0 {
		// Increased from 20 to handle large-scale TCP scanning
		// With 164k+ TCP targets, we need much higher concurrency
		config.Concurrency = 500
	}

	if config.Interval == 0 {
		config.Interval = 5 * time.Minute
	}

	if config.ICMPRateLimit == 0 {
		config.ICMPRateLimit = 1000
	}

	if config.ICMPCount == 0 {
		// Send 3 ICMP packets per target by default for reliable availability detection
		// Host is marked available if ANY packet receives a reply
		config.ICMPCount = 3
	}

	return config
}

// ScanStats tracks scanning statistics.
type ScanStats struct {
	uniqueHosts map[string]struct{}
	uniqueIPs   int
	startTime   time.Time
}

func newScanStats() *ScanStats {
	return &ScanStats{
		uniqueHosts: make(map[string]struct{}),
		startTime:   time.Now(),
	}
}

// CheckICMP performs a standalone ICMP check on the specified host.
func (s *SweepService) CheckICMP(ctx context.Context, host string) (*models.Result, error) {
	var opts []scan.ICMPSweeperOption
	if s.config.ICMPCount > 0 {
		opts = append(opts, scan.WithICMPCount(s.config.ICMPCount))
	}

	icmpScanner, err := scan.NewICMPSweeper(s.config.Timeout, s.config.ICMPRateLimit, s.logger, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	defer func() {
		if stopErr := icmpScanner.Stop(); stopErr != nil {
			s.logger.Error().Err(stopErr).Msg("Failed to stop ICMP scanner")
		}
	}()

	target := models.Target{Host: host, Mode: models.ModeICMP}

	results, err := icmpScanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return nil, fmt.Errorf("ICMP scan failed: %w", err)
	}

	var result models.Result

	for r := range results {
		result = r

		break // Expecting one result
	}

	return &result, nil
}

// GetSweepResults returns sweep results with sequence tracking for change detection.
func (s *SweepService) GetSweepResults(ctx context.Context, lastSequence string) (*proto.ResultsResponse, error) {
	s.logger.Debug().Str("lastSequence", lastSequence).Msg("GetSweepResults called")

	summary, err := s.sweeper.GetStatus(ctx)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep summary for results")
		return nil, fmt.Errorf("failed to get sweep results: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	totalHosts := summary.TotalHosts
	hostsProcessed := len(summary.Hosts)
	sweepComplete := summary.LastSweep > 0 && hostsProcessed > 0

	// Only publish results when a sweep has completed
	if sweepComplete && summary.LastSweep != s.lastSweepTimestamp {
		// Update cached results and increment sequence
		s.cachedResults = summary
		s.lastSweepTimestamp = summary.LastSweep
		s.currentSequence++

		// The id belongs to this LastSweep only when the sweeper published
		// them together. A later cycle with an empty id gets a local UUID,
		// and an id from a cycle that did not publish does not carry forward.
		if summary.ExecutionID != "" {
			s.executionID = summary.ExecutionID
		} else {
			s.executionID = uuid.New().String()
		}

		s.logger.Info().
			Uint64("newSequence", s.currentSequence).
			Str("executionID", s.executionID).
			Msg("Sweep data changed, updated sequence and execution ID")
	}

	currentSeqStr := fmt.Sprintf("%d", s.currentSequence)

	sweepGroupID := s.sweepGroupID
	if sweepGroupID == "" {
		// Back-compat / safety: prefer config value if execution context hasn't been set yet.
		sweepGroupID = strings.TrimSpace(s.config.SweepGroupID)
	}

	// If the caller's sequence is up to date, return no new data
	if lastSequence != "" && lastSequence == currentSeqStr {
		s.logger.Debug().Str("callerSequence", lastSequence).Str("currentSequence", currentSeqStr).Msg("No new sweep data")

		return &proto.ResultsResponse{
			HasNewData:      false,
			CurrentSequence: currentSeqStr,
			ServiceName:     networkSweepServiceName,
			ServiceType:     "sweep",
			ExecutionId:     s.executionID,
			SweepGroupId:    sweepGroupID,
			Available:       true,
			Timestamp:       time.Now().Unix(),
		}, nil
	}

	if s.cachedResults == nil || len(s.cachedResults.Hosts) == 0 {
		s.logger.Debug().
			Str("sequence", currentSeqStr).
			Int("totalHosts", totalHosts).
			Int("hostsProcessed", hostsProcessed).
			Msg("No completed sweep results available to return")

		return &proto.ResultsResponse{
			HasNewData:      false,
			CurrentSequence: currentSeqStr,
			ServiceName:     networkSweepServiceName,
			ServiceType:     "sweep",
			ExecutionId:     s.executionID,
			SweepGroupId:    sweepGroupID,
			Available:       true,
			Timestamp:       time.Now().Unix(),
		}, nil
	}

	// Marshal the full sweep results
	resultPayload := map[string]interface{}{
		"network":         s.cachedResults.Network,
		"total_hosts":     s.cachedResults.TotalHosts,
		"available_hosts": s.cachedResults.AvailableHosts,
		"last_sweep":      s.cachedResults.LastSweep,
		"ports":           s.cachedResults.Ports,
		"hosts":           s.cachedResults.Hosts,
		"execution_id":    s.executionID,
		"sweep_group_id":  sweepGroupID,
	}

	// Signal a scan-timeout cancellation so the server can record the correct
	// execution status (cancelled rather than completed).
	if wasCancelled, ok := s.sweeper.(interface{ WasCancelledSweep() bool }); ok && wasCancelled.WasCancelledSweep() {
		resultPayload["cancelled"] = true
	}

	if scannerStats := s.sweeper.GetScannerStats(); scannerStats != nil {
		resultPayload["scanner_stats"] = scannerStats
	}
	if bannerStats := s.sweeper.GetBannerGrabStats(); bannerStats != nil {
		resultPayload["banner_grab"] = bannerStats
	}

	resultData, err := json.Marshal(resultPayload)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal sweep results")
		return nil, fmt.Errorf("failed to marshal sweep results: %w", err)
	}

	s.logger.Info().
		Str("sequence", currentSeqStr).
		Int("hostCount", len(s.cachedResults.Hosts)).
		Str("executionID", s.executionID).
		Str("sweepGroupID", s.sweepGroupID).
		Msg("Returning new sweep data")

	// Build sweep completion status with scanner stats
	sweepCompletion := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		ExecutionId:      s.executionID,
		SweepGroupId:     sweepGroupID,
		TotalTargets:     int32(len(s.cachedResults.Hosts)),
		CompletedTargets: int32(len(s.cachedResults.Hosts)),
		CompletionTime:   time.Now().Unix(),
	}

	// Populate scanner stats if available
	if scannerStats := s.sweeper.GetScannerStats(); scannerStats != nil {
		sweepCompletion.ScannerStats = &proto.SweepScannerStats{
			Protocol:             scannerStats.Protocol,
			AddressFamily:        scannerStats.AddressFamily,
			ScannerPath:          scannerStats.ScannerPath,
			PacketsSent:          scannerStats.PacketsSent,
			PacketsRecv:          scannerStats.PacketsRecv,
			PacketsDropped:       scannerStats.PacketsDropped,
			RingBlocksProcessed:  scannerStats.RingBlocksProcessed,
			RingBlocksDropped:    scannerStats.RingBlocksDropped,
			RetriesAttempted:     scannerStats.RetriesAttempted,
			RetriesSuccessful:    scannerStats.RetriesSuccessful,
			PortsAllocated:       scannerStats.PortsAllocated,
			PortsReleased:        scannerStats.PortsReleased,
			PortExhaustionCount:  scannerStats.PortExhaustionCount,
			RateLimitDeferrals:   scannerStats.RateLimitDeferrals,
			RateLimitWaits:       scannerStats.RateLimitWaits,
			SourcePortWaits:      scannerStats.SourcePortWaits,
			RateLimitWaitTimeMs:  scannerStats.RateLimitWaitTimeMs,
			SourcePortWaitTimeMs: scannerStats.SourcePortWaitTimeMs,
			RxDropRatePercent:    scannerStats.RxDropRatePercent,
			DialsStarted:         scannerStats.DialsStarted,
			DialsSucceeded:       scannerStats.DialsSucceeded,
			DialTimeouts:         scannerStats.DialTimeouts,
			DialResets:           scannerStats.DialResets,
			DialResourceErrors:   scannerStats.DialResourceErrors,
			ActiveDials:          scannerStats.ActiveDials,
			MaxActiveDials:       scannerStats.MaxActiveDials,
			QueueDepth:           scannerStats.QueueDepth,
			MaxQueueDepth:        scannerStats.MaxQueueDepth,
		}
	}

	return &proto.ResultsResponse{
		HasNewData:      true,
		CurrentSequence: currentSeqStr,
		Data:            resultData,
		ServiceName:     networkSweepServiceName,
		ServiceType:     "sweep",
		Available:       true,
		Timestamp:       time.Now().Unix(),
		ExecutionId:     s.executionID,
		SweepGroupId:    sweepGroupID,
		SweepCompletion: sweepCompletion,
	}, nil
}

func sweepLeaseReport(state string, nextSlotUnixNano int64, slotsRemaining int, sweepGroupID string) map[string]any {
	return map[string]any{
		"state":               state,
		"next_slot_unix_nano": nextSlotUnixNano,
		"slots_remaining":     slotsRemaining,
		"sweep_group_id":      sweepGroupID,
	}
}

// SetExecutionContext updates the sweep group ID and config hash from config.
// This should be called when the sweep config is updated from the gateway.
func (s *SweepService) SetExecutionContext(sweepGroupID, configHash string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.sweepGroupID != sweepGroupID || s.configHash != configHash {
		s.logger.Info().
			Str("oldGroupID", s.sweepGroupID).
			Str("newGroupID", sweepGroupID).
			Str("oldHash", s.configHash).
			Str("newHash", configHash).
			Msg("Updating sweep execution context")

		s.sweepGroupID = sweepGroupID
		s.configHash = configHash
	}
}

// GetConfigHash returns the current config hash for change detection.
func (s *SweepService) GetConfigHash() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.configHash
}
