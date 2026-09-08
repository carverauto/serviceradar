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
	"net"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
)

// Option configures a NetworkSweeper instance.
type Option func(*NetworkSweeper)

// BannerObservationHandler consumes successful active banner observations.
type BannerObservationHandler func(context.Context, models.BannerGrab, *banner_grab.Engine, <-chan banner_grab.BannerObservation) error

// WithBannerObservationHandler wires banner observations to the agent-owned
// netprobe IPC batcher. When unset, the sweeper drains observations and logs
// counters so enabling banner grab cannot block the scan path.
func WithBannerObservationHandler(handler BannerObservationHandler) Option {
	return func(s *NetworkSweeper) {
		s.bannerHandler = handler
	}
}

const (
	defaultInterval      = 5 * time.Minute
	scanTimeout          = 20 * time.Minute // Timeout for individual scan operations - increased for large-scale TCP scanning
	defaultResultTimeout = 500 * time.Millisecond
	defaultTargetBatch   = 100000
	intSizeBits          = 32 << (^uint(0) >> 63)
	maxInt               = int(^uint(0) >> 1)
)

const (
	metadataAddressFamily        = "address_family"
	metadataIPv6RawSYNFallback   = "ipv6_raw_syn_fallback"
	addressFamilyIPv4            = "ipv4"
	addressFamilyIPv6            = "ipv6"
	addressFamilyDualStack       = "dual_stack"
	addressFamilyUnknown         = "unknown"
	scannerProtocolTCP           = "tcp"
	scannerPathRawSYN            = "raw_syn"
	scannerPathTCPConnect        = "tcp_connect"
	scannerPathTCPConnectIPv6SYN = "tcp_connect_ipv6_raw_syn_fallback"
)

// DeviceRegistryService interface for device registry operations
type DeviceRegistryService interface {
	ProcessSweepResult(ctx context.Context, result *models.SweepResult) error
	UpdateDevice(ctx context.Context, update *models.DeviceUpdate) error
	GetDevice(ctx context.Context, deviceID string) (*models.OCSFDevice, error)
	GetDevicesByIP(ctx context.Context, ip string) ([]*models.OCSFDevice, error)
	ListDevices(ctx context.Context, limit, offset int) ([]*models.OCSFDevice, error)
}

var (
	errNilConfig        = errors.New("config cannot be nil")
	errIPv6CIDRTooLarge = errors.New("IPv6 CIDR expands above target batch limit")
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
	deviceRegistry DeviceRegistryService,
	log logger.Logger,
	opts ...Option) (*NetworkSweeper, error) {
	if config == nil {
		return nil, errNilConfig
	}

	icmpScanner := initializeICMPScanner(config, log)
	tcpScanner := initializeTCPScanner(config, log)
	tcpConnectScanner := initializeTCPConnectScanner(config, log)

	// Default interval if not set
	if config.Interval == 0 {
		config.Interval = defaultInterval
	}

	log.Info().Dur("interval", config.Interval).Msg("Creating NetworkSweeper")

	ns := &NetworkSweeper{
		config:            config,
		icmpScanner:       icmpScanner,
		tcpScanner:        tcpScanner,
		tcpConnectScanner: tcpConnectScanner,
		store:             store,
		processor:         processor,
		deviceRegistry:    deviceRegistry,
		logger:            log,
		done:              nil,
		deviceResults:     make(map[string]*DeviceResultAggregator),
		tickerReset:       make(chan struct{}, 1),
	}

	ns.ensureControlChannels()

	for _, opt := range opts {
		opt(ns)
	}

	return ns, nil
}

// initializeICMPScanner creates an ICMP scanner if needed based on config
func initializeICMPScanner(config *models.Config, log logger.Logger) scan.Scanner {
	if !needsICMPScanning(config) {
		return nil
	}

	// Build options for ICMP scanner
	var opts []scan.ICMPSweeperOption
	if config.ICMPCount > 0 {
		opts = append(opts, scan.WithICMPCount(config.ICMPCount))
	}

	icmpScanner, err := scan.NewICMPSweeper(config.Timeout, config.ICMPRateLimit, log, opts...)
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

// needsTCPScanning checks if raw TCP SYN scanning is needed based on config.
func needsTCPScanning(config *models.Config) bool {
	// Check global sweep modes
	for _, mode := range config.SweepModes {
		if mode == models.ModeTCP {
			return true
		}
	}

	// Check device target sweep modes
	for _, deviceTarget := range config.DeviceTargets {
		for _, mode := range deviceTarget.SweepModes {
			if mode == models.ModeTCP {
				return true
			}
		}
	}

	return false
}

// needsTCPConnectScanning checks if TCP connect scanning is needed based on config
func needsTCPConnectScanning(config *models.Config) bool {
	// Check global sweep modes
	for _, mode := range config.SweepModes {
		if mode == models.ModeTCPConnect {
			return true
		}
	}

	// Check device target sweep modes
	for _, deviceTarget := range config.DeviceTargets {
		for _, mode := range deviceTarget.SweepModes {
			if mode == models.ModeTCPConnect {
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
	if !needsTCPScanning(config) {
		return nil
	}

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

	synScanner, synErr := scan.NewSYNScanner(config.TCPSettings.Timeout, synConcurrency, log, opts)
	if synScanner == nil {
		// SYN scanner failed (non-Linux, container without CAP_NET_RAW, etc.)
		// Gracefully fall back to TCP connect() scanner
		log.Warn().Err(synErr).Msg("SYN scanner unavailable; falling back to TCP connect() scanner")
	} else {
		log.Info().Int("concurrency", synConcurrency).Msg("Using SYN scanning for improved TCP port detection performance")
		return synScanner
	}

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

// initializeTCPConnectScanner creates a TCP connect scanner for safe scanning
func initializeTCPConnectScanner(config *models.Config, log logger.Logger) scan.Scanner {
	if !needsTCPConnectScanning(config) {
		return nil
	}

	// Prefer TCP-specific settings if set; otherwise fall back to global settings
	baseTimeout := config.TCPSettings.Timeout
	if baseTimeout == 0 {
		baseTimeout = config.Timeout
	}

	baseConcurrency := config.TCPSettings.Concurrency
	if baseConcurrency <= 0 {
		baseConcurrency = calculateEffectiveConcurrency(config, log)
	}

	// Apply connect scanner concurrency upper bound (more restrictive than SYN)
	connectConcurrency := baseConcurrency
	if connectConcurrency > maxConnectConcurrency {
		connectConcurrency = maxConnectConcurrency
		log.Info().Int("originalConcurrency", baseConcurrency).Int("clampedConcurrency", connectConcurrency).
			Msg("Clamped TCP connect scanner concurrency to prevent resource exhaustion")
	}

	tcpConnectScanner := scan.NewTCPSweeper(baseTimeout, connectConcurrency, log)
	log.Info().Int("concurrency", connectConcurrency).Msg("Using TCP connect() scanning (safe for conntrack)")

	return tcpConnectScanner
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

	oldInterval := s.config.Interval
	s.config = config

	if config.Interval != oldInterval {
		select {
		case s.tickerReset <- struct{}{}:
		default:
			// Signal already pending
		}
	}

	// A group can gain a mode without being recreated. Initialize any newly
	// required scanner while preserving existing scanner instances.
	s.ensureScannersInitializedLocked()

	return nil
}

// estimateTargetCount calculates the total number of targets.
// Includes both global networks/modes and device-specific targets.
func estimateTargetCount(config *models.Config) int {
	total := 0

	// Count targets from global networks and sweep modes
	for _, network := range config.Networks {
		targetCount, err := countCIDRTargets(network, config.SweepModes, len(config.Ports))
		if err != nil {
			continue
		}

		total = saturatingAdd(total, targetCount)
	}

	// Count targets from device-specific configurations
	for _, deviceTarget := range config.DeviceTargets {
		// Use device-specific sweep modes if available, otherwise fall back to global
		sweepModes := deviceTarget.SweepModes
		if len(sweepModes) == 0 {
			sweepModes = config.SweepModes
		}

		targetCount, err := countCIDRTargets(deviceTarget.Network, sweepModes, len(config.Ports))
		if err != nil {
			continue
		}

		total = saturatingAdd(total, targetCount)
	}

	return total
}

func countCIDRTargets(cidr string, sweepModes []models.SweepMode, portCount int) (int, error) {
	hostCount, err := countCIDRHosts(cidr)
	if err != nil {
		return 0, err
	}

	baseIP, _, err := net.ParseCIDR(cidr)
	if err != nil {
		return 0, err
	}

	return countTargetsForHostCount(hostCount, baseIP.To4() == nil, sweepModes, portCount), nil
}

func countTargetsForHostCount(hostCount int, ipv6 bool, sweepModes []models.SweepMode, portCount int) int {
	if hostCount <= 0 {
		return 0
	}

	effectiveModes := effectiveSweepModes(ipv6, sweepModes, false)
	total := 0

	if containsMode(effectiveModes, models.ModeICMP) {
		total = saturatingAdd(total, hostCount)
	}

	if containsMode(effectiveModes, models.ModeTCP) {
		total = saturatingAdd(total, saturatingMul(hostCount, portCount))
	}

	if containsMode(effectiveModes, models.ModeTCPConnect) {
		total = saturatingAdd(total, saturatingMul(hostCount, portCount))
	}

	return total
}

func countCIDRHosts(cidr string) (int, error) {
	ip, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return 0, err
	}

	ones, bits := ipNet.Mask.Size()
	if ones < 0 || bits <= 0 || ones > bits {
		return 0, nil
	}

	hostBits := bits - ones
	count := pow2Saturating(hostBits)

	// Keep parity with scan.ExpandCIDR: for IPv4 CIDRs other than /32, network
	// and broadcast addresses are skipped. This means /31 currently counts as 0.
	if ip.To4() != nil && ones != 32 {
		if count <= 2 {
			return 0, nil
		}

		count -= 2
	}

	return count, nil
}

func pow2Saturating(exp int) int {
	if exp <= 0 {
		return 1
	}

	if exp >= intSizeBits-1 {
		return maxInt
	}

	return 1 << exp
}

func saturatingAdd(a, b int) int {
	if b > maxInt-a {
		return maxInt
	}

	return a + b
}

func saturatingMul(a, b int) int {
	if a == 0 || b == 0 {
		return 0
	}

	if a > maxInt/b {
		return maxInt
	}

	return a * b
}

// StoreOptionsForConfig returns memory store options tuned to the sweep config.
// It avoids large preallocations when there are few or zero targets.
func StoreOptionsForConfig(config *models.Config) []InMemoryStoreOption {
	if config == nil {
		return nil
	}

	targets := estimateTargetCount(config)
	if targets == 0 {
		return []InMemoryStoreOption{WithoutPreallocation()}
	}

	if targets < defaultMaxResults {
		return []InMemoryStoreOption{WithMaxResults(targets)}
	}

	return nil
}
