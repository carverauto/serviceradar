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
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

const (
	defaultInterval      = 5 * time.Minute
	scanTimeout          = 20 * time.Minute // Timeout for individual scan operations - increased for large-scale TCP scanning
	defaultResultTimeout = 500 * time.Millisecond
	// KV Watch auto-reconnect parameters
	kvWatchInitialBackoff = 1 * time.Second
	kvWatchMaxBackoff     = 5 * time.Minute
	kvWatchBackoffFactor  = 2.0
	kvWatchJitterFactor   = 0.1 // 10% jitter
)

// min returns the minimum of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// DeviceRegistryService interface for device registry operations
type DeviceRegistryService interface {
	ProcessSweepResult(ctx context.Context, result *models.SweepResult) error
	UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error
	GetDevice(ctx context.Context, deviceID string) (*models.UnifiedDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.UnifiedDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.UnifiedDevice, error)
}

// NetworkSweeper implements both Sweeper and SweepService interfaces.
type NetworkSweeper struct {
	config         *models.Config
	icmpScanner    scan.Scanner
	tcpScanner     scan.Scanner
	store          Store
	processor      ResultProcessor
	kvStore        KVStore
	deviceRegistry DeviceRegistryService
	configKey      string
	logger         logger.Logger
	mu             sync.RWMutex
	done           chan struct{}
	watchDone      chan struct{}
	lastSweep      time.Time
	// KV change detection
	lastConfigTimestamp string
	lastConfigHash      [32]byte
	// Device result aggregation for multi-IP devices
	deviceResults map[string]*DeviceResultAggregator
	resultsMu     sync.Mutex
}

// DeviceResultAggregator aggregates scan results for a device with multiple IPs
type DeviceResultAggregator struct {
	DeviceID    string
	Results     []*models.Result
	ExpectedIPs []string
	Metadata    map[string]interface{}
	AgentID     string
	PollerID    string
	Partition   string
	mu          sync.Mutex
}

var (
	errNilConfig = fmt.Errorf("config cannot be nil")
)

const (
	defaultTotalTargetLimitPercentage = 10
	defaultEffectiveConcurrency       = 5

	// Concurrency upper bounds to prevent resource exhaustion
	maxSYNConcurrency     = 2048 // SYN scanning can handle higher concurrency efficiently
	maxConnectConcurrency = 500  // TCP connect() is more resource intensive
)

// NewNetworkSweeper creates a new scanner for network sweeping.
func NewNetworkSweeper(
	config *models.Config,
	store Store,
	processor ResultProcessor,
	kvStore KVStore,
	deviceRegistry DeviceRegistryService,
	configKey string,
	log logger.Logger) (*NetworkSweeper, error) {
	if config == nil {
		return nil, errNilConfig
	}

	icmpScanner := initializeICMPScanner(config, log)
	tcpScanner := initializeTCPScanner(config, log)

	// Default interval if not set
	if config.Interval == 0 {
		config.Interval = defaultInterval
	}

	log.Info().Dur("interval", config.Interval).Msg("Creating NetworkSweeper")

	return &NetworkSweeper{
		config:         config,
		icmpScanner:    icmpScanner,
		tcpScanner:     tcpScanner,
		store:          store,
		processor:      processor,
		kvStore:        kvStore,
		deviceRegistry: deviceRegistry,
		configKey:      configKey,
		logger:         log,
		done:           make(chan struct{}),
		watchDone:      make(chan struct{}),
		deviceResults:  make(map[string]*DeviceResultAggregator),
	}, nil
}

// initializeICMPScanner creates an ICMP scanner if needed based on config
func initializeICMPScanner(config *models.Config, log logger.Logger) scan.Scanner {
	if !needsICMPScanning(config) {
		return nil
	}

	icmpScanner, err := scan.NewICMPSweeper(config.Timeout, config.ICMPRateLimit, log)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to create ICMP scanner, ICMP scanning will be disabled")
		return nil
	}

	return icmpScanner
}

// needsICMPScanning checks if ICMP scanning is needed based on config
func needsICMPScanning(config *models.Config) bool {
	// Check global sweep modes
	for _, mode := range config.SweepModes {
		if mode == models.ModeICMP {
			return true
		}
	}

	// Check device target sweep modes
	for _, deviceTarget := range config.DeviceTargets {
		for _, mode := range deviceTarget.SweepModes {
			if mode == models.ModeICMP {
				return true
			}
		}
	}

	return false
}

// configureSYNScannerOptions configures SYN scanner options from config
func configureSYNScannerOptions(config *models.Config, log logger.Logger) *scan.SYNScannerOptions {
	opts := &scan.SYNScannerOptions{}

	// Use TCPSettings.MaxBatch if configured
	if config.TCPSettings.MaxBatch > 0 {
		opts.SendBatchSize = config.TCPSettings.MaxBatch
		log.Debug().Int("tcp_max_batch", config.TCPSettings.MaxBatch).Msg("Using configured TCP max batch size for SYN scanner")
	}

	// Use configured route discovery host for locked-down environments
	if config.TCPSettings.RouteDiscoveryHost != "" {
		opts.RouteDiscoveryHost = config.TCPSettings.RouteDiscoveryHost
		log.Debug().Str("route_discovery_host", config.TCPSettings.RouteDiscoveryHost).
			Msg("Using configured route discovery host for local IP detection")
	}

	// Configure ring buffer settings
	configureRingBufferSettings(config, opts, log)

	// Configure network interface for multi-homed hosts
	if config.TCPSettings.Interface != "" {
		opts.Interface = config.TCPSettings.Interface
		log.Debug().Str("interface", opts.Interface).Msg("Using configured network interface")
	}

	// Configure NAT/firewall compatibility options
	if config.TCPSettings.SuppressRSTReply {
		opts.SuppressRSTReply = true

		log.Debug().Msg("RST reply suppression enabled for firewall compatibility")
	}

	// Configure global memory limit for ring buffers
	if config.TCPSettings.GlobalRingMemoryMB > 0 {
		opts.GlobalRingMemoryMB = config.TCPSettings.GlobalRingMemoryMB
		log.Debug().Int("global_ring_memory_mb", opts.GlobalRingMemoryMB).
			Msg("Using configured global ring buffer memory limit")
	}

	return opts
}

// configureRingBufferSettings configures ring buffer settings for SYN scanner
func configureRingBufferSettings(config *models.Config, opts *scan.SYNScannerOptions, log logger.Logger) {
	// Configure ring buffer block size
	if config.TCPSettings.RingBlockSize > 0 {
		if config.TCPSettings.RingBlockSize <= int(^uint32(0)) {
			opts.RingBlockSize = uint32(config.TCPSettings.RingBlockSize) // #nosec G115 - bounds check above ensures no overflow
		} else {
			opts.RingBlockSize = ^uint32(0) // Use max uint32 value if overflow would occur
		}

		log.Debug().Uint32("ring_block_size", opts.RingBlockSize).Msg("Using configured ring buffer block size")
	}

	// Configure ring readers and poll timeout tunables
	if config.TCPSettings.RingReaders > 0 {
		opts.RingReaders = config.TCPSettings.RingReaders
		log.Debug().Int("ring_readers", opts.RingReaders).Msg("Using configured ring reader count")
	}

	if config.TCPSettings.RingPollTimeoutMs > 0 {
		opts.RingPollTimeoutMs = config.TCPSettings.RingPollTimeoutMs
		log.Debug().Int("ring_poll_timeout_ms", opts.RingPollTimeoutMs).Msg("Using configured ring poll timeout")
	}

	// Configure ring buffer block count
	if config.TCPSettings.RingBlockCount > 0 {
		if config.TCPSettings.RingBlockCount <= int(^uint32(0)) {
			opts.RingBlockCount = uint32(config.TCPSettings.RingBlockCount) // #nosec G115 - bounds check above ensures no overflow
		} else {
			opts.RingBlockCount = ^uint32(0) // Use max uint32 value if overflow would occur
		}

		log.Debug().Uint32("ring_block_count", opts.RingBlockCount).Msg("Using configured ring buffer block count")
	}
}

// initializeTCPScanner creates and configures the TCP scanner with graceful fallback
func initializeTCPScanner(config *models.Config, log logger.Logger) scan.Scanner {
	// Prefer TCP-specific settings if set; otherwise fall back to global settings
	baseTimeout := config.TCPSettings.Timeout
	if baseTimeout == 0 {
		baseTimeout = config.Timeout
	}

	baseConcurrency := config.TCPSettings.Concurrency
	if baseConcurrency <= 0 {
		baseConcurrency = calculateEffectiveConcurrency(config, log)
	}

	log.Debug().Dur("baseTimeout", baseTimeout).Int("baseConcurrency", baseConcurrency).
		Msg("Using TCP-specific settings for scanner initialization")

	// Try SYN scanner first for optimal performance
	opts := configureSYNScannerOptions(config, log)

	// Apply SYN concurrency upper bound
	synConcurrency := baseConcurrency
	if synConcurrency > maxSYNConcurrency {
		synConcurrency = maxSYNConcurrency
		log.Info().Int("originalConcurrency", baseConcurrency).Int("clampedConcurrency", synConcurrency).
			Msg("Clamped SYN scanner concurrency to prevent resource exhaustion")
	}

	synScanner, err := scan.NewSYNScanner(config.TCPSettings.Timeout, synConcurrency, log, opts)
	if err == nil {
		log.Info().Int("concurrency", synConcurrency).Msg("Using SYN scanning for improved TCP port detection performance")
		return synScanner
	}

	// SYN scanner failed (non-Linux, container without CAP_NET_RAW, etc.)
	// Gracefully fall back to TCP connect() scanner
	log.Warn().Err(err).Msg("SYN scanner unavailable; falling back to TCP connect() scanner")

	// Apply connect scanner concurrency upper bound (more restrictive)
	connectConcurrency := baseConcurrency
	if connectConcurrency > maxConnectConcurrency {
		connectConcurrency = maxConnectConcurrency
		log.Info().Int("originalConcurrency", baseConcurrency).Int("clampedConcurrency", connectConcurrency).
			Msg("Clamped TCP connect scanner concurrency to prevent resource exhaustion")
	}

	tcpScanner := scan.NewTCPSweeper(baseTimeout, connectConcurrency, log)
	log.Info().Int("concurrency", connectConcurrency).Msg("Using TCP connect() scanning (slower but more compatible)")

	return tcpScanner
}

// calculateEffectiveConcurrency adjusts concurrency based on target count
func calculateEffectiveConcurrency(config *models.Config, log logger.Logger) int {
	totalTargets := estimateTargetCount(config)
	effectiveConcurrency := config.Concurrency

	if totalTargets > 0 && effectiveConcurrency > totalTargets/10 {
		effectiveConcurrency = totalTargets / defaultTotalTargetLimitPercentage // Limit to 10% of targets
		if effectiveConcurrency < defaultEffectiveConcurrency {
			effectiveConcurrency = defaultEffectiveConcurrency // Minimum concurrency
		}

		log.Debug().Int("adjustedConcurrency", effectiveConcurrency).Int("totalTargets", totalTargets).Msg("Adjusted concurrency for targets")
	}

	return effectiveConcurrency
}

// Start begins periodic sweeping and KV watching.
func (s *NetworkSweeper) Start(ctx context.Context) error {
	s.logger.Info().Dur("interval", s.config.Interval).Msg("Starting network sweeper")

	// Start KV config watching and wait for initial config (if available)
	configReady := make(chan struct{})
	go s.watchConfigWithInitialSignal(ctx, configReady)

	// Wait for initial config update (with timeout) or proceed with file config
	select {
	case <-configReady:
		s.logger.Info().Msg("Received initial KV config, starting sweep with updated configuration")
	case <-time.After(10 * time.Second):
		s.logger.Info().Msg("No KV config received within timeout, starting sweep with file configuration")
	case <-ctx.Done():
		return ctx.Err()
	}

	initialCtx, initialCancel := context.WithTimeout(ctx, scanTimeout)
	if err := s.runSweep(initialCtx); err != nil {
		initialCancel()

		s.logger.Error().Err(err).Msg("Initial sweep failed")
	} else {
		s.logger.Info().Msg("Initial sweep completed successfully")
	}

	initialCancel()

	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	s.logger.Debug().Dur("interval", s.config.Interval).Msg("Entering sweep loop")

	for {
		select {
		case <-ctx.Done():
			s.logger.Info().Msg("Context canceled, stopping sweeper")

			return ctx.Err()
		case <-s.done:
			s.logger.Info().Msg("Received done signal, stopping sweeper")

			return nil
		case t := <-ticker.C:
			s.logger.Debug().Time("tickTime", t).Msg("Ticker fired, starting periodic sweep")

			sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
			if err := s.runSweep(sweepCtx); err != nil {
				s.logger.Error().Err(err).Msg("Periodic sweep failed")
			} else {
				s.logger.Debug().Msg("Periodic sweep completed successfully")
			}

			sweepCancel()

			s.mu.Lock()
			s.lastSweep = time.Now()
			s.mu.Unlock()
		}
	}
}

// Stop gracefully stops sweeping and KV watching.
func (s *NetworkSweeper) Stop() error {
	s.logger.Info().Msg("Stopping network sweeper")

	close(s.done)
	<-s.watchDone // Wait for KV watching to stop

	if s.icmpScanner != nil {
		if err := s.icmpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop ICMP scanner")
		}
	}

	if s.tcpScanner != nil {
		if err := s.tcpScanner.Stop(); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop TCP scanner")
		}
	}

	return nil
}

// GetStatus returns current sweep status.
func (s *NetworkSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	return s.store.GetSweepSummary(ctx)
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

// preserveIntValue preserves an existing int value if the new value is zero.
// Returns true if the value was preserved.
func preserveIntValue(newVal *int, existingVal int) bool {
	if *newVal == 0 && existingVal > 0 {
		*newVal = existingVal
		return true
	}

	return false
}

// preserveDurationValue preserves an existing time.Duration value if the new value is zero.
// Returns true if the value was preserved.
func preserveDurationValue(newVal *time.Duration, existingVal time.Duration) bool {
	if *newVal == 0 && existingVal > 0 {
		*newVal = existingVal
		return true
	}

	return false
}

// preserveBoolValue preserves an existing bool value if the new value is false.
// Returns true if the value was preserved.
func preserveBoolValue(newVal *bool, existingVal bool) bool {
	if !*newVal && existingVal {
		*newVal = existingVal
		return true
	}

	return false
}

// preserveSliceValues preserves existing slice values if the new slice is empty.
// Returns true if values were preserved.
func preserveSliceValues[T any](newSlice *[]T, existingSlice []T) bool {
	if len(*newSlice) == 0 && len(existingSlice) > 0 {
		*newSlice = existingSlice
		return true
	}

	return false
}

// preserveField is a generic function that preserves a field value and records the field name
// if preservation occurred.
func preserveField(preservedFields *[]string, fieldName string, preserved bool) {
	if preserved {
		*preservedFields = append(*preservedFields, fieldName)
	}
}

// preserveConfigFields handles preservation of multiple fields of the same type
func preserveConfigFields(preservedFields *[]string, fieldMap map[string]bool) {
	for fieldName, preserved := range fieldMap {
		preserveField(preservedFields, fieldName, preserved)
	}
}

// UpdateConfig updates sweeper configuration.
func (s *NetworkSweeper) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.logger.Info().
		Int("networks", len(config.Networks)).
		Int("deviceTargets", len(config.DeviceTargets)).
		Int("ports", len(config.Ports)).
		Msg("Updating sweeper config")

	// Preserve existing non-zero values when new config has zero values
	// This allows minimal configs from sync service (with only networks) to work properly
	preservedFields := []string{}

	// Always update networks (this is what sync service sends)
	// Networks field is handled by direct assignment below

	// Preserve basic configuration fields
	preserveConfigFields(&preservedFields, map[string]bool{
		"ports":       preserveSliceValues(&config.Ports, s.config.Ports),
		"sweep_modes": preserveSliceValues(&config.SweepModes, s.config.SweepModes),
	})

	// Preserve duration fields
	preserveConfigFields(&preservedFields, map[string]bool{
		"interval":     preserveDurationValue(&config.Interval, s.config.Interval),
		"timeout":      preserveDurationValue(&config.Timeout, s.config.Timeout),
		"max_lifetime": preserveDurationValue(&config.MaxLifetime, s.config.MaxLifetime),
		"idle_timeout": preserveDurationValue(&config.IdleTimeout, s.config.IdleTimeout),
	})

	// Preserve integer fields
	preserveConfigFields(&preservedFields, map[string]bool{
		"concurrency": preserveIntValue(&config.Concurrency, s.config.Concurrency),
		"icmp_count":  preserveIntValue(&config.ICMPCount, s.config.ICMPCount),
		"max_idle":    preserveIntValue(&config.MaxIdle, s.config.MaxIdle),
	})

	// Preserve ICMP settings
	preserveConfigFields(&preservedFields, map[string]bool{
		"icmp_rate_limit": preserveIntValue(&config.ICMPSettings.RateLimit, s.config.ICMPSettings.RateLimit),
		"icmp_timeout":    preserveDurationValue(&config.ICMPSettings.Timeout, s.config.ICMPSettings.Timeout),
		"icmp_max_batch":  preserveIntValue(&config.ICMPSettings.MaxBatch, s.config.ICMPSettings.MaxBatch),
	})

	// Preserve TCP settings
	preserveConfigFields(&preservedFields, map[string]bool{
		"tcp_concurrency": preserveIntValue(&config.TCPSettings.Concurrency, s.config.TCPSettings.Concurrency),
		"tcp_timeout":     preserveDurationValue(&config.TCPSettings.Timeout, s.config.TCPSettings.Timeout),
		"tcp_max_batch":   preserveIntValue(&config.TCPSettings.MaxBatch, s.config.TCPSettings.MaxBatch),
	})

	// Preserve additional settings
	preserveConfigFields(&preservedFields, map[string]bool{
		"icmp_rate_limit_global": preserveIntValue(&config.ICMPRateLimit, s.config.ICMPRateLimit),
		"high_perf_icmp":         preserveBoolValue(&config.EnableHighPerformanceICMP, s.config.EnableHighPerformanceICMP),
	})

	if len(preservedFields) > 0 {
		s.logger.Debug().Strs("preserved_fields", preservedFields).Msg("Preserved existing config values from zero/nil values")
	}

	s.config = config

	// Re-check if we need ICMP scanner based on updated config
	needsICMP := false

	// Check global sweep modes
	for _, mode := range config.SweepModes {
		if mode == models.ModeICMP {
			needsICMP = true
			break
		}
	}

	// Also check device target sweep modes
	if !needsICMP {
		for _, deviceTarget := range config.DeviceTargets {
			for _, mode := range deviceTarget.SweepModes {
				if mode == models.ModeICMP {
					needsICMP = true
					break
				}
			}

			if needsICMP {
				break
			}
		}
	}

	// Initialize ICMP scanner if needed and not already initialized
	if needsICMP && s.icmpScanner == nil {
		icmpScanner, err := scan.NewICMPSweeper(config.Timeout, config.ICMPRateLimit, s.logger)
		if err != nil {
			s.logger.Warn().Err(err).Msg("Failed to create ICMP scanner during config update, ICMP scanning will be disabled")
		} else {
			s.icmpScanner = icmpScanner
			s.logger.Info().Msg("Initialized ICMP scanner based on updated config")
		}
	}

	return nil
}

// handleCancellation checks for context cancellation or sweeper shutdown and closes configReady if needed
func (s *NetworkSweeper) handleCancellation(ctx context.Context, initialConfigReceived bool, configReady chan<- struct{}) bool {
	select {
	case <-ctx.Done():
		s.logger.Debug().Msg("Context canceled, stopping config watch")

		if !initialConfigReceived {
			close(configReady)
		}

		return true
	case <-s.done:
		s.logger.Debug().Msg("Sweep service closed, stopping config watch")

		if !initialConfigReceived {
			close(configReady)
		}

		return true
	default:
		return false
	}
}

// handleBackoffWait implements the backoff logic with cancellation checks
func (s *NetworkSweeper) handleBackoffWait(
	ctx context.Context, backoff time.Duration, initialConfigReceived bool, configReady chan<- struct{},
) bool {
	// Reset backoff on successful initial config to avoid long delays on subsequent reconnects
	if initialConfigReceived {
		backoff = kvWatchInitialBackoff
	}

	// Add jitter to prevent thundering herd
	jitterDelay := s.addJitter(backoff)

	s.logger.Debug().
		Dur("delay", jitterDelay).
		Dur("baseBackoff", backoff).
		Msg("KV watch channel closed, retrying after backoff")

	// Wait for backoff duration or context cancellation
	select {
	case <-ctx.Done():
		s.logger.Debug().Msg("Context canceled during backoff, stopping config watch")

		if !initialConfigReceived {
			close(configReady)
		}

		return true
	case <-s.done:
		s.logger.Debug().Msg("Sweep service closed during backoff, stopping config watch")

		if !initialConfigReceived {
			close(configReady)
		}

		return true
	case <-time.After(jitterDelay):
		// Continue to next iteration
		return false
	}
}

// watchConfigWithInitialSignal watches the KV store for config updates and signals when first config is received.
// Implements auto-reconnect with exponential backoff and jitter to handle spurious channel closures.
func (s *NetworkSweeper) watchConfigWithInitialSignal(ctx context.Context, configReady chan<- struct{}) {
	defer close(s.watchDone)

	if s.kvStore == nil {
		s.logger.Debug().Msg("No KV store configured, skipping config watch")
		close(configReady) // Signal immediately since there's no KV config to wait for

		return
	}

	s.logger.Info().Str("configKey", s.configKey).Msg("Starting KV watch with auto-reconnect")

	initialConfigReceived := false
	backoff := kvWatchInitialBackoff
	// Auto-reconnect loop with exponential backoff and jitter
	for {
		// Check for cancellation
		if s.handleCancellation(ctx, initialConfigReceived, configReady) {
			return
		}

		// Establish watch connection
		watchResult := s.performKVWatch(ctx, &initialConfigReceived, configReady)

		// If watch returned due to context cancellation or sweeper shutdown, exit
		if watchResult == watchResultCanceled {
			return
		}

		// If this was an error establishing the watch, exit (no retry for connection failures)
		if watchResult == watchResultError {
			return
		}

		// If this was a channel closure, implement backoff before retrying
		if watchResult == watchResultChannelClosed {
			if s.handleBackoffWait(ctx, backoff, initialConfigReceived, configReady) {
				return
			}

			// Exponentially increase backoff, capped at maximum
			backoff = time.Duration(math.Min(
				float64(backoff)*kvWatchBackoffFactor,
				float64(kvWatchMaxBackoff),
			))
		}
	}
}

// watchResult represents the outcome of a KV watch attempt
type watchResult int

const (
	watchResultChannelClosed watchResult = iota
	watchResultCanceled
	watchResultError
)

// performKVWatch performs a single KV watch session and returns the reason it ended
func (s *NetworkSweeper) performKVWatch(ctx context.Context, initialConfigReceived *bool, configReady chan<- struct{}) watchResult {
	ch, err := s.kvStore.Watch(ctx, s.configKey)
	if err != nil {
		s.logger.Error().Err(err).Str("configKey", s.configKey).Msg("Failed to watch KV key")
		// If we can't establish the watch and haven't received initial config, signal to proceed with file config
		if !*initialConfigReceived {
			close(configReady)
		}

		return watchResultError
	}

	s.logger.Debug().Str("configKey", s.configKey).Msg("KV watch established")

	for {
		select {
		case <-ctx.Done():
			s.logger.Debug().Msg("Context canceled during watch")

			if !*initialConfigReceived {
				close(configReady)
			}

			return watchResultCanceled

		case <-s.done:
			s.logger.Debug().Msg("Sweep service closed during watch")

			if !*initialConfigReceived {
				close(configReady)
			}

			return watchResultCanceled

		case value, ok := <-ch:
			if !ok {
				s.logger.Debug().Str("configKey", s.configKey).Msg("Watch channel closed, will retry")
				return watchResultChannelClosed
			}

			s.processConfigUpdate(value)

			// Signal that initial config has been received
			if !*initialConfigReceived {
				*initialConfigReceived = true

				close(configReady)
				s.logger.Info().Str("configKey", s.configKey).Msg("Initial KV config received")
			}
		}
	}
}

// addJitter adds random jitter to backoff duration to prevent thundering herd
func (*NetworkSweeper) addJitter(backoff time.Duration) time.Duration {
	jitter := time.Duration(float64(backoff) * kvWatchJitterFactor * (rand.Float64()*2 - 1))
	jitteredBackoff := backoff + jitter

	// Ensure jittered backoff is positive
	if jitteredBackoff < 0 {
		jitteredBackoff = backoff
	}

	return jitteredBackoff
}

// processConfigUpdate processes a config update from the KV store.
func (s *NetworkSweeper) processConfigUpdate(value []byte) {
	s.logger.Debug().
		Int("valueLength", len(value)).
		Msg("Processing KV config update")

	// Calculate hash of the incoming config to detect changes
	configHash := sha256.Sum256(value)

	// Check if we've already processed this exact configuration
	s.mu.Lock()

	if s.lastConfigHash == configHash {
		s.mu.Unlock()
		s.logger.Debug().Msg("Configuration unchanged, skipping processing")

		return
	}

	s.mu.Unlock()

	// First check if this is a metadata file indicating chunked config
	var metadataCheck map[string]interface{}

	if err := json.Unmarshal(value, &metadataCheck); err != nil {
		s.logger.Error().Err(err).Str("configKey", s.configKey).Msg("Failed to unmarshal config")

		return
	}

	// Check if this is a metadata file with chunk information
	if chunkCount, exists := metadataCheck["chunk_count"]; exists {
		// For chunked config, also check timestamp
		timestamp, timestampExists := metadataCheck["timestamp"].(string)
		if timestampExists {
			s.mu.Lock()
			if s.lastConfigTimestamp == timestamp {
				s.mu.Unlock()
				s.logger.Debug().
					Str("timestamp", timestamp).
					Msg("Chunked configuration timestamp unchanged, skipping processing")

				return
			}

			s.lastConfigTimestamp = timestamp
			s.mu.Unlock()
		}

		s.logger.Info().
			Int("chunkCount", int(chunkCount.(float64))).
			Str("timestamp", timestamp).
			Msg("Detected new chunked sweep config, reading chunks")

		s.processChunkedConfig(metadataCheck)

		// Update hash after successful processing
		s.mu.Lock()
		s.lastConfigHash = configHash
		s.mu.Unlock()

		return
	}

	s.logger.Debug().Msg("Processing as single config file")

	// Process as single file (legacy format)
	s.processSingleConfig(value, configHash)
}

// processSingleConfig handles the original single-file config format
func (s *NetworkSweeper) processSingleConfig(value []byte, configHash [32]byte) {
	var temp unmarshalConfig
	if err := json.Unmarshal(value, &temp); err != nil {
		s.logger.Error().Err(err).Str("configKey", s.configKey).Msg("Failed to unmarshal single config")
		return
	}

	newConfig := s.createConfigFromUnmarshal(&temp)

	if err := s.UpdateConfig(&newConfig); err != nil {
		s.logger.Error().Err(err).Msg("Failed to apply single config update")
	} else {
		// Update hash after successful processing
		s.mu.Lock()
		s.lastConfigHash = configHash
		s.mu.Unlock()

		s.logger.Info().
			Int("networks", len(newConfig.Networks)).
			Int("deviceTargets", len(newConfig.DeviceTargets)).
			Msg("Successfully updated sweep config from single KV file")
	}
}

// processChunkedConfig handles the new chunked config format
func (s *NetworkSweeper) processChunkedConfig(metadata map[string]interface{}) {
	if s.kvStore == nil {
		s.logger.Error().Msg("KV store is nil, cannot read chunked config")
		return
	}

	chunkCount, ok := s.extractChunkCount(metadata)
	if !ok {
		return
	}

	baseConfig, combinedNetworks, combinedDeviceTargets, ok := s.readAndParseChunks(chunkCount)
	if !ok {
		return
	}

	s.applyChunkedConfig(&baseConfig, combinedNetworks, combinedDeviceTargets, chunkCount)
}

// extractChunkCount extracts and validates chunk count from metadata
func (s *NetworkSweeper) extractChunkCount(metadata map[string]interface{}) (int, bool) {
	chunkCountFloat, ok := metadata["chunk_count"].(float64)
	if !ok {
		s.logger.Error().Msg("Invalid chunk_count in metadata")
		return 0, false
	}

	chunkCount := int(chunkCountFloat)
	s.logger.Info().
		Int("chunkCount", chunkCount).
		Str("baseConfigKey", s.getBaseConfigKey()).
		Msg("Reading chunked sweep configuration")

	return chunkCount, true
}

// chunkResult holds the result of reading and parsing a single chunk
type chunkResult struct {
	config unmarshalConfig
	index  int
	err    error
}

// readAndParseChunks reads all chunks in parallel and combines their data
func (s *NetworkSweeper) readAndParseChunks(chunkCount int) (unmarshalConfig, []string, []models.DeviceTarget, bool) {
	// Pre-allocate slices with estimated capacity to reduce allocations
	const estimatedDevicesPerChunk = 1000 // Adjust based on your chunk size
	estimatedTotalDevices := chunkCount * estimatedDevicesPerChunk
	
	combinedNetworks := make([]string, 0, estimatedTotalDevices)
	combinedDeviceTargets := make([]models.DeviceTarget, 0, estimatedTotalDevices)

	var baseConfig unmarshalConfig
	var configSet bool

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second) // Increased timeout for parallel processing
	defer cancel()

	// Use buffered channel to collect results
	results := make(chan chunkResult, chunkCount)
	var wg sync.WaitGroup

	// Start time for performance logging
	startTime := time.Now()

	// Launch parallel workers to read chunks
	workerCount := min(chunkCount, 10) // Limit concurrent KV operations to prevent overwhelming the store
	chunkJobs := make(chan int, chunkCount)

	// Start workers
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for chunkIndex := range chunkJobs {
				chunkKey := fmt.Sprintf("%s_chunk_%d.json", s.getBaseConfigKey(), chunkIndex)
				
				chunkConfig, ok := s.readSingleChunk(ctx, chunkKey, chunkIndex)
				if ok {
					results <- chunkResult{
						config: chunkConfig,
						index:  chunkIndex,
						err:    nil,
					}
				} else {
					results <- chunkResult{
						index: chunkIndex,
						err:   fmt.Errorf("failed to read chunk %d", chunkIndex),
					}
				}
			}
		}()
	}

	// Send jobs to workers
	go func() {
		defer close(chunkJobs)
		for i := 0; i < chunkCount; i++ {
			select {
			case chunkJobs <- i:
			case <-ctx.Done():
				return
			}
		}
	}()

	// Close results channel when all workers are done
	go func() {
		wg.Wait()
		close(results)
	}()

	// Collect results and sort by index to maintain order
	chunkConfigs := make([]unmarshalConfig, chunkCount)
	validChunks := make([]bool, chunkCount)
	successCount := 0

	for result := range results {
		if result.err == nil {
			chunkConfigs[result.index] = result.config
			validChunks[result.index] = true
			successCount++
		} else {
			s.logger.Warn().
				Err(result.err).
				Int("chunkIndex", result.index).
				Msg("Failed to read chunk")
		}
	}

	if successCount == 0 {
		s.logger.Error().
			Int("chunkCount", chunkCount).
			Dur("duration", time.Since(startTime)).
			Msg("No valid chunks found")
		return unmarshalConfig{}, nil, nil, false
	}

	// Combine results in order
	for i := 0; i < chunkCount; i++ {
		if !validChunks[i] {
			continue
		}

		chunkConfig := chunkConfigs[i]

		// Use first valid chunk for base configuration
		if !configSet {
			baseConfig = chunkConfig
			configSet = true
		}

		// Accumulate networks and device targets
		combinedNetworks = append(combinedNetworks, chunkConfig.Networks...)
		combinedDeviceTargets = append(combinedDeviceTargets, chunkConfig.DeviceTargets...)

		s.logger.Debug().
			Int("chunkIndex", i).
			Int("networks", len(chunkConfig.Networks)).
			Int("deviceTargets", len(chunkConfig.DeviceTargets)).
			Int("totalNetworks", len(combinedNetworks)).
			Int("totalDeviceTargets", len(combinedDeviceTargets)).
			Msg("Combined config chunk")
	}

	s.logger.Info().
		Int("chunkCount", chunkCount).
		Int("successCount", successCount).
		Int("totalNetworks", len(combinedNetworks)).
		Int("totalDeviceTargets", len(combinedDeviceTargets)).
		Dur("duration", time.Since(startTime)).
		Msg("Parallel chunk processing completed")

	return baseConfig, combinedNetworks, combinedDeviceTargets, true
}

// readSingleChunk reads and parses a single chunk
func (s *NetworkSweeper) readSingleChunk(ctx context.Context, chunkKey string, chunkIndex int) (unmarshalConfig, bool) {
	s.logger.Debug().Str("chunkKey", chunkKey).Int("chunkIndex", chunkIndex).Msg("Reading config chunk")

	chunkData, found, err := s.kvStore.Get(ctx, chunkKey)
	if err != nil {
		s.logger.Error().Err(err).Str("chunkKey", chunkKey).Msg("Failed to get chunk data")
		return unmarshalConfig{}, false
	}

	if !found {
		s.logger.Warn().Str("chunkKey", chunkKey).Msg("Chunk data not found")
		return unmarshalConfig{}, false
	}

	if len(chunkData) == 0 {
		s.logger.Warn().Str("chunkKey", chunkKey).Msg("Empty chunk data")
		return unmarshalConfig{}, false
	}

	s.logger.Debug().Str("chunkKey", chunkKey).Int("dataLength", len(chunkData)).Msg("Successfully retrieved chunk data")

	var chunkConfig unmarshalConfig
	if err := json.Unmarshal(chunkData, &chunkConfig); err != nil {
		s.logger.Error().Err(err).Str("chunkKey", chunkKey).Msg("Failed to unmarshal chunk config")
		return unmarshalConfig{}, false
	}

	return chunkConfig, true
}

// applyChunkedConfig creates and applies the final combined configuration
func (s *NetworkSweeper) applyChunkedConfig(
	baseConfig *unmarshalConfig,
	combinedNetworks []string,
	combinedDeviceTargets []models.DeviceTarget,
	chunkCount int,
) {
	baseConfig.Networks = combinedNetworks
	baseConfig.DeviceTargets = combinedDeviceTargets

	s.logger.Debug().
		Int("totalChunks", chunkCount).
		Int("totalNetworks", len(combinedNetworks)).
		Int("totalDeviceTargets", len(combinedDeviceTargets)).
		Msg("Successfully assembled chunked sweep configuration")

	newConfig := s.createConfigFromUnmarshal(baseConfig)
	
	// Apply adaptive configuration based on target count
	s.applyAdaptiveConfiguration(&newConfig, combinedNetworks, combinedDeviceTargets)

	if err := s.UpdateConfig(&newConfig); err != nil {
		s.logger.Error().Err(err).Msg("Failed to apply chunked config update")
	} else {
		s.logger.Debug().
			Int("totalChunks", chunkCount).
			Int("networks", len(newConfig.Networks)).
			Int("deviceTargets", len(newConfig.DeviceTargets)).
			Int("adaptedConcurrency", newConfig.Concurrency).
			Int("adaptedICMPRateLimit", newConfig.ICMPRateLimit).
			Msg("Successfully updated sweep config from chunked KV data with adaptive settings")
	}
}

// applyAdaptiveConfiguration adjusts configuration parameters based on target count
func (s *NetworkSweeper) applyAdaptiveConfiguration(
	config *models.Config,
	networks []string,
	deviceTargets []models.DeviceTarget,
) {
	// Calculate total targets for adaptive scaling
	totalDeviceTargets := len(deviceTargets)
	totalNetworkHosts := s.estimateNetworkHosts(networks)
	totalPorts := len(config.Ports)
	
	// Estimate total scanning targets
	totalTargets := (totalDeviceTargets + totalNetworkHosts) * totalPorts
	
	s.logger.Info().
		Int("deviceTargets", totalDeviceTargets).
		Int("networkHosts", totalNetworkHosts).
		Int("ports", totalPorts).
		Int("estimatedTotalTargets", totalTargets).
		Msg("Calculating adaptive configuration based on target count")
	
	// Define scaling tiers based on target count
	switch {
	case totalTargets <= 100: // Small deployment (< 100 targets)
		s.applySmallScaleConfig(config, totalTargets)
	case totalTargets <= 10000: // Medium deployment (100 - 10k targets)  
		s.applyMediumScaleConfig(config, totalTargets)
	case totalTargets <= 100000: // Large deployment (10k - 100k targets)
		s.applyLargeScaleConfig(config, totalTargets)
	default: // Extra large deployment (> 100k targets)
		s.applyExtraLargeScaleConfig(config, totalTargets)
	}
}

// estimateNetworkHosts estimates the number of hosts from network CIDR blocks
func (s *NetworkSweeper) estimateNetworkHosts(networks []string) int {
	totalHosts := 0
	for _, network := range networks {
		// Simple CIDR parsing to estimate host count
		if strings.Contains(network, "/32") {
			totalHosts += 1 // Single host
		} else if strings.Contains(network, "/31") {
			totalHosts += 2
		} else if strings.Contains(network, "/30") {
			totalHosts += 4
		} else if strings.Contains(network, "/24") {
			totalHosts += 254 // Standard /24 subnet
		} else if strings.Contains(network, "/16") {
			totalHosts += 65534 // /16 network
		} else {
			// Default estimate for unknown CIDR - assume /24
			totalHosts += 254
		}
	}
	return totalHosts
}

// applySmallScaleConfig optimizes for small deployments (< 100 targets)
func (s *NetworkSweeper) applySmallScaleConfig(config *models.Config, totalTargets int) {
	config.Concurrency = min(8, totalTargets) // Very low concurrency
	config.ICMPRateLimit = min(100, totalTargets*2) // Conservative rate limiting
	config.ICMPSettings.RateLimit = min(50, totalTargets)
	config.ICMPSettings.MaxBatch = min(8, totalTargets)
	config.TCPSettings.Concurrency = min(8, totalTargets)
	config.TCPSettings.MaxBatch = min(8, totalTargets)
	config.TCPSettings.GlobalRingMemoryMB = 4 // Minimal memory usage
	config.TCPSettings.RingReaders = 1
	config.TCPSettings.RingPollTimeoutMs = 100
	
	s.logger.Info().
		Int("totalTargets", totalTargets).
		Int("concurrency", config.Concurrency).
		Int("icmpRateLimit", config.ICMPRateLimit).
		Msg("Applied small-scale adaptive configuration")
}

// applyMediumScaleConfig optimizes for medium deployments (100 - 10k targets)
func (s *NetworkSweeper) applyMediumScaleConfig(config *models.Config, totalTargets int) {
	config.Concurrency = min(64, totalTargets/10) // Moderate concurrency
	config.ICMPRateLimit = min(1000, totalTargets/2)
	config.ICMPSettings.RateLimit = min(500, totalTargets/5)
	config.ICMPSettings.MaxBatch = min(32, totalTargets/20)
	config.TCPSettings.Concurrency = min(64, totalTargets/10)
	config.TCPSettings.MaxBatch = min(32, totalTargets/20)
	config.TCPSettings.GlobalRingMemoryMB = min(32, totalTargets/200) // Scale memory with targets
	config.TCPSettings.RingReaders = min(2, totalTargets/1000)
	config.TCPSettings.RingPollTimeoutMs = 50
	
	s.logger.Info().
		Int("totalTargets", totalTargets).
		Int("concurrency", config.Concurrency).
		Int("icmpRateLimit", config.ICMPRateLimit).
		Msg("Applied medium-scale adaptive configuration")
}

// applyLargeScaleConfig optimizes for large deployments (10k - 100k targets)
func (s *NetworkSweeper) applyLargeScaleConfig(config *models.Config, totalTargets int) {
	config.Concurrency = min(512, totalTargets/50) // High concurrency
	config.ICMPRateLimit = min(5000, totalTargets/10)
	config.ICMPSettings.RateLimit = min(2500, totalTargets/20)
	config.ICMPSettings.MaxBatch = min(64, totalTargets/100)
	config.TCPSettings.Concurrency = min(512, totalTargets/50)
	config.TCPSettings.MaxBatch = min(64, totalTargets/100)
	config.TCPSettings.GlobalRingMemoryMB = min(128, totalTargets/500) // More memory for large scale
	config.TCPSettings.RingReaders = min(4, totalTargets/5000)
	config.TCPSettings.RingPollTimeoutMs = 25
	
	s.logger.Info().
		Int("totalTargets", totalTargets).
		Int("concurrency", config.Concurrency).
		Int("icmpRateLimit", config.ICMPRateLimit).
		Msg("Applied large-scale adaptive configuration")
}

// applyExtraLargeScaleConfig optimizes for extra large deployments (> 100k targets)
func (s *NetworkSweeper) applyExtraLargeScaleConfig(config *models.Config, totalTargets int) {
	config.Concurrency = min(1024, totalTargets/100) // Maximum concurrency
	config.ICMPRateLimit = min(10000, totalTargets/20)
	config.ICMPSettings.RateLimit = min(5000, totalTargets/50)
	config.ICMPSettings.MaxBatch = min(128, totalTargets/500)
	config.TCPSettings.Concurrency = min(1024, totalTargets/100)
	config.TCPSettings.MaxBatch = min(128, totalTargets/500)
	config.TCPSettings.GlobalRingMemoryMB = min(256, totalTargets/1000) // Maximum memory allocation
	config.TCPSettings.RingReaders = min(8, totalTargets/10000)
	config.TCPSettings.RingPollTimeoutMs = 10 // Most aggressive polling
	
	s.logger.Info().
		Int("totalTargets", totalTargets).
		Int("concurrency", config.Concurrency).
		Int("icmpRateLimit", config.ICMPRateLimit).
		Msg("Applied extra-large-scale adaptive configuration")
}


// getBaseConfigKey extracts the base config key without the file extension
func (s *NetworkSweeper) getBaseConfigKey() string {
	// Remove .json extension if present
	baseKey := s.configKey
	if len(baseKey) > 5 && baseKey[len(baseKey)-5:] == ".json" {
		baseKey = baseKey[:len(baseKey)-5]
	}

	return baseKey
}

// createConfigFromUnmarshal creates a models.Config from the unmarshaled data
func (*NetworkSweeper) createConfigFromUnmarshal(temp *unmarshalConfig) models.Config {
	return models.Config{
		Networks:      temp.Networks,
		Ports:         temp.Ports,
		SweepModes:    temp.SweepModes,
		DeviceTargets: temp.DeviceTargets,
		Interval:      time.Duration(temp.Interval),
		Concurrency:   temp.Concurrency,
		Timeout:       time.Duration(temp.Timeout),
		ICMPCount:     temp.ICMPCount,
		MaxIdle:       temp.MaxIdle,
		MaxLifetime:   time.Duration(temp.MaxLifetime),
		IdleTimeout:   time.Duration(temp.IdleTimeout),
		ICMPSettings: struct {
			RateLimit int
			Timeout   time.Duration
			MaxBatch  int
		}{
			RateLimit: temp.ICMPSettings.RateLimit,
			Timeout:   time.Duration(temp.ICMPSettings.Timeout),
			MaxBatch:  temp.ICMPSettings.MaxBatch,
		},
		TCPSettings: struct {
			Concurrency        int
			Timeout            time.Duration
			MaxBatch           int
			RouteDiscoveryHost string `json:"route_discovery_host,omitempty"`

			// Ring buffer tuning for SYN scanner memory vs performance tradeoffs
			RingBlockSize  int `json:"ring_block_size,omitempty"`  // Block size in bytes (default: 1MB, max: 8MB)
			RingBlockCount int `json:"ring_block_count,omitempty"` // Number of blocks (default: 8, max: 32, total max: 64MB)

			// Network interface selection for multi-homed hosts
			Interface string `json:"interface,omitempty"` // Network interface (e.g., "eth0", "wlan0") - auto-detected if empty

			// Advanced NAT/firewall compatibility options
			SuppressRSTReply bool `json:"suppress_rst_reply,omitempty"` // Suppress RST packet generation (optional)

			// Global ring buffer memory cap (in MB) to be distributed across all CPU cores
			GlobalRingMemoryMB int `json:"global_ring_memory_mb,omitempty"`

			// Ring readers and poll timeout tuning
			RingReaders       int `json:"ring_readers,omitempty"`
			RingPollTimeoutMs int `json:"ring_poll_timeout_ms,omitempty"`
		}{
			Concurrency:        temp.TCPSettings.Concurrency,
			Timeout:            time.Duration(temp.TCPSettings.Timeout),
			MaxBatch:           temp.TCPSettings.MaxBatch,
			RouteDiscoveryHost: temp.TCPSettings.RouteDiscoveryHost,
			RingBlockSize:      temp.TCPSettings.RingBlockSize,
			RingBlockCount:     temp.TCPSettings.RingBlockCount,
			Interface:          temp.TCPSettings.Interface,
			SuppressRSTReply:   temp.TCPSettings.SuppressRSTReply,
			GlobalRingMemoryMB: temp.TCPSettings.GlobalRingMemoryMB,
			RingReaders:        temp.TCPSettings.RingReaders,
			RingPollTimeoutMs:  temp.TCPSettings.RingPollTimeoutMs,
		},
		EnableHighPerformanceICMP: temp.EnableHighPerformanceICMP,
		ICMPRateLimit:             temp.ICMPRateLimit,
	}
}

// estimateTargetCount calculates the total number of targets.
// Includes both global networks/modes and device-specific targets.
func estimateTargetCount(config *models.Config) int {
	total := 0

	// Count targets from global networks and sweep modes
	for _, network := range config.Networks {
		ips, err := scan.ExpandCIDR(network)
		if err != nil {
			continue
		}

		if containsMode(config.SweepModes, models.ModeICMP) {
			total += len(ips)
		}

		if containsMode(config.SweepModes, models.ModeTCP) {
			total += len(ips) * len(config.Ports)
		}
	}

	// Count targets from device-specific configurations
	for _, deviceTarget := range config.DeviceTargets {
		ips, err := scan.ExpandCIDR(deviceTarget.Network)
		if err != nil {
			continue
		}

		// Use device-specific sweep modes if available, otherwise fall back to global
		sweepModes := deviceTarget.SweepModes
		if len(sweepModes) == 0 {
			sweepModes = config.SweepModes
		}

		if containsMode(sweepModes, models.ModeICMP) {
			total += len(ips)
		}

		if containsMode(sweepModes, models.ModeTCP) {
			// DeviceTarget doesn't have its own ports, use global ports
			total += len(ips) * len(config.Ports)
		}
	}

	return total
}

// scanAndProcess runs a scan and processes its results.
func (s *NetworkSweeper) scanAndProcess(ctx context.Context, wg *sync.WaitGroup,
	scanner scan.Scanner, targets []models.Target, scanType string) error {
	defer wg.Done()

	s.logger.Debug().Str("scanType", scanType).Msg("Running scan")

	results, err := scanner.Scan(ctx, targets)
	if err != nil {
		s.logger.Error().Err(err).Str("scanType", scanType).Msg("Scan failed")

		return err
	}

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

			count++
			if result.Available {
				success++
			}

			// Add to batch
			resultBatch = append(resultBatch, result)

			// Process batch when it's full
			if len(resultBatch) >= batchSize {
				if err := s.processBatchedResults(ctx, resultBatch); err != nil {
					s.logger.Error().Err(err).Str("scanType", scanType).Msg("Failed to process result batch")
				}

				// Reset batch slice but keep capacity to avoid reallocation
				resultBatch = resultBatch[:0]


				// Log progress periodically (every batch)
				s.logger.Info().Str("scanType", scanType).Int("processed", count).Int("successful", success).Msg("Scan progress")
			}

		case <-ctx.Done():
			// Timeout reached, process any remaining batch
			if len(resultBatch) > 0 {
				if err := s.processBatchedResults(ctx, resultBatch); err != nil {
					s.logger.Error().Err(err).Str("scanType", scanType).Msg("Failed to process remaining result batch")
				}
			}

			s.logger.Info().Str("scanType", scanType).Int("totalResults", count).Int("successful", success).Msg("Scan complete - timeout reached")
			return nil
		}
	}
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Prepare device result aggregators for multi-IP devices
	s.prepareDeviceAggregators(targets)

	var icmpTargets, tcpTargets []models.Target

	for _, t := range targets {
		switch t.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, t)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, t)
		}
	}

	s.logger.Info().
		Int("icmpTargets", len(icmpTargets)).
		Int("tcpTargets", len(tcpTargets)).
		Bool("icmpScannerAvailable", s.icmpScanner != nil).
		Bool("tcpScannerAvailable", s.tcpScanner != nil).
		Msg("Starting sweep")

	var wg sync.WaitGroup

	errChan := make(chan error, 2) // Buffer for both ICMP and TCP errors

	if len(icmpTargets) > 0 && s.icmpScanner != nil {
		wg.Add(1)

		go func() {
			if err := s.scanAndProcess(ctx, &wg, s.icmpScanner, icmpTargets, "icmp"); err != nil {
				errChan <- err
			}
		}()
		
	} else if len(icmpTargets) > 0 {
		s.logger.Warn().Int("icmpTargets", len(icmpTargets)).Msg("ICMP targets found but ICMP scanner is not available, skipping ICMP scan")
	}

	if len(tcpTargets) > 0 && s.tcpScanner != nil {
		wg.Add(1)

		go func() {
			if err := s.scanAndProcess(ctx, &wg, s.tcpScanner, tcpTargets, "tcp"); err != nil {
				errChan <- err
			}
		}()
	} else if len(tcpTargets) > 0 {
		s.logger.Warn().Int("tcpTargets", len(tcpTargets)).Msg("TCP targets found but TCP scanner is not available, skipping TCP scan")
	}

	wg.Wait()
	close(errChan)

	// Check for any errors
	for err := range errChan {
		return err
	}

	// Finalize and process aggregated device results
	s.finalizeDeviceAggregators(ctx)

	s.logger.Info().Msg("Sweep completed successfully")

	return nil
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

// extractAgentInfo extracts agent/poller/partition information from config and metadata.
func (s *NetworkSweeper) extractAgentInfo(result *models.Result) (agentID, pollerID, partition string) {
	// Get agent/poller info from config first, then try metadata
	agentID = defaultName
	pollerID = defaultName
	partition = defaultName

	// Use config values if available
	if s.config.AgentID != "" {
		agentID = s.config.AgentID
	}

	if s.config.PollerID != "" {
		pollerID = s.config.PollerID
	}

	if s.config.Partition != "" {
		partition = s.config.Partition
	}

	// Extract from metadata if available (metadata can override config)
	if result.Target.Metadata != nil {
		if id, ok := result.Target.Metadata["agent_id"].(string); ok && id != "" {
			agentID = id
		}

		if id, ok := result.Target.Metadata["poller_id"].(string); ok && id != "" {
			pollerID = id
		}

		if p, ok := result.Target.Metadata["partition"].(string); ok && p != "" {
			partition = p
		}
	}

	return agentID, pollerID, partition
}

// createDeviceUpdate creates a DeviceUpdate from a Result.
func (*NetworkSweeper) createDeviceUpdate(result *models.Result, agentID, pollerID, partition string) *models.DeviceUpdate {
	// Always generate a valid device ID with partition
	deviceID := fmt.Sprintf("%s:%s", partition, result.Target.Host)

	return &models.DeviceUpdate{
		AgentID:     agentID,
		PollerID:    pollerID,
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
	agentID, pollerID, partition := s.extractAgentInfo(result)
	deviceUpdate := s.createDeviceUpdate(result, agentID, pollerID, partition)

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
	// Check if this device target has multiple IPs specified in metadata
	var targetIPs []string

	if allIPsStr, hasAllIPs := deviceTarget.Metadata["all_ips"]; hasAllIPs {
		// Parse comma-separated list of IPs
		allIPs := strings.Split(allIPsStr, ",")
		for _, ip := range allIPs {
			trimmed := strings.TrimSpace(ip)
			if trimmed != "" {
				targetIPs = append(targetIPs, trimmed)
			}
		}

		s.logger.Debug().
			Str("device_target", deviceTarget.Network).
			Strs("all_ips", targetIPs).
			Str("armis_device_id", deviceTarget.Metadata["armis_device_id"]).
			Msg("Device target has multiple IPs - will scan all of them")
	} else {
		// Fall back to expanding the CIDR normally
		ips, err := scan.ExpandCIDR(deviceTarget.Network)
		if err != nil {
			s.logger.Warn().
				Err(err).
				Str("network", deviceTarget.Network).
				Str("query_label", deviceTarget.QueryLabel).
				Msg("Failed to expand device target CIDR, skipping")

			return targets, hostCount
		}

		targetIPs = ips
	}

	metadata := map[string]interface{}{
		"network":     deviceTarget.Network,
		"total_hosts": len(targetIPs),
		"source":      deviceTarget.Source,
		"query_label": deviceTarget.QueryLabel,
	}

	// Add device target metadata to the scan metadata
	for k, v := range deviceTarget.Metadata {
		metadata[k] = v
	}

	// Use device-specific sweep modes if available, otherwise fall back to global
	sweepModes := deviceTarget.SweepModes
	if len(sweepModes) == 0 {
		s.logger.Debug().
			Str("device", deviceTarget.Network).
			Msg("Device target has no sweep modes, using global config")

		sweepModes = s.config.SweepModes
	}

	s.logger.Debug().
		Str("device", deviceTarget.Network).
		Strs("sweep_modes", func() []string {
			modes := []string{}
			for _, m := range sweepModes {
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

// createTargetsForIP creates targets for a specific IP using the given sweep modes
func (s *NetworkSweeper) createTargetsForIP(ip string, sweepModes []models.SweepMode, metadata map[string]interface{}) []models.Target {
	var targets []models.Target

	if containsMode(sweepModes, models.ModeICMP) {
		target := scan.TargetFromIP(ip, models.ModeICMP)
		target.Metadata = metadata
		targets = append(targets, target)
	}

	if containsMode(sweepModes, models.ModeTCP) {
		for _, port := range s.config.Ports {
			target := scan.TargetFromIP(ip, models.ModeTCP, port)
			target.Metadata = metadata
			targets = append(targets, target)
		}
	}

	return targets
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
			modes := []string{}
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

	// Log batch processing statistics for errors or periodically for large batches
	if errors > 0 || len(batch) >= 1000 {
		s.logger.Info().
			Int("batchSize", len(batch)).
			Int("errors", errors).
			Int("aggregated", aggregated).
			Int("deviceRegistryUpdates", deviceRegistryUpdates).
			Msg("Batch result processing completed")
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

		var expectedIPs []string
		for _, t := range targets {
			expectedIPs = append(expectedIPs, t.Host)
		}

		agentID, pollerID, partition := s.extractAgentInfoFromMetadata(deviceMetadata[deviceID])

		s.deviceResults[deviceID] = &DeviceResultAggregator{
			DeviceID:    deviceID,
			Results:     make([]*models.Result, 0, len(targets)),
			ExpectedIPs: expectedIPs,
			Metadata:    deviceMetadata[deviceID],
			AgentID:     agentID,
			PollerID:    pollerID,
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
func (s *NetworkSweeper) extractAgentInfoFromMetadata(metadata map[string]interface{}) (agentID, pollerID, partition string) {
	agentID = defaultName
	pollerID = defaultName
	partition = defaultName

	if s.config.AgentID != "" {
		agentID = s.config.AgentID
	}

	if s.config.PollerID != "" {
		pollerID = s.config.PollerID
	}

	if s.config.Partition != "" {
		partition = s.config.Partition
	}

	if metadata != nil {
		if id, ok := metadata["agent_id"].(string); ok && id != "" {
			agentID = id
		}

		if id, ok := metadata["poller_id"].(string); ok && id != "" {
			pollerID = id
		}

		if p, ok := metadata["partition"].(string); ok && p != "" {
			partition = p
		}
	}

	return agentID, pollerID, partition
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
		PollerID:    aggregator.PollerID,
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
	// For very large result sets, avoid building heavy string metadata to reduce CPU and GC pressure.
	const aggDetailThreshold = 100 // keep tests with small sets passing; production large sets skip details

	total := len(results)
	if total == 0 {
		deviceUpdate.Metadata["scan_result_count"] = "0"
		deviceUpdate.Metadata["scan_available_count"] = "0"
		deviceUpdate.Metadata["scan_unavailable_count"] = "0"
		deviceUpdate.Metadata["scan_availability_percent"] = "0.0"
		deviceUpdate.IsAvailable = false

		return
	}

	if total > aggDetailThreshold {
		// Counts only path
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

		return
	}

	// Detailed path for small sets (retains existing behavior for tests and small batches)
	// Use strings.Builder for efficient string concatenation
	var allIPsBuilder, availableIPsBuilder, unavailableIPsBuilder strings.Builder
	var icmpResultsBuilder, tcpResultsBuilder strings.Builder
	
	// Pre-allocate builders with estimated capacity to reduce allocations
	// Estimate: average IP length ~12 bytes, + separator = 13 bytes per IP
	allIPsBuilder.Grow(total * 13)
	availableIPsBuilder.Grow(total * 13 / 2) // Assume ~50% available
	unavailableIPsBuilder.Grow(total * 13 / 2) // Assume ~50% unavailable
	
	// For scan details, estimate ~60 bytes per result
	icmpResultsBuilder.Grow(total * 60 / 2) // Assume ~50% ICMP
	tcpResultsBuilder.Grow(total * 60 / 2)  // Assume ~50% TCP

	availableCount := 0
	firstIP := true
	firstAvailable := true
	firstUnavailable := true
	firstICMP := true
	firstTCP := true

	for _, result := range results {
		// Build all IPs list
		if !firstIP {
			allIPsBuilder.WriteByte(',')
		}
		allIPsBuilder.WriteString(result.Target.Host)
		firstIP = false

		if result.Available {
			availableCount++
			// Build available IPs list
			if !firstAvailable {
				availableIPsBuilder.WriteByte(',')
			}
			availableIPsBuilder.WriteString(result.Target.Host)
			firstAvailable = false
		} else {
			// Build unavailable IPs list
			if !firstUnavailable {
				unavailableIPsBuilder.WriteByte(',')
			}
			unavailableIPsBuilder.WriteString(result.Target.Host)
			firstUnavailable = false
		}

		// Build scan detail strings more efficiently
		switch result.Target.Mode {
		case models.ModeICMP:
			if !firstICMP {
				icmpResultsBuilder.WriteByte(';')
			}
			// Use more efficient string building
			icmpResultsBuilder.WriteString(result.Target.Host)
			icmpResultsBuilder.WriteString(":icmp:available=")
			if result.Available {
				icmpResultsBuilder.WriteString("true")
			} else {
				icmpResultsBuilder.WriteString("false")
			}
			icmpResultsBuilder.WriteString(":response_time=")
			icmpResultsBuilder.WriteString(result.RespTime.String())
			icmpResultsBuilder.WriteString(":packet_loss=")
			icmpResultsBuilder.WriteString(fmt.Sprintf("%.2f", result.PacketLoss))
			firstICMP = false
		case models.ModeTCP:
			if !firstTCP {
				tcpResultsBuilder.WriteByte(';')
			}
			tcpResultsBuilder.WriteString(result.Target.Host)
			tcpResultsBuilder.WriteString(":tcp:available=")
			if result.Available {
				tcpResultsBuilder.WriteString("true")
			} else {
				tcpResultsBuilder.WriteString("false")
			}
			tcpResultsBuilder.WriteString(":response_time=")
			tcpResultsBuilder.WriteString(result.RespTime.String())
			tcpResultsBuilder.WriteString(":packet_loss=")
			tcpResultsBuilder.WriteString(fmt.Sprintf("%.2f", result.PacketLoss))
			firstTCP = false
		}
	}

	// Assign the built strings to metadata
	deviceUpdate.Metadata["scan_all_ips"] = allIPsBuilder.String()
	deviceUpdate.Metadata["scan_available_ips"] = availableIPsBuilder.String()
	deviceUpdate.Metadata["scan_unavailable_ips"] = unavailableIPsBuilder.String()
	deviceUpdate.Metadata["scan_result_count"] = fmt.Sprintf("%d", total)
	deviceUpdate.Metadata["scan_available_count"] = fmt.Sprintf("%d", availableCount)
	deviceUpdate.Metadata["scan_unavailable_count"] = fmt.Sprintf("%d", total-availableCount)

	if icmpResultsBuilder.Len() > 0 {
		deviceUpdate.Metadata["scan_icmp_results"] = icmpResultsBuilder.String()
	}

	if tcpResultsBuilder.Len() > 0 {
		deviceUpdate.Metadata["scan_tcp_results"] = tcpResultsBuilder.String()
	}

	deviceUpdate.Metadata["scan_availability_percent"] = fmt.Sprintf("%.1f", float64(availableCount)/float64(total)*100)
	deviceUpdate.IsAvailable = availableCount > 0
}
