// Package sweeper pkg/sweeper/sweeper.go
package sweeper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
)

const (
	cidr32              = 32
	networkAndBroadcast = 2
	maxInt              = int(^uint(0) >> 1) // maxInt is the maximum value of int on the current platform
	bitCount            = 64
	bitsBeforeOverflow  = 63
)

var (
	errInvalidSweepMode = errors.New("invalid sweep mode")
	errTargetCapacity   = errors.New("target capacity overflowed")
	errNetworkCapacity  = errors.New("error calculating network capacity")
	errInvalidCIDRMask  = errors.New("invalid CIDR mask")
	errCIDRMaskTooLarge = errors.New("CIDR mask is too large to calculate network size")
)

// NetworkSweeper implements the Sweeper interface.
type NetworkSweeper struct {
	config    *models.Config
	scanner   *scan.CombinedScanner
	store     Store
	processor ResultProcessor
	mu        sync.RWMutex
	done      chan struct{}
	lastSweep time.Time // Track last sweep time
}

func (s *NetworkSweeper) Start(ctx context.Context) error {
	// Track start time for logging
	startTime := time.Now()
	log.Printf("Starting NetworkSweeper with interval: %v", s.config.Interval)

	// Do initial sweep
	if err := s.runSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
	}

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	for {
		select {
		case <-ctx.Done():
			log.Printf("NetworkSweeper stopping after running for %v", time.Since(startTime))
			return ctx.Err()
		case <-s.done:
			log.Printf("NetworkSweeper done signal received after %v", time.Since(startTime))
			return nil
		case <-ticker.C:
			s.mu.RLock()
			timeSinceLastSweep := time.Since(s.lastSweep)
			s.mu.RUnlock()

			// Enforce minimum interval
			if timeSinceLastSweep < s.config.Interval {
				log.Printf("Skipping sweep, last one was %v ago (interval: %v)",
					timeSinceLastSweep.Round(time.Second),
					s.config.Interval)
				continue
			}

			// Run sweep and update last sweep time
			if err := s.runSweep(ctx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			}
		}
	}
}

func (s *NetworkSweeper) Stop() error {
	close(s.done)
	return s.scanner.Stop()
}

func (s *NetworkSweeper) GetResults(ctx context.Context, filter *models.ResultFilter) ([]models.Result, error) {
	return s.store.GetResults(ctx, filter)
}

func (s *NetworkSweeper) GetConfig() *models.Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.config
}

func (s *NetworkSweeper) UpdateConfig(config *models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.config = config

	return nil
}

type SweepMode models.SweepMode

// UnmarshalJSON implements json.Unmarshaler for SweepMode.
func (m *SweepMode) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}

	switch strings.ToLower(s) {
	case "tcp":
		*m = SweepMode(models.ModeTCP)
	case "icmp":
		*m = SweepMode(models.ModeICMP)
	default:
		return fmt.Errorf("%w: %s", errInvalidSweepMode, s)
	}

	return nil
}

// MarshalJSON implements json.Marshaler for SweepMode.
func (m *SweepMode) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(*m))
}

func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	// Calculate total targets and unique IPs
	targetCapacity, uniqueIPs, err := s.calculateTargetCapacity()
	if err != nil {
		return nil, fmt.Errorf("failed to calculate target capacity: %w", err)
	}

	// Pre-allocate slice with calculated capacity
	allTargets := make([]models.Target, 0, targetCapacity)

	// Generate targets for each network
	for _, network := range s.config.Networks {
		targets, err := s.generateTargetsForNetwork(network, uniqueIPs)
		if err != nil {
			return nil, fmt.Errorf("failed to generate targets for network %s: %w", network, err)
		}

		allTargets = append(allTargets, targets...)
	}

	log.Printf("Generated %d targets (%d unique IPs, %d ports, modes: %v)",
		len(allTargets),
		len(uniqueIPs),
		len(s.config.Ports),
		s.config.SweepModes)

	return allTargets, nil
}

func (s *NetworkSweeper) calculateTargetCapacity() (targetCap int, uniqueIPs map[string]struct{}, err error) {
	u := make(map[string]struct{})
	targetCapacity := 0

	for _, network := range s.config.Networks {
		capacity, err := calculateNetworkCapacity(network, s.config.SweepModes, len(s.config.Ports))
		if err != nil {
			return 0, nil, fmt.Errorf("%w for network %s: %w", errNetworkCapacity, network, err)
		}

		// Check for overflow before adding
		if targetCapacity > maxInt-capacity {
			return 0, nil, errTargetCapacity
		}

		targetCapacity += capacity
	}

	return targetCapacity, u, nil
}

// calculateNetworkCapacity calculates the target capacity for a single network.
func calculateNetworkCapacity(network string, sweepModes []models.SweepMode, numPorts int) (int, error) {
	_, ipnet, err := net.ParseCIDR(network)
	if err != nil {
		return 0, fmt.Errorf("%w %s: %w", errInvalidCIDRMask, network, err)
	}

	ones, bits := ipnet.Mask.Size()
	if bits < ones {
		return 0, fmt.Errorf("%w %s: bits (%d) < ones (%d)", errInvalidCIDRMask, network, bits, ones)
	}

	shift := bits - ones

	// Ensure the shift is within a safe range
	if shift > bitsBeforeOverflow { // 63 because 1 << 64 would overflow on 64-bit systems
		return 0, fmt.Errorf("%w %s", errCIDRMaskTooLarge, network)
	}

	// Calculate network size, considering /32
	networkSize := 1 << shift
	if ones < cidr32 {
		networkSize -= networkAndBroadcast
	}

	// Calculate target capacity for the network based on enabled modes
	capacity := 0
	if containsMode(sweepModes, models.ModeICMP) {
		capacity += networkSize
	}

	if containsMode(sweepModes, models.ModeTCP) {
		// Check for overflow before multiplying
		if numPorts > 0 && networkSize > maxInt/numPorts {
			return 0, fmt.Errorf("%w", errTargetCapacity)
		}

		capacity += networkSize * numPorts
	}

	return capacity, nil
}

// generateTargetsForNetwork generates targets for a specific network.
func (s *NetworkSweeper) generateTargetsForNetwork(network string, uniqueIPs map[string]struct{}) ([]models.Target, error) {
	ips, err := generateIPsFromCIDR(network)
	if err != nil {
		return nil, fmt.Errorf("failed to generate IPs for %s: %w", network, err)
	}

	var targets []models.Target

	for _, ip := range ips {
		ipStr := ip.String()
		uniqueIPs[ipStr] = struct{}{}

		// Add ICMP target if enabled
		if containsMode(s.config.SweepModes, models.ModeICMP) {
			targets = append(targets, models.Target{
				Host: ipStr,
				Mode: models.ModeICMP,
				Metadata: map[string]interface{}{
					"network": network,
				},
			})
		}

		// Add TCP targets if enabled
		if containsMode(s.config.SweepModes, models.ModeTCP) {
			for _, port := range s.config.Ports {
				targets = append(targets, models.Target{
					Host: ipStr,
					Port: port,
					Mode: models.ModeTCP,
					Metadata: map[string]interface{}{
						"network": network,
					},
				})
			}
		}
	}

	return targets, nil
}

func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	// Start timing the sweep
	sweepStart := time.Now()

	// Generate targets
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	log.Printf("Starting network sweep at %v", sweepStart.Format(time.RFC3339))

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Track statistics while processing results
	var stats struct {
		total     int
		success   int
		icmp      int
		tcp       int
		unique    map[string]struct{}
		processed int64
		start     time.Time
	}
	stats.unique = make(map[string]struct{})
	stats.start = time.Now()

	// Process results as they come in
	for result := range results {
		stats.total++
		stats.unique[result.Target.Host] = struct{}{}

		if result.Available {
			stats.success++
			switch result.Target.Mode {
			case models.ModeICMP:
				stats.icmp++
				log.Printf("Host %s responded to ICMP ping (%.2fms)",
					result.Target.Host, float64(result.RespTime)/float64(time.Millisecond))
			case models.ModeTCP:
				stats.tcp++
				log.Printf("Host %s has port %d open (%.2fms)",
					result.Target.Host, result.Target.Port,
					float64(result.RespTime)/float64(time.Millisecond))
			}
		}

		// Process and store the result
		if err := s.processor.Process(&result); err != nil {
			log.Printf("Failed to process result: %v", err)
		}
		if err := s.store.SaveResult(ctx, &result); err != nil {
			log.Printf("Failed to save result: %v", err)
		}

		stats.processed++
	}

	// Update last sweep time
	s.mu.Lock()
	s.lastSweep = sweepStart
	s.mu.Unlock()

	// Log comprehensive sweep summary
	duration := time.Since(sweepStart)
	log.Printf("Sweep completed in %.2f seconds: %d total results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		duration.Seconds(), stats.total, stats.success, stats.icmp, stats.tcp, len(stats.unique))

	return nil
}

func containsMode(modes []models.SweepMode, mode models.SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}

func generateIPsFromCIDR(network string) ([]net.IP, error) {
	ip, ipnet, err := net.ParseCIDR(network)
	if err != nil {
		return nil, err
	}

	var ips []net.IP

	for i := ip.Mask(ipnet.Mask); ipnet.Contains(i); scan.Inc(i) {
		// Skip network and broadcast addresses for IPv4
		if i.To4() != nil && scan.IsFirstOrLastAddress(i, ipnet) {
			continue
		}

		newIP := make(net.IP, len(i))

		copy(newIP, i)
		ips = append(ips, newIP)
	}

	return ips, nil
}
