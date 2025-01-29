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

// generateTargets generates a list of targets based on the current configuration.
func (s *NetworkSweeper) generateTargets() ([]models.Target, error) {
	// Pre-calculate capacity to avoid reallocations
	totalIPs := 0
	for _, network := range s.config.Networks {
		_, ipnet, err := net.ParseCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}
		ones, bits := ipnet.Mask.Size()
		// Calculate network size (2^(32-ones) - 2 for IPv4)
		// Subtract 2 to account for network and broadcast addresses
		if ones < 32 { // Not a /32
			totalIPs += 1<<uint(bits-ones) - 2
		} else {
			totalIPs++ // Single host for /32
		}
	}

	// Calculate total targets based on enabled modes
	targetCapacity := 0
	if containsMode(s.config.SweepModes, models.ModeICMP) {
		targetCapacity += totalIPs
	}
	if containsMode(s.config.SweepModes, models.ModeTCP) {
		targetCapacity += totalIPs * len(s.config.Ports)
	}

	// Pre-allocate slice with calculated capacity
	allTargets := make([]models.Target, 0, targetCapacity)

	uniqueIPs := make(map[string]struct{}, totalIPs)

	for _, network := range s.config.Networks {
		// Generate IPs for this network
		ips, err := generateIPsFromCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to generate IPs for %s: %w", network, err)
		}

		// Process each IP address
		for _, ip := range ips {
			ipStr := ip.String()
			uniqueIPs[ipStr] = struct{}{}

			// Add ICMP target if enabled
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				allTargets = append(allTargets, models.Target{
					Host: ipStr,
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"network":     network,
						"total_hosts": totalIPs,
					},
				})
			}

			// Add TCP targets if enabled
			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					allTargets = append(allTargets, models.Target{
						Host: ipStr,
						Port: port,
						Mode: models.ModeTCP,
						Metadata: map[string]interface{}{
							"network":     network,
							"total_hosts": totalIPs,
						},
					})
				}
			}
		}
	}

	log.Printf("Generated %d targets (%d unique IPs, %d ports, modes: %v)",
		len(allTargets),
		len(uniqueIPs),
		len(s.config.Ports),
		s.config.SweepModes)

	return allTargets, nil
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
