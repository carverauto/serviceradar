// Package sweeper pkg/sweeper/sweeper.go
package sweeper

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"time"
)

// NetworkSweeper implements the Sweeper interface.
type NetworkSweeper struct {
	config  Config
	scanner *CombinedScanner
	store   Store
	mu      sync.RWMutex
	done    chan struct{}
}

// NewNetworkSweeper creates a new instance of NetworkSweeper.
func NewNetworkSweeper(config Config) *NetworkSweeper {
	scanner := NewCombinedScanner(config.Timeout, config.Concurrency, config.ICMPCount)
	store := NewInMemoryStore()

	return &NetworkSweeper{
		config:  config,
		scanner: scanner,
		store:   store,
		done:    make(chan struct{}),
	}
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
				return err
			}
		}
	}
}

func (s *NetworkSweeper) Stop() error {
	close(s.done)
	return s.scanner.Stop()
}

func (s *NetworkSweeper) GetResults(ctx context.Context, filter *ResultFilter) ([]Result, error) {
	return s.store.GetResults(ctx, filter)
}

func (s *NetworkSweeper) GetConfig() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.config
}

func (s *NetworkSweeper) UpdateConfig(config Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.config = config

	return nil
}

// UnmarshalJSON implements json.Unmarshaler for SweepMode.
func (m *SweepMode) UnmarshalJSON(data []byte) error {
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}

	switch strings.ToLower(s) {
	case "tcp":
		*m = ModeTCP
	case "icmp":
		*m = ModeICMP
	default:
		return fmt.Errorf("invalid sweep mode: %s", s)
	}

	return nil
}

// MarshalJSON implements json.Marshaler for SweepMode.
func (m *SweepMode) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(*m))
}

func (s *NetworkSweeper) generateTargets() ([]Target, error) {
	var allTargets []Target

	for _, network := range s.config.Networks {
		// First generate all IP addresses
		ips, err := generateIPsFromCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to generate IPs for %s: %w", network, err)
		}

		// For each IP, create ICMP target if enabled
		if containsMode(s.config.SweepModes, ModeICMP) {
			for _, ip := range ips {
				allTargets = append(allTargets, Target{
					Host: ip.String(),
					Mode: ModeICMP,
				})
			}
		}

		// For each IP, create TCP targets for each port if enabled
		if containsMode(s.config.SweepModes, ModeTCP) {
			for _, ip := range ips {
				for _, port := range s.config.Ports {
					allTargets = append(allTargets, Target{
						Host: ip.String(),
						Port: port,
						Mode: ModeTCP,
					})
				}
			}
		}
	}

	log.Printf("Generated %d targets (%d IPs, %d ports, modes: %v)",
		len(allTargets),
		len(allTargets)/(len(s.config.Ports)+1),
		len(s.config.Ports),
		s.config.SweepModes)

	return allTargets, nil
}

// inc increments an IP address.
func inc(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

// isFirstOrLastAddress checks if the IP is the network or broadcast address.
func isFirstOrLastAddress(ip net.IP, network *net.IPNet) bool {
	// Get the IP address as 4-byte slice for IPv4
	ipv4 := ip.To4()
	if ipv4 == nil {
		return false
	}

	// Check if it's the network address (first address)
	if ipv4.Equal(ip.Mask(network.Mask)) {
		return true
	}

	// Create broadcast address
	broadcast := make(net.IP, len(ipv4))
	for i := range ipv4 {
		broadcast[i] = ipv4[i] | ^network.Mask[i]
	}

	// Check if it's the broadcast address (last address)
	return ipv4.Equal(broadcast)
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
		// Store the result
		if err := s.store.SaveResult(ctx, &result); err != nil {
			log.Printf("Failed to save result: %v", err)
			continue
		}

		// Log based on scan type
		switch result.Target.Mode {
		case ModeICMP:
			if result.Available {
				log.Printf("Host %s responded to ICMP ping (%.2fms)",
					result.Target.Host, float64(result.RespTime)/float64(time.Millisecond))
			}
		case ModeTCP:
			if result.Available {
				log.Printf("Host %s has port %d open (%.2fms)",
					result.Target.Host, result.Target.Port,
					float64(result.RespTime)/float64(time.Millisecond))
			}
		}
	}

	return nil
}

func containsMode(modes []SweepMode, mode SweepMode) bool {
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
	for ip := ip.Mask(ipnet.Mask); ipnet.Contains(ip); inc(ip) {
		// Skip network and broadcast addresses for IPv4
		if ip.To4() != nil && isFirstOrLastAddress(ip, ipnet) {
			continue
		}
		newIP := make(net.IP, len(ip))
		copy(newIP, ip)
		ips = append(ips, newIP)
	}

	return ips, nil
}
