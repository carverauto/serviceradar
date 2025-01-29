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
)

var (
	errInvalidSweepMode = errors.New("invalid sweep mode")
)

// NetworkSweeper implements the Sweeper interface.
type NetworkSweeper struct {
	config    *models.Config
	scanner   *scan.CombinedScanner
	store     Store
	processor ResultProcessor
	mu        sync.RWMutex
	done      chan struct{}
}

func (s *NetworkSweeper) Start(ctx context.Context) error {
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	// Do initial sweep
	if err := s.runSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
	}

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
	var totalIPs uint64 // Use uint64 to avoid overflow

	u := make(map[string]struct{}) // uniqueIPs

	for _, network := range s.config.Networks {
		_, ipnet, err := net.ParseCIDR(network)
		if err != nil {
			return 0, nil, fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}

		ones, bits := ipnet.Mask.Size()
		// Ensure that the shift operation is safe by checking the number of bits
		if bits-ones > 64 {
			return 0, nil, fmt.Errorf("CIDR mask %s is too large to calculate network size", network)
		}
		networkSize := uint64(1) << uint64(bits-ones) // Total IPs in the network

		if ones < cidr32 { // Not a /32
			networkSize -= networkAndBroadcast // Subtract network and broadcast addresses
		}

		totalIPs += networkSize
	}

	// Calculate target capacity based on enabled modes
	var targetCapacity uint64 // Use uint64 for intermediate calculations
	if containsMode(s.config.SweepModes, models.ModeICMP) {
		targetCapacity += totalIPs
	}

	if containsMode(s.config.SweepModes, models.ModeTCP) {
		targetCapacity += totalIPs * uint64(len(s.config.Ports))
	}

	// Check if targetCapacity exceeds the maximum value of int
	if targetCapacity > uint64(maxInt) {
		return 0, nil, fmt.Errorf("target capacity %d exceeds maximum int value %d", targetCapacity, maxInt)
	}

	return int(targetCapacity), u, nil
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
	// Generate targets
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Process results as they come in
	for result := range results {
		// Process the result first
		if err := s.processor.Process(&result); err != nil {
			log.Printf("Failed to process result: %v", err)
		}

		// Store the result
		if err := s.store.SaveResult(ctx, &result); err != nil {
			log.Printf("Failed to save result: %v", err)
		}

		// Log based on scan type
		switch result.Target.Mode {
		case models.ModeICMP:
			if result.Available {
				log.Printf("Host %s responded to ICMP ping (%.2fms)",
					result.Target.Host, float64(result.RespTime)/float64(time.Millisecond))
			}
		case models.ModeTCP:
			if result.Available {
				log.Printf("Host %s has port %d open (%.2fms)",
					result.Target.Host, result.Target.Port,
					float64(result.RespTime)/float64(time.Millisecond))
			}
		}
	}

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
