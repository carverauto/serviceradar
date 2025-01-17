package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/sweeper"
	"github.com/mfreeman451/homemon/proto"
)

type SweepService struct {
	sweeper  sweeper.Sweeper
	mu       sync.RWMutex
	closed   chan struct{}
	config   sweeper.Config
	results  []sweeper.Result
	lastScan time.Time
}

// NewSweepService creates a new sweep service
func NewSweepService(config sweeper.Config) (*SweepService, error) {
	// Create TCP scanner with configuration
	scanner := sweeper.NewTCPScanner(config.Timeout, config.Concurrency)

	// Create an in-memory store for temporary results
	store := NewInMemoryStore()

	// Create sweeper instance
	sw := sweeper.NewSweeper(config, scanner, store)

	return &SweepService{
		sweeper: sw,
		closed:  make(chan struct{}),
		config:  config,
		results: make([]sweeper.Result, 0),
	}, nil
}

// InMemoryStore implements sweeper.Store interface for temporary storage
type InMemoryStore struct {
	mu      sync.RWMutex
	results []sweeper.Result
}

func NewInMemoryStore() *InMemoryStore {
	return &InMemoryStore{
		results: make([]sweeper.Result, 0),
	}
}

func (s *InMemoryStore) SaveResult(_ context.Context, result sweeper.Result) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.results = append(s.results, result)
	return nil
}

func (s *InMemoryStore) GetResults(_ context.Context, filter sweeper.ResultFilter) ([]sweeper.Result, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	filtered := make([]sweeper.Result, 0)
	for _, result := range s.results {
		if filter.StartTime.IsZero() || result.LastSeen.After(filter.StartTime) {
			filtered = append(filtered, result)
		}
	}
	return filtered, nil
}

func (s *InMemoryStore) PruneResults(_ context.Context, age time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-age)
	newResults := make([]sweeper.Result, 0)
	for _, result := range s.results {
		if result.LastSeen.After(cutoff) {
			newResults = append(newResults, result)
		}
	}
	s.results = newResults
	return nil
}

func (s *SweepService) Start(ctx context.Context) error {
	log.Printf("Starting sweep service with config: %+v", s.config)
	return s.sweeper.Start(ctx)
}

func (s *SweepService) Stop() error {
	close(s.closed)
	return s.sweeper.Stop()
}

func (s *SweepService) GetStatus(ctx context.Context) (*proto.ServiceStatus, error) {
	s.mu.RLock()
	config := s.config
	s.mu.RUnlock()

	// Get latest results
	results, err := s.sweeper.GetResults(ctx, sweeper.ResultFilter{
		StartTime: time.Now().Add(-config.Interval),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to get sweep results: %w", err)
	}

	// Aggregate results
	portCounts := make(map[int]int)
	hostsSeen := make(map[string]bool)
	hostsAvailable := make(map[string]bool)

	for _, result := range results {
		hostsSeen[result.Target.Host] = true
		if result.Available {
			hostsAvailable[result.Target.Host] = true
			portCounts[result.Target.Port]++
		}
	}

	// Create sweep status
	sweepStatus := &proto.SweepServiceStatus{
		Network:        config.Networks[0],
		TotalHosts:     int32(len(hostsSeen)),
		AvailableHosts: int32(len(hostsAvailable)),
		LastSweep:      time.Now().Unix(),
		Ports:          make([]*proto.PortStatus, 0, len(portCounts)),
	}

	for port, count := range portCounts {
		sweepStatus.Ports = append(sweepStatus.Ports, &proto.PortStatus{
			Port:      int32(port),
			Available: int32(count),
		})
	}

	// Convert to JSON for the service status message
	statusJSON, err := json.Marshal(sweepStatus)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
	}

	return &proto.ServiceStatus{
		ServiceName: "network_sweep",
		ServiceType: "sweep",
		Available:   true,
		Message:     string(statusJSON),
	}, nil
}

// UpdateConfig updates the sweep configuration
func (s *SweepService) UpdateConfig(config sweeper.Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.config = config
	return s.sweeper.UpdateConfig(config)
}

// Close implements io.Closer
func (s *SweepService) Close() error {
	return s.Stop()
}
