package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
	"github.com/mfreeman451/serviceradar/pkg/sweeper"
	"github.com/mfreeman451/serviceradar/proto"
)

const (
	cidr32       = 32
	networkStart = 1
	networkNext  = 2
	sweepTimeout = 2 * time.Minute
)

// SweepService implements sweeper.SweepService for network scanning.
type SweepService struct {
	scanner   scan.Scanner
	store     sweeper.Store
	processor sweeper.ResultProcessor
	mu        sync.RWMutex
	closed    chan struct{}
	config    *models.Config
}

// ScanStats holds statistics for a network sweep.
type ScanStats struct {
	totalResults int
	successCount int
	icmpSuccess  int
	tcpSuccess   int
	uniqueHosts  map[string]struct{}
	startTime    time.Time
}

// NewSweepService creates a new sweep service with the provided configuration.
func NewSweepService(config *models.Config) (Service, error) {
	// Apply default configuration
	config = applyDefaultConfig(config)

	// Create scanner with config settings
	scanner := scan.NewCombinedScanner(
		config.Timeout,
		config.Concurrency,
		config.ICMPCount,
		config.MaxIdle,
		config.MaxLifetime,
		config.IdleTimeout,
	)

	// Create processor instance
	processor := sweeper.NewBaseProcessor(config)

	// Create an in-memory store
	store := sweeper.NewInMemoryStore(processor)

	service := &SweepService{
		scanner:   scanner,
		store:     store,
		processor: processor,
		config:    config,
		closed:    make(chan struct{}),
	}

	return service, nil
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
	// Create a timeout context for the sweep operation
	sweepCtx, cancel := context.WithTimeout(ctx, sweepTimeout)
	defer cancel()

	log.Printf("Starting sweep with context: %p", sweepCtx)

	// Generate targets
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Start the scan with the timeout context
	results, err := s.scanner.Scan(sweepCtx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	stats := newScanStats()

	// Process results with the same context
	if err := s.processScanResults(sweepCtx, results, stats); err != nil {
		return fmt.Errorf("failed to process scan results: %w", err)
	}

	// Log completion stats
	s.logScanCompletion(stats)

	return nil
}

func (s *SweepService) processScanResults(ctx context.Context, results <-chan models.Result, stats *ScanStats) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case result, ok := <-results:
			if !ok {
				return nil // Channel closed normally
			}

			if err := s.handleResult(ctx, &result); err != nil {
				log.Printf("Error handling result: %v", err)
			}

			updateStats(stats, &result)
		}
	}
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
		config.Timeout = 5 * time.Second // Per-operation timeout
	}

	if config.Concurrency == 0 {
		config.Concurrency = 25 // Reduced from 100
	}

	if config.ICMPCount == 0 {
		config.ICMPCount = 2 // Reduced from 3
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

	return config
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
		len(allTargets),
		len(uniqueIPs),
		globalTotalHosts,
		len(s.config.Ports),
		s.config.SweepModes)

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

	if ones == cidr32 {
		// Just one IP (/32)
		return s.generateSingleHostTargets(ip, networkCIDR, *globalTotalHosts, uniqueIPs), nil
	}

	// Enumerate non-/32
	return s.generateRangeTargets(ipNet, networkCIDR, *globalTotalHosts, uniqueIPs), nil
}

// generateSingleHostTargets returns the targets for a /32 network.
func (s *SweepService) generateSingleHostTargets(
	ip net.IP,
	networkCIDR string,
	totalHosts int,
	uniqueIPs map[string]struct{},
) []models.Target {
	ipStr := ip.String()
	uniqueIPs[ipStr] = struct{}{}

	return s.buildTargets(ipStr, networkCIDR, totalHosts)
}

// generateRangeTargets enumerates addresses in a given net.IPNet, skipping
// network and broadcast addresses, then builds the target list.
func (s *SweepService) generateRangeTargets(
	ipNet *net.IPNet,
	networkCIDR string,
	totalHosts int,
	uniqueIPs map[string]struct{},
) []models.Target {
	var targets []models.Target

	for addr := incrementIP(cloneIP(ipNet.IP)); ipNet.Contains(addr); incrementIP(addr) {
		if isFirstOrLastAddress(addr, ipNet) {
			continue
		}

		ipStr := addr.String()
		uniqueIPs[ipStr] = struct{}{}

		targets = append(targets, s.buildTargets(ipStr, networkCIDR, totalHosts)...)
	}

	return targets
}

// buildTargets creates ICMP/TCP targets for a single IP.
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
func (*SweepService) logScanCompletion(stats *ScanStats) {
	scanDuration := time.Since(stats.startTime)
	log.Printf("Sweep completed in %.2f seconds: %d total results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		scanDuration.Seconds(),
		stats.totalResults,
		stats.successCount,
		stats.icmpSuccess,
		stats.tcpSuccess,
		len(stats.uniqueHosts))
}

// calculateNetworkSize calculates how many usable IP addresses exist in the subnet.
func calculateNetworkSize(ones, bits int) int {
	if ones == cidr32 {
		return networkStart
	}

	// Subtract network and broadcast addresses for typical subnets
	return (networkStart << (bits - ones)) - networkNext
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

	data := struct {
		Network        string              `json:"network"`
		TotalHosts     int                 `json:"total_hosts"`
		AvailableHosts int                 `json:"available_hosts"`
		LastSweep      int64               `json:"last_sweep"`
		Ports          []models.PortCount  `json:"ports"`
		Hosts          []models.HostResult `json:"hosts"`
	}{
		Network:        strings.Join(s.config.Networks, ","),
		TotalHosts:     summary.TotalHosts,
		AvailableHosts: summary.AvailableHosts,
		LastSweep:      summary.LastSweep,
		Ports:          summary.Ports,
		Hosts:          summary.Hosts,
	}

	// Sort hosts using IPSorter
	ips := make([]string, 0, len(data.Hosts))
	for _, host := range data.Hosts {
		ips = append(ips, host.Host)
	}
	sort.Sort(IPSorter(ips))

	// Rebuild sorted Hosts slice
	sortedHosts := make([]models.HostResult, 0, len(data.Hosts))
	for _, ip := range ips {
		for _, host := range data.Hosts {
			if host.Host == ip {
				sortedHosts = append(sortedHosts, host)
				break
			}
		}
	}
	data.Hosts = sortedHosts

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

	newConfig := applyDefaultConfig(config)
	s.config = newConfig

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
