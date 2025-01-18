// Package agent pkg/agent/sweep_service.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/sweeper"
	"github.com/mfreeman451/serviceradar/proto"
)

type SweepService struct {
	sweeper sweeper.Sweeper
	mu      sync.RWMutex
	closed  chan struct{}
	config  sweeper.Config
	results []sweeper.Result
}

// NewSweepService creates a new sweep service.
func NewSweepService(config sweeper.Config) (*SweepService, error) {
	// Ensure we have default sweep modes if none specified
	if len(config.SweepModes) == 0 {
		config.SweepModes = []sweeper.SweepMode{
			sweeper.ModeTCP,  // Always enable TCP scanning
			sweeper.ModeICMP, // Enable ICMP for host discovery
		}
	}

	// Ensure reasonable defaults
	if config.Timeout == 0 {
		config.Timeout = 2 * time.Second
	}
	if config.Concurrency == 0 {
		config.Concurrency = 100
	}
	if config.ICMPCount == 0 {
		config.ICMPCount = 3 // Default to 3 ICMP attempts
	}

	log.Printf("Creating sweep service with config: %+v", config)

	// Create network sweeper instance
	sw := sweeper.NewNetworkSweeper(config)

	return &SweepService{
		sweeper: sw,
		closed:  make(chan struct{}),
		config:  config,
		results: make([]sweeper.Result, 0),
	}, nil
}

func (s *SweepService) Start(ctx context.Context) error {
	log.Printf("Starting sweep service with config: %+v", s.config)
	return s.sweeper.Start(ctx)
}

func (s *SweepService) Stop() error {
	close(s.closed)
	return s.sweeper.Stop()
}

// identifyService maps common port numbers to service names
func identifyService(port int) string {
	commonPorts := map[int]string{
		21:   "FTP",
		22:   "SSH",
		23:   "Telnet",
		25:   "SMTP",
		53:   "DNS",
		80:   "HTTP",
		110:  "POP3",
		143:  "IMAP",
		443:  "HTTPS",
		3306: "MySQL",
		5432: "PostgreSQL",
		6379: "Redis",
		8080: "HTTP-Alt",
		8443: "HTTPS-Alt",
		9000: "Kadcast", // Dusk network port
	}

	if service, ok := commonPorts[port]; ok {
		return service
	}
	return fmt.Sprintf("Port-%d", port)
}

func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
	if s == nil {
		log.Printf("Warning: Sweep service not initialized")
		return &proto.StatusResponse{
			Available:   false,
			Message:     "Sweep service not initialized",
			ServiceName: "network_sweep",
			ServiceType: "sweep",
		}, nil
	}

	// Get latest results and log them
	results, err := s.sweeper.GetResults(ctx, &sweeper.ResultFilter{
		StartTime: time.Now().Add(-s.config.Interval),
	})
	if err != nil {
		log.Printf("Error getting sweep results: %v", err)
		return nil, fmt.Errorf("failed to get sweep results: %w", err)
	}

	log.Printf("Processing %d sweep results", len(results))

	// Aggregate results by host
	hostMap := make(map[string]*sweeper.HostResult)
	portCounts := make(map[int]int)
	totalHosts := 0

	for _, result := range results {
		log.Printf("Processing result for host %s (port %d): available=%v time=%v",
			result.Target.Host, result.Target.Port, result.Available, result.RespTime)

		// Update port counts
		if result.Available {
			portCounts[result.Target.Port]++
		}

		// Get or create host result
		host, exists := hostMap[result.Target.Host]
		if !exists {
			totalHosts++
			host = &sweeper.HostResult{
				Host:        result.Target.Host,
				FirstSeen:   result.FirstSeen,
				LastSeen:    result.LastSeen,
				Available:   false,
				PortResults: make([]*sweeper.PortResult, 0),
			}
			hostMap[result.Target.Host] = host
		}

		// Update host details
		if result.Available {
			host.Available = true
			if result.Target.Mode == sweeper.ModeTCP {
				portResult := &sweeper.PortResult{
					Port:      result.Target.Port,
					Available: true,
					RespTime:  result.RespTime,
					Service:   identifyService(result.Target.Port),
				}
				host.PortResults = append(host.PortResults, portResult)
				log.Printf("Found open port %d on host %s (%s)",
					result.Target.Port, host.Host, portResult.Service)
			}
		}
	}

	// Create the summary
	hosts := make([]sweeper.HostResult, 0, len(hostMap))
	availableHosts := 0
	for _, host := range hostMap {
		if host.Available {
			availableHosts++
		}
		hosts = append(hosts, *host)
	}

	now := time.Now()
	summary := sweeper.SweepSummary{
		Network:        s.config.Networks[0],
		TotalHosts:     totalHosts,
		AvailableHosts: availableHosts,
		LastSweep:      now,
		Hosts:          hosts,
		Ports:          make([]sweeper.PortCount, 0, len(portCounts)),
	}

	// Add port statistics
	for port, count := range portCounts {
		summary.Ports = append(summary.Ports, sweeper.PortCount{
			Port:      port,
			Available: count,
		})
	}

	// Log the final summary
	log.Printf("Sweep summary: %d total hosts, %d available, %d ports scanned",
		summary.TotalHosts, summary.AvailableHosts, len(summary.Ports))
	for _, port := range summary.Ports {
		log.Printf("Port %d: %d hosts available", port.Port, port.Available)
	}

	// Convert to JSON for the message field
	statusJSON, err := json.Marshal(summary)
	if err != nil {
		log.Printf("Error marshaling sweep status: %v", err)
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.StatusResponse{
		Available:   true,
		Message:     string(statusJSON),
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

// UpdateConfig updates the sweep configuration.
func (s *SweepService) UpdateConfig(config sweeper.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.config = config

	return s.sweeper.UpdateConfig(config)
}

// Close implements io.Closer.
func (s *SweepService) Close() error {
	return s.Stop()
}
