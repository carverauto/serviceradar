package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
	"github.com/mfreeman451/serviceradar/pkg/sweeper"
	"github.com/mfreeman451/serviceradar/proto"
)

// SweepService implements sweeper.SweepService for network scanning
type SweepService struct {
	scanner   scan.Scanner
	store     sweeper.Store
	processor sweeper.ResultProcessor
	mu        sync.RWMutex
	closed    chan struct{}
	config    *models.Config
}

// ScanStats holds statistics for a network sweep
type ScanStats struct {
	totalResults int
	successCount int
	icmpSuccess  int
	tcpSuccess   int
	uniqueHosts  map[string]struct{}
	startTime    time.Time
}

// NewSweepService creates a new sweep service with the provided configuration
func NewSweepService(config *models.Config) (Service, error) {
	// Apply default configuration
	config = applyDefaultConfig(config)

	// Create scanner with config settings
	scanner := scan.NewCombinedScanner(
		config.Timeout,
		config.Concurrency,
		config.ICMPCount,
	)

	// Create processor instance
	processor := sweeper.NewBaseProcessor()

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

func applyDefaultConfig(config *models.Config) *models.Config {
	if config == nil {
		config = &models.Config{}
	}

	// Ensure we have default sweep modes
	if len(config.SweepModes) == 0 {
		config.SweepModes = []models.SweepMode{
			models.ModeTCP,
			models.ModeICMP,
		}
	}

	// Set reasonable defaults
	if config.Timeout == 0 {
		config.Timeout = 10 * time.Second
	}

	if config.Concurrency == 0 {
		config.Concurrency = 100
	}

	if config.ICMPCount == 0 {
		config.ICMPCount = 3
	}

	if config.Interval == 0 {
		config.Interval = 5 * time.Minute
	}

	return config
}

func (s *SweepService) Start(ctx context.Context) error {
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	// Do initial sweep
	if err := s.performSweep(ctx); err != nil {
		log.Printf("Initial sweep failed: %v", err)
		return err
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

// Replace the generateTargets function in pkg/agent/sweep_service.go with this version:
// Replace the generateTargets function in pkg/agent/sweep_service.go with this version:
func (s *SweepService) generateTargets() ([]models.Target, error) {
	var allTargets []models.Target
	uniqueIPs := make(map[string]struct{})
	globalTotalHosts := 0

	for _, network := range s.config.Networks {
		// Parse the CIDR
		ip, ipNet, err := net.ParseCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("failed to parse CIDR %s: %w", network, err)
		}

		// Calculate total hosts for this network
		ones, bits := ipNet.Mask.Size()
		var networkSize int
		if ones == 32 {
			networkSize = 1 // /32 network is just one host
		} else {
			networkSize = (1 << (bits - ones)) - 2 // Subtract network and broadcast for non-/32
		}
		globalTotalHosts += networkSize

		// For /32, just add the single IP
		if ones == 32 {
			ipStr := ip.String()
			uniqueIPs[ipStr] = struct{}{}

			// Add ICMP target if enabled
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				allTargets = append(allTargets, models.Target{
					Host: ipStr,
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"network":     network,
						"total_hosts": globalTotalHosts,
					},
				})
			}

			// Add TCP targets for each port if enabled
			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					allTargets = append(allTargets, models.Target{
						Host: ipStr,
						Port: port,
						Mode: models.ModeTCP,
						Metadata: map[string]interface{}{
							"network":     network,
							"total_hosts": globalTotalHosts,
						},
					})
				}
			}
			continue
		}

		// For non-/32 networks, iterate through the range
		for ip := incrementIP(cloneIP(ipNet.IP)); ipNet.Contains(ip); incrementIP(ip) {
			// Skip network and broadcast addresses
			if isFirstOrLastAddress(ip, ipNet) {
				continue
			}

			ipStr := ip.String()
			uniqueIPs[ipStr] = struct{}{}

			// Add ICMP target if enabled
			if containsMode(s.config.SweepModes, models.ModeICMP) {
				allTargets = append(allTargets, models.Target{
					Host: ipStr,
					Mode: models.ModeICMP,
					Metadata: map[string]interface{}{
						"network":     network,
						"total_hosts": globalTotalHosts,
					},
				})
			}

			// Add TCP targets for each port if enabled
			if containsMode(s.config.SweepModes, models.ModeTCP) {
				for _, port := range s.config.Ports {
					allTargets = append(allTargets, models.Target{
						Host: ipStr,
						Port: port,
						Mode: models.ModeTCP,
						Metadata: map[string]interface{}{
							"network":     network,
							"total_hosts": globalTotalHosts,
						},
					})
				}
			}
		}
	}

	log.Printf("Generated %d targets (%d unique IPs, total hosts: %d, ports: %d, modes: %v)",
		len(allTargets),
		len(uniqueIPs),
		globalTotalHosts,
		len(s.config.Ports),
		s.config.SweepModes)

	return allTargets, nil
}

// Helper function to check if an IP is a network or broadcast address
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

// Helper function to clone an IP address
func cloneIP(ip net.IP) net.IP {
	clone := make(net.IP, len(ip))
	copy(clone, ip)
	return clone
}

// Helper function to increment an IP address
func incrementIP(ip net.IP) net.IP {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
	return ip
}

func (s *SweepService) performSweep(ctx context.Context) error {
	// Generate targets
	targets, err := s.generateTargets()
	if err != nil {
		return fmt.Errorf("failed to generate targets: %w", err)
	}

	// Initialize scan statistics
	stats := &ScanStats{
		uniqueHosts: make(map[string]struct{}),
		startTime:   time.Now(),
	}

	log.Printf("Starting network sweep at %s", stats.startTime.Format(time.RFC3339))

	// Start the scan
	results, err := s.scanner.Scan(ctx, targets)
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Process results as they come in
	for result := range results {
		// Update statistics
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

		// Process the result
		if err := s.processor.Process(&result); err != nil {
			log.Printf("Failed to process result: %v", err)
			continue
		}

		// Store the result
		if err := s.store.SaveResult(ctx, &result); err != nil {
			log.Printf("Failed to save result: %v", err)
			continue
		}

		// Log successful results
		if result.Available {
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
	}

	// Log final scan statistics
	scanDuration := time.Since(stats.startTime)
	log.Printf("Sweep completed in %.2f seconds: %d total results, %d successful (%d ICMP, %d TCP), %d unique hosts",
		scanDuration.Seconds(),
		stats.totalResults,
		stats.successCount,
		stats.icmpSuccess,
		stats.tcpSuccess,
		len(stats.uniqueHosts))

	return nil
}

func (s *SweepService) Stop() error {
	close(s.closed)
	return s.scanner.Stop()
}

func (s *SweepService) Name() string {
	return "network_sweep"
}

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

	// Sort hosts based on IP address numeric values
	sort.Slice(data.Hosts, func(i, j int) bool {
		// Split IP addresses into their numeric components
		ip1Parts := strings.Split(data.Hosts[i].Host, ".")
		ip2Parts := strings.Split(data.Hosts[j].Host, ".")

		// Compare each octet numerically
		for k := 0; k < 4; k++ {
			n1, _ := strconv.Atoi(ip1Parts[k])
			n2, _ := strconv.Atoi(ip2Parts[k])
			if n1 != n2 {
				return n1 < n2
			}
		}
		return false
	})

	statusJSON, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	// Log the response data for debugging
	log.Printf("Sweep status response: %s", string(statusJSON))

	return &proto.StatusResponse{
		Available:    true,
		Message:      string(statusJSON),
		ServiceName:  "network_sweep",
		ServiceType:  "sweep",
		ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
	}, nil
}

func (s *SweepService) UpdateConfig(config models.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	newConfig := applyDefaultConfig(&config)
	s.config = newConfig

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

// isValidNetwork checks if a network string is a valid CIDR
func isValidNetwork(network string) bool {
	_, _, err := net.ParseCIDR(network)
	return err == nil
}

func validateNetworks(networks []string) error {
	if len(networks) == 0 {
		return fmt.Errorf("no networks specified")
	}

	for _, network := range networks {
		if !isValidNetwork(network) {
			return fmt.Errorf("invalid network CIDR: %s", network)
		}
	}

	return nil
}
