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
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

const (
	defaultInterval      = 5 * time.Minute
	scanTimeout          = 2 * time.Minute // Timeout for individual scan operations
	defaultResultTimeout = 500 * time.Millisecond
)

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
	mu             sync.RWMutex
	done           chan struct{}
	watchDone      chan struct{}
	lastSweep      time.Time
}

var (
	errNilConfig = fmt.Errorf("config cannot be nil")
)

const (
	defaultTotalTargetLimitPercentage = 10
	defaultEffectiveConcurrency       = 5
)

// NewNetworkSweeper creates a new scanner for network sweeping.
func NewNetworkSweeper(
	config *models.Config,
	store Store,
	processor ResultProcessor,
	kvStore KVStore,
	deviceRegistry DeviceRegistryService,
	configKey string) (*NetworkSweeper, error) {
	if config == nil {
		return nil, errNilConfig
	}

	// Initialize scanners
	icmpScanner, err := scan.NewICMPSweeper(config.Timeout, config.ICMPRateLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	totalTargets := estimateTargetCount(config)
	effectiveConcurrency := config.Concurrency

	if totalTargets > 0 && effectiveConcurrency > totalTargets/10 {
		effectiveConcurrency = totalTargets / defaultTotalTargetLimitPercentage // Limit to 10% of targets
		if effectiveConcurrency < defaultEffectiveConcurrency {
			effectiveConcurrency = defaultEffectiveConcurrency // Minimum concurrency
		}

		log.Printf("Adjusted concurrency to %d for %d targets", effectiveConcurrency, totalTargets)
	}

	tcpScanner := scan.NewTCPSweeper(config.Timeout, effectiveConcurrency)

	// Default interval if not set
	if config.Interval == 0 {
		config.Interval = defaultInterval
	}

	log.Printf("Creating NetworkSweeper with interval: %v", config.Interval)

	return &NetworkSweeper{
		config:         config,
		icmpScanner:    icmpScanner,
		tcpScanner:     tcpScanner,
		store:          store,
		processor:      processor,
		kvStore:        kvStore,
		deviceRegistry: deviceRegistry,
		configKey:      configKey,
		done:           make(chan struct{}),
		watchDone:      make(chan struct{}),
	}, nil
}

// Start begins periodic sweeping and KV watching.
func (s *NetworkSweeper) Start(ctx context.Context) error {
	log.Printf("Starting network sweeper with interval %v", s.config.Interval)

	// Start KV config watching in a goroutine
	go s.watchConfig(ctx)

	initialCtx, initialCancel := context.WithTimeout(ctx, scanTimeout)
	if err := s.runSweep(initialCtx); err != nil {
		initialCancel()

		log.Printf("Initial sweep failed: %v", err)
	} else {
		log.Printf("Initial sweep completed successfully")
	}

	initialCancel()

	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	log.Printf("Entering sweep loop with interval %v", s.config.Interval)

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping sweeper")

			return ctx.Err()
		case <-s.done:
			log.Printf("Received done signal, stopping sweeper")

			return nil
		case t := <-ticker.C:
			log.Printf("Ticker fired at %v, starting periodic sweep", t.Format(time.RFC3339))

			sweepCtx, sweepCancel := context.WithTimeout(ctx, scanTimeout)
			if err := s.runSweep(sweepCtx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			} else {
				log.Printf("Periodic sweep completed successfully")
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
	log.Printf("Stopping network sweeper")

	close(s.done)
	<-s.watchDone // Wait for KV watching to stop

	if err := s.icmpScanner.Stop(context.Background()); err != nil {
		log.Printf("Failed to stop ICMP scanner: %v", err)
	}

	if err := s.tcpScanner.Stop(context.Background()); err != nil {
		log.Printf("Failed to stop TCP scanner: %v", err)
	}

	return nil
}

// GetStatus returns current sweep status.
func (s *NetworkSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	return s.store.GetSweepSummary(ctx)
}

// GetResults retrieves sweep results based on filter.
func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	log.Printf("Getting results with filter: %+v", filter)

	return s.store.GetResults(ctx, filter)
}

// GetConfig returns current sweeper configuration.
func (s *NetworkSweeper) GetConfig() models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return *s.config
}

// UpdateConfig updates sweeper configuration.
func (s *NetworkSweeper) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("Updating sweeper config: %+v", config)
	s.config = config

	return nil
}

// watchConfig watches the KV store for config updates.
func (s *NetworkSweeper) watchConfig(ctx context.Context) {
	defer close(s.watchDone)

	if s.kvStore == nil {
		log.Printf("No KV store configured, skipping config watch")

		return
	}

	ch, err := s.kvStore.Watch(ctx, s.configKey)
	if err != nil {
		log.Printf("Failed to watch KV key %s: %v", s.configKey, err)

		return
	}

	log.Printf("Watching KV key %s for config updates", s.configKey)

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping config watch")

			return
		case <-s.done:
			log.Printf("Sweep service closed, stopping config watch")

			return
		case value, ok := <-ch:
			if !ok {
				log.Printf("Watch channel closed for key %s", s.configKey)

				return
			}

			s.processConfigUpdate(value)
		}
	}
}

// processConfigUpdate processes a config update from the KV store.
func (s *NetworkSweeper) processConfigUpdate(value []byte) {
	var temp unmarshalConfig
	if err := json.Unmarshal(value, &temp); err != nil {
		log.Printf("Failed to unmarshal config for %s: %v", s.configKey, err)
		return
	}

	newConfig := models.Config{
		Networks:    temp.Networks,
		Ports:       temp.Ports,
		SweepModes:  temp.SweepModes,
		Interval:    time.Duration(temp.Interval),
		Concurrency: temp.Concurrency,
		Timeout:     time.Duration(temp.Timeout),
		ICMPCount:   temp.ICMPCount,
		MaxIdle:     temp.MaxIdle,
		MaxLifetime: time.Duration(temp.MaxLifetime),
		IdleTimeout: time.Duration(temp.IdleTimeout),
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
			Concurrency int
			Timeout     time.Duration
			MaxBatch    int
		}{
			Concurrency: temp.TCPSettings.Concurrency,
			Timeout:     time.Duration(temp.TCPSettings.Timeout),
			MaxBatch:    temp.TCPSettings.MaxBatch,
		},
		EnableHighPerformanceICMP: temp.EnableHighPerformanceICMP,
		ICMPRateLimit:             temp.ICMPRateLimit,
	}

	// Apply defaults if applyDefaultConfig exists, otherwise skip for now
	// newConfig = *applyDefaultConfig(&newConfig)
	if err := s.UpdateConfig(&newConfig); err != nil {
		log.Printf("Failed to apply config update: %v", err)
	} else {
		log.Printf("Successfully updated sweep config from KV: %+v", newConfig)
	}
}

// estimateTargetCount calculates the total number of targets.
func estimateTargetCount(config *models.Config) int {
	total := 0

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

	return total
}

// scanAndProcess runs a scan and processes its results.
func (s *NetworkSweeper) scanAndProcess(ctx context.Context, wg *sync.WaitGroup,
	scanner scan.Scanner, targets []models.Target, scanType string) error {
	defer wg.Done()

	log.Printf("Running %s scan...", scanType)

	results, err := scanner.Scan(ctx, targets)
	if err != nil {
		log.Printf("%s scan failed: %v", scanType, err)

		return err
	}

	count := 0
	success := 0

	for result := range results {
		count++

		if err := s.processResult(ctx, &result); err != nil {
			log.Printf("Failed to process %s result: %v", scanType, err)

			continue
		}

		if result.Available {
			success++
		}
	}

	log.Printf("%s scan complete: %d results, %d successful", scanType, count, success)

	return nil
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	var icmpTargets, tcpTargets []models.Target

	for _, t := range targets {
		switch t.Mode {
		case models.ModeICMP:
			icmpTargets = append(icmpTargets, t)
		case models.ModeTCP:
			tcpTargets = append(tcpTargets, t)
		}
	}

	log.Printf("Starting sweep with %d ICMP targets and %d TCP targets",
		len(icmpTargets), len(tcpTargets))

	var wg sync.WaitGroup

	var icmpErr, tcpErr error

	if len(icmpTargets) > 0 {
		wg.Add(1)

		go func() {
			icmpErr = s.scanAndProcess(ctx, &wg, s.icmpScanner, icmpTargets, "ICMP")
		}()
	}

	if len(tcpTargets) > 0 {
		wg.Add(1)

		go func() {
			tcpErr = s.scanAndProcess(ctx, &wg, s.tcpScanner, tcpTargets, "TCP")
		}()
	}

	wg.Wait()

	if icmpErr != nil {
		return icmpErr
	}

	if tcpErr != nil {
		return tcpErr
	}

	log.Printf("Sweep completed successfully")

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

	// Process through unified device registry if available and result is available
	if s.deviceRegistry != nil && result.Available {
		if err := s.processDeviceRegistry(result); err != nil {
			// Log error but don't fail the entire operation
			log.Printf("Failed to process sweep result through device registry for %s: %v", result.Target.Host, err)
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

// createSweepResult creates a SweepResult from a Result.
func (*NetworkSweeper) createSweepResult(result *models.Result, agentID, pollerID, partition string) *models.SweepResult {
	// Always generate a valid device ID with partition
	deviceID := fmt.Sprintf("%s:%s", partition, result.Target.Host)

	return &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		Partition:       partition,
		DeviceID:        deviceID,
		DiscoverySource: string(models.DiscoverySourceSweep),
		IP:              result.Target.Host,
		Timestamp:       result.LastSeen,
		Available:       result.Available,
		Metadata:        make(map[string]string),
	}
}

// convertMetadataToStringMap converts metadata to a string map.
func convertMetadataToStringMap(sweepResult *models.SweepResult, metadata map[string]interface{}) {
	if metadata == nil {
		return
	}

	for key, value := range metadata {
		if strVal, ok := value.(string); ok {
			sweepResult.Metadata[key] = strVal
		} else {
			sweepResult.Metadata[key] = fmt.Sprintf("%v", value)
		}
	}
}

// addAdditionalMetadata adds additional metadata to the SweepResult.
func addAdditionalMetadata(sweepResult *models.SweepResult, result *models.Result) {
	// Add sweep mode to metadata
	sweepResult.Metadata["sweep_mode"] = string(result.Target.Mode)
	if result.Target.Port > 0 {
		sweepResult.Metadata["port"] = fmt.Sprintf("%d", result.Target.Port)
	}

	// Add timing metadata
	sweepResult.Metadata["response_time"] = result.RespTime.String()
	sweepResult.Metadata["packet_loss"] = fmt.Sprintf("%.2f", result.PacketLoss)
}

// processDeviceRegistry processes the sweep result through the device registry.
func (s *NetworkSweeper) processDeviceRegistry(result *models.Result) error {
	agentID, pollerID, partition := s.extractAgentInfo(result)
	sweepResult := s.createSweepResult(result, agentID, pollerID, partition)

	// Convert metadata to string map
	convertMetadataToStringMap(sweepResult, result.Target.Metadata)

	// Add additional metadata
	addAdditionalMetadata(sweepResult, result)

	// Use background context to avoid cancellation
	bgCtx := context.Background()

	return s.deviceRegistry.ProcessSweepResult(bgCtx, sweepResult)
}

// generateTargets creates scan targets from the configuration.
func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	var targets []models.Target

	totalHostCount := 0

	for _, network := range s.config.Networks {
		ips, err := scan.ExpandCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to expand CIDR %s: %w", network, err)
		}

		totalHostCount += len(ips)

		metadata := map[string]interface{}{
			"network":     network,
			"total_hosts": len(ips),
		}

		for _, ip := range ips {
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				target := scan.TargetFromIP(ip, models.ModeICMP)
				target.Metadata = metadata
				targets = append(targets, target)
			}

			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					target := scan.TargetFromIP(ip, models.ModeTCP, port)
					target.Metadata = metadata
					targets = append(targets, target)
				}
			}
		}
	}

	log.Printf("Generated %d targets from %d networks (total hosts: %d)",
		len(targets), len(s.config.Networks), totalHostCount)

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
