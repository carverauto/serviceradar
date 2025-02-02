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
	"sync/atomic"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
)

const (
	cidr32              = 32
	networkAndBroadcast = 2
	maxInt              = int(^uint(0) >> 1) // maxInt is the maximum value of int on the current platform
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
	// Do initial sweep
	if err := s.runSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
	}

	// Create ticker after initial sweep
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	// Update last sweep time
	s.mu.Lock()
	s.lastSweep = time.Now()
	s.mu.Unlock()

	log.Printf("Starting sweep cycle with interval: %v", s.config.Interval)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		case <-ticker.C:
			if err := s.runSweep(ctx); err != nil {
				log.Printf("Periodic sweep failed: %v", err)
			}
			// Update last sweep time after each periodic sweep
			s.mu.Lock()
			s.lastSweep = time.Now()
			s.mu.Unlock()
		}
	}
}

// generateTargets generates a list of targets to scan.
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
		s.config.SweepModes,
	)

	return allTargets, nil
}

// processResults processes scan results until the results channel is closed or the context is canceled.
func (s *NetworkSweeper) processResults(ctx context.Context, results <-chan models.Result) (
	icmpSuccess int64, tcpSuccess int64, totalResults int64, uniqueHosts map[string]struct{},
) {
	uniqueHosts = make(map[string]struct{})

	for {
		select {
		case <-ctx.Done():
			return icmpSuccess, tcpSuccess, totalResults, uniqueHosts
		case result, ok := <-results:
			if !ok {
				return icmpSuccess, tcpSuccess, totalResults, uniqueHosts
			}

			atomic.AddInt64(&totalResults, 1)

			uniqueHosts[result.Target.Host] = struct{}{}

			if err := s.processResult(ctx, &result); err != nil {
				// Log but continue processing other results
				log.Printf("Error processing result: %v", err)

				continue
			}

			// Update success counters
			if result.Available {
				switch result.Target.Mode {
				case models.ModeICMP:
					atomic.AddInt64(&icmpSuccess, 1)
				case models.ModeTCP:
					atomic.AddInt64(&tcpSuccess, 1)
				}
			}
		}
	}
}

// runSweep performs a network sweep, scanning targets and processing results.
func (s *NetworkSweeper) runSweep(ctx context.Context) error {
	// Generate targets
	targets, err := s.generateTargets()
	if err != nil {
		return err // Error already wrapped in generateTargets
	}

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Process results
	icmpSuccess, tcpSuccess, totalResults, uniqueHosts := s.processResults(ctx, results)

	// Check for context cancellation after processing results
	if ctx.Err() != nil {
		return ctx.Err()
	}

	log.Printf("Sweep completed: %d total results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		totalResults, icmpSuccess+tcpSuccess, icmpSuccess, tcpSuccess, len(uniqueHosts))

	return nil
}

func (s *NetworkSweeper) processResult(ctx context.Context, result *models.Result) error {
	// Process with processor
	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("processor error: %w", err)
	}

	// Save to store
	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("store error: %w", err)
	}

	return nil
}

func (s *NetworkSweeper) Stop(ctx context.Context) error {
	close(s.done)
	return s.scanner.Stop(ctx)
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
