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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
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
}

// NewSweepService creates a new SweepService.
func NewSweepService(config *models.Config, kvStore KVStore, configKey string, log logger.Logger) (Service, error) {
	config = applyDefaultConfig(config)
	processor := sweeper.NewBaseProcessor(config, log)
	store := sweeper.NewInMemoryStore(processor, log)

	sweeperInstance, err := sweeper.NewNetworkSweeper(config, store, processor, kvStore, nil, configKey, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create network sweeper: %w", err)
	}

	return &SweepService{
		sweeper:            sweeperInstance,
		config:             config,
		stats:              newScanStats(),
		logger:             log,
		cachedResults:      nil,
		lastSweepTimestamp: 0,
		currentSequence:    0,
	}, nil
}

// Start begins the sweep service.
func (s *SweepService) Start(ctx context.Context) error {
	s.logger.Info().Msgf("Starting sweep service with interval %v", s.config.Interval)

	return s.sweeper.Start(ctx) // KV watching is handled by NetworkSweeper
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

// Name returns the service name.
func (*SweepService) Name() string {
	return "network_sweep"
}

// UpdateConfig updates the service configuration.
func (s *SweepService) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	newConfig := applyDefaultConfig(config)

	s.config = newConfig
	s.logger.Info().Msgf("Updated sweep config: %+v", newConfig)

	return s.sweeper.UpdateConfig(newConfig)
}

// GetStatus returns the current status of the sweep service (lightweight version without hosts).
func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.logger.Info().Msg("Fetching sweep status")

	summary, err := s.sweeper.GetStatus(ctx)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep summary")
		return nil, fmt.Errorf("failed to get sweep status: %w", err)
	}

	s.mu.RLock()
	data := struct {
		Network        string             `json:"network"`
		TotalHosts     int                `json:"total_hosts"`
		AvailableHosts int                `json:"available_hosts"`
		LastSweep      int64              `json:"last_sweep"`
		Ports          []models.PortCount `json:"ports"`
		DefinedCIDRs   int                `json:"defined_cidrs"`
		UniqueIPs      int                `json:"unique_ips"`
		Sequence       uint64             `json:"sequence"`
	}{
		Network:        strings.Join(s.config.Networks, ","),
		TotalHosts:     summary.TotalHosts,
		AvailableHosts: summary.AvailableHosts,
		LastSweep:      summary.LastSweep,
		Ports:          summary.Ports,
		DefinedCIDRs:   len(s.config.Networks),
		UniqueIPs:      s.stats.uniqueIPs,
		Sequence:       s.currentSequence,
	}
	s.mu.RUnlock()

	statusJSON, err := json.Marshal(data)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal status")
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      statusJSON,
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
	}, nil
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
		config.Timeout = 5 * time.Second
	}

	if config.Concurrency == 0 {
		config.Concurrency = 20
	}

	if config.Interval == 0 {
		config.Interval = 5 * time.Minute
	}

	if config.ICMPRateLimit == 0 {
		config.ICMPRateLimit = 1000
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
	icmpScanner, err := scan.NewICMPSweeper(s.config.Timeout, s.config.ICMPRateLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	defer func() {
		if stopErr := icmpScanner.Stop(ctx); stopErr != nil {
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
	s.logger.Info().Str("lastSequence", lastSequence).Msg("GetSweepResults called")

	summary, err := s.sweeper.GetStatus(ctx)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep summary for results")
		return nil, fmt.Errorf("failed to get sweep results: %w", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if sweep data has changed based on timestamp
	if summary.LastSweep != s.lastSweepTimestamp {
		// Update cached results and increment sequence
		s.cachedResults = summary
		s.lastSweepTimestamp = summary.LastSweep
		s.currentSequence++

		// Sequence updated

		s.logger.Info().Uint64("newSequence", s.currentSequence).Msg("Sweep data changed, updated sequence")
	}

	currentSeqStr := fmt.Sprintf("%d", s.currentSequence)

	// If the caller's sequence is up to date, return no new data
	if lastSequence != "" && lastSequence == currentSeqStr {
		s.logger.Debug().Str("callerSequence", lastSequence).Str("currentSequence", currentSeqStr).Msg("No new sweep data")

		return &proto.ResultsResponse{
			HasNewData:      false,
			CurrentSequence: currentSeqStr,
			ServiceName:     "network_sweep",
			ServiceType:     "sweep",
		}, nil
	}

	// Marshal the full sweep results
	resultData, err := json.Marshal(s.cachedResults)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal sweep results")
		return nil, fmt.Errorf("failed to marshal sweep results: %w", err)
	}

	s.logger.Info().Str("sequence", currentSeqStr).Int("hostCount", len(s.cachedResults.Hosts)).Msg("Returning new sweep data")

	return &proto.ResultsResponse{
		HasNewData:      true,
		CurrentSequence: currentSeqStr,
		Data:            resultData,
		ServiceName:     "network_sweep",
		ServiceType:     "sweep",
		Available:       true,
		Timestamp:       time.Now().Unix(),
	}, nil
}
