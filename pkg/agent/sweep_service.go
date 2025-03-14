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
	"net"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/pkg/sweeper"
	"github.com/carverauto/serviceradar/proto"
)

const (
	cidr32       = 32
	networkStart = 1
	networkNext  = 2
	sweepTimeout = 10 * time.Minute
)

// SweepService implements sweeper.SweepService for network scanning.
type SweepService struct {
	scanner   scan.Scanner
	store     sweeper.Store
	processor sweeper.ResultProcessor
	mu        sync.RWMutex
	closed    chan struct{}
	config    *models.Config
	stats     *ScanStats
}

// NewSweepService creates a new sweep service with the provided configuration.
func NewSweepService(config *models.Config) (Service, error) {
	// Apply default configuration
	config = applyDefaultConfig(config)

	// Create processor instance
	processor := sweeper.NewBaseProcessor(config)

	// Create an in-memory store
	store := sweeper.NewInMemoryStore(processor)

	// Create scanner based on configuration
	var scanner scan.Scanner

	// Create combined scanner that can handle both TCP and ICMP targets
	scanner = scan.NewCombinedScanner(
		config.Timeout,
		config.Concurrency,
		config.ICMPCount,
		config.MaxIdle,
		config.MaxLifetime,
		config.IdleTimeout,
	)

	// If high-performance ICMP scanning is enabled, update the combined scanner
	if config.EnableHighPerformanceICMP {
		log.Printf("High-performance ICMP scanning enabled with rate limit %d pps",
			config.ICMPRateLimit)

		// Create a high-performance ICMP scanner
		icmpScanner, err := scan.NewFastICMPScanner(config.Timeout, config.ICMPRateLimit)
		if err != nil {
			log.Printf("Failed to create high-performance ICMP scanner: %v, falling back to standard scanner", err)
		} else {
			// Create the TCP scanner - we need to recreate the CombinedScanner with the fast ICMP scanner
			tcpScanner := scan.NewTCPScanner(config.Timeout, config.Concurrency)

			// Create a custom combined scanner with the fast ICMP scanner
			scanner = &customCombinedScanner{
				tcpScanner:  tcpScanner,
				icmpScanner: icmpScanner,
			}

			log.Printf("Using high-performance ICMP scanner")
		}
	}

	service := &SweepService{
		scanner:   scanner,
		store:     store,
		processor: processor,
		config:    config,
		closed:    make(chan struct{}),
		stats:     newScanStats(),
	}

	return service, nil
}

// customCombinedScanner combines a TCP scanner and a custom ICMP scanner
type customCombinedScanner struct {
	tcpScanner  scan.Scanner
	icmpScanner scan.Scanner
	mu          sync.Mutex
}

// Scan implements the Scanner interface for the custom combined scanner
func (s *customCombinedScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	resultCh := make(chan models.Result, 1000)

	// Split targets by protocol
	var tcpTargets, icmpTargets []models.Target
	for _, target := range targets {
		if target.Mode == models.ModeTCP {
			tcpTargets = append(tcpTargets, target)
		} else if target.Mode == models.ModeICMP {
			icmpTargets = append(icmpTargets, target)
		}
	}

	log.Printf("Processing targets - TCP: %d, ICMP: %d", len(tcpTargets), len(icmpTargets))

	var wg sync.WaitGroup

	// Start TCP scan if we have TCP targets
	if len(tcpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tcpResults, err := s.tcpScanner.Scan(ctx, tcpTargets)
			if err != nil {
				log.Printf("TCP scan error: %v", err)
				return
			}

			// Forward results
			for result := range tcpResults {
				select {
				case <-ctx.Done():
					return
				case resultCh <- result:
					// Result forwarded
				}
			}
		}()
	}

	// Start ICMP scan if we have ICMP targets
	if len(icmpTargets) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			icmpResults, err := s.icmpScanner.Scan(ctx, icmpTargets)
			if err != nil {
				log.Printf("ICMP scan error: %v", err)
				return
			}

			// Forward results
			for result := range icmpResults {
				select {
				case <-ctx.Done():
					return
				case resultCh <- result:
					// Result forwarded
				}
			}
		}()
	}

	// Close result channel when all scanners are done
	go func() {
		wg.Wait()
		close(resultCh)
	}()

	return resultCh, nil
}

// Stop implements the Scanner interface for the custom combined scanner
func (s *customCombinedScanner) Stop(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var errTCP, errICMP error

	// Stop TCP scanner
	errTCP = s.tcpScanner.Stop(ctx)

	// Stop ICMP scanner
	errICMP = s.icmpScanner.Stop(ctx)

	// Return errors
	if errTCP != nil && errICMP != nil {
		return fmt.Errorf("multiple errors stopping scanners: TCP: %v, ICMP: %v", errTCP, errICMP)
	} else if errTCP != nil {
		return errTCP
	} else if errICMP != nil {
		return errICMP
	}

	return nil
}

const (
	defaultMaxRetries    = 3
	defaultRetryInterval = 5 * time.Second
)

// Start launches the periodic sweeps.
func (s *SweepService) Start(ctx context.Context) error {
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	// Retry initial sweep with backoff
	retryInterval := defaultRetryInterval

	for i := 0; i < defaultMaxRetries; i++ {
		err := s.performSweep(ctx)
		if err == nil {
			break // Success
		}

		log.Printf("Initial sweep failed (attempt %d/%d): %v", i+1, defaultMaxRetries, err)

		if i == defaultMaxRetries-1 {
			return fmt.Errorf("initial sweep failed after %d retries: %w", defaultMaxRetries, err)
		}

		time.Sleep(defaultRetryInterval)

		retryInterval *= 2 // Exponential backoff
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.closed:
			return nil
		case <-ticker.C:
			if err := s.performSweep(ctx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			}
		}
	}
}

// performSweep performs a network sweep with the current configuration.
func (s *SweepService) performSweep(ctx context.Context) error {
	sweepCtx, cancel := context.WithTimeout(ctx, sweepTimeout)
	defer cancel()

	startTime := time.Now()
	log.Printf("Starting sweep at %s with timeout of %s", startTime.Format(time.RFC3339), sweepTimeout)

	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	results, err := s.scanner.Scan(sweepCtx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	stats := newScanStats()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for result := range results {
			if err := s.handleResult(sweepCtx, &result); err != nil {
				log.Printf("Error handling result: %v", err)
			}
			updateStats(stats, &result)
		}
	}()

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Printf("All scan results processed")
	case <-sweepCtx.Done():
		log.Printf("Sweep canceled: %v", sweepCtx.Err())
	}

	// Update s.stats with this sweep's results
	s.mu.Lock()
	s.stats.totalResults += stats.totalResults
	s.stats.successCount += stats.successCount
	s.stats.icmpSuccess += stats.icmpSuccess
	s.stats.tcpSuccess += stats.tcpSuccess
	for host := range stats.uniqueHosts {
		s.stats.uniqueHosts[host] = struct{}{}
	}
	// uniqueIPs is set in generateTargets, don't overwrite here
	s.mu.Unlock()

	s.logScanCompletion(stats)
	log.Printf("Sweep completed in %.2f seconds", time.Since(startTime).Seconds())
	return nil
}

func (s *SweepService) handleResult(ctx context.Context, result *models.Result) error {
	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("failed to process result: %w", err)
	}

	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("failed to save result: %w", err)
	}

	s.logSuccessfulResult(result)

	return nil
}

func applyDefaultConfig(config *models.Config) *models.Config {
	if config == nil {
		config = &models.Config{}
	}

	// Set sweep modes if not configured
	if len(config.SweepModes) == 0 {
		config.SweepModes = []models.SweepMode{
			models.ModeTCP,
			models.ModeICMP,
		}
	}

	// Conservative defaults
	if config.Timeout == 0 {
		config.Timeout = 15 * time.Second // Per-operation timeout
	}

	if config.Concurrency == 0 {
		config.Concurrency = 20 // Reduced from 25
	}

	if config.ICMPCount == 0 {
		config.ICMPCount = 1 // Reduced from 2
	}

	if config.Interval == 0 {
		config.Interval = 15 * time.Minute // Increased from 5 minutes
	}

	// Connection pool settings
	if config.MaxIdle == 0 {
		config.MaxIdle = 5
	}

	if config.MaxLifetime == 0 {
		config.MaxLifetime = 10 * time.Minute
	}

	if config.IdleTimeout == 0 {
		config.IdleTimeout = 30 * time.Second
	}

	// High-performance ICMP settings
	if config.ICMPRateLimit == 0 {
		config.ICMPRateLimit = 1000 // Default to 1000 packets per second
	}

	return config
}

type ScanStats struct {
	totalResults int
	successCount int
	icmpSuccess  int
	tcpSuccess   int
	uniqueHosts  map[string]struct{}
	uniqueIPs    int // Added to track total unique IPs
	startTime    time.Time
}

func (s *SweepService) generateTargets() ([]models.Target, error) {
	var allTargets []models.Target
	uniqueIPs := make(map[string]struct{})
	globalTotalHosts := 0

	for _, networkCIDR := range s.config.Networks {
		networkTargets, err := s.generateTargetsForNetwork(networkCIDR, &globalTotalHosts, uniqueIPs)
		if err != nil {
			return nil, err
		}
		allTargets = append(allTargets, networkTargets...)
	}

	log.Printf("Generated %d targets (%d unique IPs, total hosts: %d, ports: %d, modes: %v)",
		len(allTargets), len(uniqueIPs), globalTotalHosts, len(s.config.Ports), s.config.SweepModes)

	s.mu.Lock()
	s.stats.uniqueIPs = len(uniqueIPs) // Set in s.stats
	s.mu.Unlock()

	return allTargets, nil
}

// generateTargetsForNetwork parses a single CIDR, enumerates its IPs, and builds targets.
func (s *SweepService) generateTargetsForNetwork(
	networkCIDR string,
	globalTotalHosts *int,
	uniqueIPs map[string]struct{},
) ([]models.Target, error) {
	ip, ipNet, err := net.ParseCIDR(networkCIDR)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CIDR %s: %w", networkCIDR, err)
	}

	ones, bits := ipNet.Mask.Size()
	networkSize := calculateNetworkSize(ones, bits)
	*globalTotalHosts += networkSize

	var targets []models.Target
	if ones == cidr32 {
		ipStr := ip.String()
		uniqueIPs[ipStr] = struct{}{}
		return s.buildTargets(ipStr, networkCIDR, *globalTotalHosts), nil
	}

	for addr := incrementIP(cloneIP(ipNet.IP)); ipNet.Contains(addr); incrementIP(addr) {
		if isFirstOrLastAddress(addr, ipNet) {
			continue
		}
		ipStr := addr.String()
		uniqueIPs[ipStr] = struct{}{}
		targets = append(targets, s.buildTargets(ipStr, networkCIDR, *globalTotalHosts)...)
	}
	return targets, nil
}

func (s *SweepService) buildTargets(ipStr, network string, totalHosts int) []models.Target {
	var targets []models.Target
	if containsMode(s.config.SweepModes, models.ModeICMP) {
		targets = append(targets, models.Target{
			Host: ipStr,
			Mode: models.ModeICMP,
			Metadata: map[string]interface{}{
				"network":     network,
				"total_hosts": totalHosts,
			},
		})
	}
	if containsMode(s.config.SweepModes, models.ModeTCP) {
		for _, port := range s.config.Ports {
			targets = append(targets, models.Target{
				Host: ipStr,
				Port: port,
				Mode: models.ModeTCP,
				Metadata: map[string]interface{}{
					"network":     network,
					"total_hosts": totalHosts,
				},
			})
		}
	}
	return targets
}

// logSuccessfulResult logs successful (Available) results.
func (*SweepService) logSuccessfulResult(result *models.Result) {
	if !result.Available {
		return
	}

	switch result.Target.Mode {
	case models.ModeICMP:
		log.Printf("Host %s responded to ICMP ping (%.2fms) - Network: %s",
			result.Target.Host,
			float64(result.RespTime)/float64(time.Millisecond),
			result.Target.Metadata["network"])
	case models.ModeTCP:
		log.Printf("Host %s has port %d open (%.2fms) - Network: %s",
			result.Target.Host,
			result.Target.Port,
			float64(result.RespTime)/float64(time.Millisecond),
			result.Target.Metadata["network"])
	}
}

// newScanStats initializes ScanStats for a new sweep.
func newScanStats() *ScanStats {
	return &ScanStats{
		uniqueHosts: make(map[string]struct{}),
		startTime:   time.Now(),
	}
}

// logScanCompletion logs final sweep statistics.
func (s *SweepService) logScanCompletion(stats *ScanStats) {
	log.Printf("Sweep completed in %.2f seconds: %d total results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		time.Since(stats.startTime).Seconds(), stats.totalResults, stats.successCount,
		stats.icmpSuccess, stats.tcpSuccess, len(stats.uniqueHosts))
	log.Printf("Config stats - Defined networks: %d, Expanded IPs: %d", len(s.config.Networks), s.stats.uniqueIPs)
}

const (
	defaultCIDR31  = 31
	defaultRFC3021 = 2
)

// calculateNetworkSize calculates how many usable IP addresses exist in the subnet.
func calculateNetworkSize(ones, bits int) int {
	if ones == cidr32 {
		return networkStart // Single host for /32
	}

	if ones == defaultCIDR31 {
		return defaultRFC3021 // Special case: RFC 3021 allows both IPs to be used in /31
	}

	// For all other networks, total addresses = 2^(32-ones)
	// Subtract 2 for network and broadcast addresses (except for /31)
	totalAddresses := 1 << (bits - ones)

	return totalAddresses - networkNext // Subtract network and broadcast addresses
}

// isFirstOrLastAddress checks if IP is the network or broadcast address.
func isFirstOrLastAddress(ip net.IP, network *net.IPNet) bool {
	if ip.Equal(network.IP) {
		return true
	}

	// Calculate broadcast address
	broadcast := make(net.IP, len(network.IP))
	for i := range network.IP {
		broadcast[i] = network.IP[i] | ^network.Mask[i]
	}

	return ip.Equal(broadcast)
}

// cloneIP returns a copy of the given net.IP.
func cloneIP(ip net.IP) net.IP {
	clone := make(net.IP, len(ip))
	copy(clone, ip)

	return clone
}

// incrementIP increments an IP address by one.
func incrementIP(ip net.IP) net.IP {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}

	return ip
}

// updateStats updates statistics for each scan result.
func updateStats(stats *ScanStats, result *models.Result) {
	stats.totalResults++
	if result.Available {
		stats.successCount++
		stats.uniqueHosts[result.Target.Host] = struct{}{}
		switch result.Target.Mode {
		case models.ModeICMP:
			stats.icmpSuccess++
		case models.ModeTCP:
			stats.tcpSuccess++
		}
	}
}

// Stop stops any in-progress scans and closes the service.
func (s *SweepService) Stop(ctx context.Context) error {
	close(s.closed)

	return s.scanner.Stop(ctx)
}

// Name returns the service name.
func (*SweepService) Name() string {
	return "network_sweep"
}

// GetStatus returns a status summary of the sweep.
func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	summary, err := s.processor.GetSummary(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get sweep summary: %w", err)
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
		LastSweep:      summary.LastSweep,
		Ports:          summary.Ports,
		Hosts:          summary.Hosts,
		DefinedCIDRs:   len(s.config.Networks),
		UniqueIPs:      s.stats.uniqueIPs,
	}
	s.mu.RUnlock()

	statusJSON, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:    true,
		Message:      string(statusJSON),
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
	}, nil
}

// UpdateConfig applies new configuration and resets default values as needed.
func (s *SweepService) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	oldConfig := s.config
	newConfig := applyDefaultConfig(config)
	s.config = newConfig

	// If a scanner-related setting has changed, recreate the scanner
	if oldConfig.EnableHighPerformanceICMP != newConfig.EnableHighPerformanceICMP ||
		oldConfig.ICMPRateLimit != newConfig.ICMPRateLimit ||
		oldConfig.ICMPCount != newConfig.ICMPCount ||
		oldConfig.Concurrency != newConfig.Concurrency ||
		oldConfig.Timeout != newConfig.Timeout {

		var scanner scan.Scanner

		// Create default combined scanner
		scanner = scan.NewCombinedScanner(
			newConfig.Timeout,
			newConfig.Concurrency,
			newConfig.ICMPCount,
			newConfig.MaxIdle,
			newConfig.MaxLifetime,
			newConfig.IdleTimeout,
		)

		// If high-performance ICMP scanning is enabled, update the combined scanner
		if newConfig.EnableHighPerformanceICMP {
			log.Printf("High-performance ICMP scanning enabled with rate limit %d pps",
				newConfig.ICMPRateLimit)

			// Create a high-performance ICMP scanner
			icmpScanner, err := scan.NewFastICMPScanner(newConfig.Timeout, newConfig.ICMPRateLimit)
			if err != nil {
				log.Printf("Failed to create high-performance ICMP scanner: %v, falling back to standard scanner", err)
			} else {
				// Create the TCP scanner - we need to recreate the CombinedScanner with the fast ICMP scanner
				tcpScanner := scan.NewTCPScanner(newConfig.Timeout, newConfig.Concurrency)

				// Create a custom combined scanner with the fast ICMP scanner
				scanner = &customCombinedScanner{
					tcpScanner:  tcpScanner,
					icmpScanner: icmpScanner,
				}

				log.Printf("Using high-performance ICMP scanner")
			}
		}

		// Replace the scanner
		s.scanner = scanner
	}

	return nil
}

// containsMode checks if the mode slice includes a specific SweepMode.
func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}
