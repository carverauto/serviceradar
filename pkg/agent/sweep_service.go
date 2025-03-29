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
	"log"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/kv"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
)

// SweepService implements sweeper.SweepService for network scanning.
type SweepService struct {
	sweeper   sweeper.Sweeper
	mu        sync.RWMutex
	closed    chan struct{}
	config    *models.Config
	stats     *ScanStats
	kvStore   kv.KVStore
	configKey string // Key to watch in KV store
	watchDone chan struct{}
}

func NewSweepService(config *models.Config, kvStore kv.KVStore, configKey string) (Service, error) {
	config = applyDefaultConfig(config)
	processor := sweeper.NewBaseProcessor(config)
	store := sweeper.NewInMemoryStore(processor)

	sweeperInstance, err := sweeper.NewNetworkSweeper(config, store, processor)
	if err != nil {
		return nil, fmt.Errorf("failed to create network sweeper: %w", err)
	}

	return &SweepService{
		sweeper:   sweeperInstance,
		config:    config,
		closed:    make(chan struct{}),
		stats:     newScanStats(),
		kvStore:   kvStore,
		configKey: configKey,
		watchDone: make(chan struct{}),
	}, nil
}

func (s *SweepService) Start(ctx context.Context) error {
	log.Printf("Starting sweep service with interval %v", s.config.Interval)

	if s.kvStore != nil && s.configKey != "" {
		go s.watchConfig(ctx)
	}

	err := s.sweeper.Start(ctx)
	if err != nil {
		log.Printf("Failed to start sweeper: %v", err)
	}

	return err
}

func (s *SweepService) Stop(ctx context.Context) error {
	log.Printf("Stopping sweep service")

	close(s.closed)

	return s.sweeper.Stop(ctx)
}

func (*SweepService) Name() string {
	return "network_sweep"
}

func (s *SweepService) watchConfig(ctx context.Context) {
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

	type tempConfig struct {
		Networks     []string           `json:"networks"`
		Ports        []int              `json:"ports"`
		SweepModes   []models.SweepMode `json:"sweep_modes"`
		Interval     string             `json:"interval"`
		Concurrency  int                `json:"concurrency"`
		Timeout      string             `json:"timeout"`
		ICMPCount    int                `json:"icmp_count"`
		MaxIdle      int                `json:"max_idle"`
		MaxLifetime  string             `json:"max_lifetime,omitempty"`
		IdleTimeout  string             `json:"idle_timeout,omitempty"`
		ICMPSettings struct {
			RateLimit int    `json:"rate_limit"`
			Timeout   string `json:"timeout,omitempty"`
			MaxBatch  int    `json:"max_batch"`
		} `json:"icmp_settings"`
		TCPSettings struct {
			Concurrency int    `json:"concurrency"`
			Timeout     string `json:"timeout,omitempty"`
			MaxBatch    int    `json:"max_batch"`
		} `json:"tcp_settings"`
		EnableHighPerformanceICMP bool `json:"high_perf_icmp,omitempty"`
		ICMPRateLimit             int  `json:"icmp_rate_limit,omitempty"`
	}

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping config watch")
			return
		case <-s.closed:
			log.Printf("Sweep service closed, stopping config watch")
			return
		case value, ok := <-ch:
			if !ok {
				log.Printf("Watch channel closed for key %s", s.configKey)
				return
			}

			var temp tempConfig
			if err := json.Unmarshal(value, &temp); err != nil {
				log.Printf("Failed to unmarshal temp config for %s: %v", s.configKey, err)
				continue
			}

			interval, err := time.ParseDuration(temp.Interval)
			if err != nil {
				log.Printf("Failed to parse interval %s: %v", temp.Interval, err)
				continue
			}
			timeout, err := time.ParseDuration(temp.Timeout)
			if err != nil {
				log.Printf("Failed to parse timeout %s: %v", temp.Timeout, err)
				continue
			}
			var maxLifetime time.Duration
			if temp.MaxLifetime != "" {
				maxLifetime, err = time.ParseDuration(temp.MaxLifetime)
				if err != nil {
					log.Printf("Failed to parse max_lifetime %s: %v", temp.MaxLifetime, err)
					continue
				}
			}
			var idleTimeout time.Duration
			if temp.IdleTimeout != "" {
				idleTimeout, err = time.ParseDuration(temp.IdleTimeout)
				if err != nil {
					log.Printf("Failed to parse idle_timeout %s: %v", temp.IdleTimeout, err)
					continue
				}
			}
			var icmpTimeout time.Duration
			if temp.ICMPSettings.Timeout != "" {
				icmpTimeout, err = time.ParseDuration(temp.ICMPSettings.Timeout)
				if err != nil {
					log.Printf("Failed to parse icmp_settings.timeout %s: %v", temp.ICMPSettings.Timeout, err)
					continue
				}
			}
			var tcpTimeout time.Duration
			if temp.TCPSettings.Timeout != "" {
				tcpTimeout, err = time.ParseDuration(temp.TCPSettings.Timeout)
				if err != nil {
					log.Printf("Failed to parse tcp_settings.timeout %s: %v", temp.TCPSettings.Timeout, err)
					continue
				}
			}

			newConfig := models.Config{
				Networks:    temp.Networks,
				Ports:       temp.Ports,
				SweepModes:  temp.SweepModes,
				Interval:    interval,
				Concurrency: temp.Concurrency,
				Timeout:     timeout,
				ICMPCount:   temp.ICMPCount,
				MaxIdle:     temp.MaxIdle,
				MaxLifetime: maxLifetime,
				IdleTimeout: idleTimeout,
				ICMPSettings: struct {
					RateLimit int
					Timeout   time.Duration
					MaxBatch  int
				}{
					RateLimit: temp.ICMPSettings.RateLimit,
					Timeout:   icmpTimeout,
					MaxBatch:  temp.ICMPSettings.MaxBatch,
				},
				TCPSettings: struct {
					Concurrency int
					Timeout     time.Duration
					MaxBatch    int
				}{
					Concurrency: temp.TCPSettings.Concurrency,
					Timeout:     tcpTimeout,
					MaxBatch:    temp.TCPSettings.MaxBatch,
				},
				EnableHighPerformanceICMP: temp.EnableHighPerformanceICMP,
				ICMPRateLimit:             temp.ICMPRateLimit,
			}

			newConfig = *applyDefaultConfig(&newConfig)
			if err := s.UpdateConfig(&newConfig); err != nil {
				log.Printf("Failed to apply config update: %v", err)
			} else {
				log.Printf("Successfully updated sweep config from KV: %+v", newConfig)
			}
		}
	}
}

func (s *SweepService) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	newConfig := applyDefaultConfig(config)
	s.config = newConfig

	log.Printf("Updated sweep config: %+v", newConfig)

	return s.sweeper.UpdateConfig(newConfig)
}

func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	log.Printf("Fetching sweep status")

	summary, err := s.sweeper.GetResults(ctx, &models.ResultFilter{})
	if err != nil {
		log.Printf("Failed to get sweep results: %v", err)

		return nil, fmt.Errorf("failed to get sweep summary: %w", err)
	}

	lastSweep := time.Now().Unix()

	if len(summary) > 0 {
		for i := range summary {
			r := &summary[i] // Use a pointer to avoid copying

			if r.LastSeen.Unix() > lastSweep {
				lastSweep = r.LastSeen.Unix()
			}
		}
	}

	s.mu.RLock()
	data := struct {
		Network        string              `json:"network"`
		TotalHosts     int                 `json:"total_hosts"`
		AvailableHosts int                 `json:"available_hosts"`
		LastSweep      int64               `json:"last_sweep"`
		Ports          []models.PortCount  `json:"ports"`
		Hosts          []models.HostResult `json:"hosts"`
		DefinedCIDRs   int                 `json:"defined_cidrs"`
		UniqueIPs      int                 `json:"unique_ips"`
	}{
		Network:        strings.Join(s.config.Networks, ","),
		TotalHosts:     len(s.stats.uniqueHosts),
		AvailableHosts: s.stats.successCount,
		LastSweep:      lastSweep,
		Ports:          aggregatePorts(summary),
		Hosts:          aggregateHosts(summary),
		DefinedCIDRs:   len(s.config.Networks),
		UniqueIPs:      s.stats.uniqueIPs,
	}

	s.mu.RUnlock()

	statusJSON, err := json.Marshal(data)
	if err != nil {
		log.Printf("Failed to marshal status: %v", err)

		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      string(statusJSON),
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		ResponseTime: time.Since(time.Unix(lastSweep, 0)).Nanoseconds(),
	}, nil
}

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

type ScanStats struct {
	successCount int
	uniqueHosts  map[string]struct{}
	uniqueIPs    int
	startTime    time.Time
}

func newScanStats() *ScanStats {
	return &ScanStats{
		uniqueHosts: make(map[string]struct{}),
		startTime:   time.Now(),
	}
}

func aggregatePorts(results []models.Result) []models.PortCount {
	portMap := make(map[int]int)

	// Count TCP results first
	for i := range results {
		r := &results[i] // Use a pointer to avoid copying
		if r.Target.Mode == models.ModeTCP && r.Available {
			portMap[r.Target.Port]++
		}
	}

	// Pre-allocate with exact size since we know the number of unique ports
	ports := make([]models.PortCount, 0, len(portMap))

	for port, count := range portMap {
		ports = append(ports, models.PortCount{Port: port, Available: count})
	}

	return ports
}

func aggregateHosts(results []models.Result) []models.HostResult {
	hostMap := make(map[string]*models.HostResult)
	// Use indexing instead of range to avoid copying
	for i := range results {
		r := &results[i] // Use a pointer to the struct

		h, ok := hostMap[r.Target.Host]
		if !ok {
			h = &models.HostResult{
				Host:        r.Target.Host,
				FirstSeen:   r.FirstSeen,
				LastSeen:    r.LastSeen,
				PortResults: []*models.PortResult{},
			}

			hostMap[r.Target.Host] = h
		}

		if r.Available {
			h.Available = true

			if r.Target.Mode == models.ModeICMP {
				h.ICMPStatus = &models.ICMPStatus{Available: true, RoundTrip: r.RespTime}
			} else if r.Target.Mode == models.ModeTCP {
				h.PortResults = append(h.PortResults, &models.PortResult{
					Port:      r.Target.Port,
					Available: true,
					RespTime:  r.RespTime,
				})
			}
		}
	}

	// Pre-allocate with exact size since we know the number of unique hosts
	hosts := make([]models.HostResult, 0, len(hostMap))

	for _, h := range hostMap {
		hosts = append(hosts, *h)
	}

	return hosts
}

// CheckICMP performs a standalone ICMP check on the specified host and returns the result.
func (s *SweepService) CheckICMP(ctx context.Context, host string) (*models.Result, error) {
	// Create a new ICMP scanner instance for this check
	icmpScanner, err := scan.NewICMPSweeper(s.config.Timeout, s.config.ICMPRateLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	defer func() {
		if stopErr := icmpScanner.Stop(ctx); stopErr != nil {
			log.Printf("Failed to stop ICMP scanner: %v", stopErr)
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
