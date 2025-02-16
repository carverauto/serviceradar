// Package snmp pkg/checker/snmp/service.go

package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/proto"
)

const (
	defaultServiceStatusTimeout = 5 * time.Second
)

// SNMPService implements both the Service interface and proto.AgentServiceServer.
type SNMPService struct {
	proto.UnimplementedAgentServiceServer
	collectors        map[string]Collector
	aggregators       map[string]Aggregator
	config            *Config
	mu                sync.RWMutex
	done              chan struct{}
	collectorFactory  CollectorFactory
	aggregatorFactory AggregatorFactory
	status            map[string]TargetStatus
}

// NewSNMPService creates a new SNMP monitoring service.
func NewSNMPService(config *Config) (*SNMPService, error) {
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidConfig, err)
	}

	service := &SNMPService{
		collectors:  make(map[string]Collector),
		aggregators: make(map[string]Aggregator),
		config:      config,
		done:        make(chan struct{}),
		status:      make(map[string]TargetStatus),
		// Use default factories if none provided
		collectorFactory:  &defaultCollectorFactory{},
		aggregatorFactory: &defaultAggregatorFactory{},
	}

	return service, nil
}

// Start implements the Service interface.
func (s *SNMPService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Initialize collectors for each target
	for _, target := range s.config.Targets {
		if err := s.initializeTarget(ctx, &target); err != nil {
			return fmt.Errorf("failed to initialize target %s: %w", target.Name, err)
		}
	}

	log.Printf("SNMP Service started with %d targets", len(s.collectors))

	return nil
}

// Stop implements the Service interface.
func (s *SNMPService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	close(s.done)

	var errs []error

	for name, collector := range s.collectors {
		if err := collector.Stop(); err != nil {
			errs = append(errs, fmt.Errorf("failed to stop collector %s: %w", name, err))
		}
	}

	s.collectors = make(map[string]Collector)
	s.aggregators = make(map[string]Aggregator)

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", ErrStoppingCollectors, errs)
	}

	return nil
}

// AddTarget implements the Service interface.
func (s *SNMPService) AddTarget(target *Target) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.collectors[target.Name]; exists {
		return fmt.Errorf("%w: %s", ErrTargetExists, target.Name)
	}

	ctx := context.Background()
	if err := s.initializeTarget(ctx, target); err != nil {
		return fmt.Errorf("%w: %s", errFailedToInitTarget, target.Name)
	}

	return nil
}

// RemoveTarget implements the Service interface.
func (s *SNMPService) RemoveTarget(targetName string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	collector, exists := s.collectors[targetName]
	if !exists {
		return fmt.Errorf("%w: %s", ErrTargetNotFound, targetName)
	}

	if err := collector.Stop(); err != nil {
		return fmt.Errorf("%w: %s", errFailedToStopCollector, targetName)
	}

	delete(s.collectors, targetName)
	delete(s.aggregators, targetName)
	delete(s.status, targetName)

	return nil
}

// GetStatus implements the Service interface.
func (s *SNMPService) GetStatus() (map[string]TargetStatus, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	status := make(map[string]TargetStatus, len(s.status))
	for name, targetStatus := range s.status {
		status[name] = targetStatus
	}

	return status, nil
}

// GetServiceStatus implements the proto.AgentServiceServer interface.
// This is the gRPC endpoint for status requests.
func (s *SNMPService) GetServiceStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	if req.ServiceType != "snmp" {
		return nil, fmt.Errorf("%w: %s", ErrInvalidServiceType, req.ServiceType)
	}

	// set a context with timeout
	_, cancel := context.WithTimeout(ctx, defaultServiceStatusTimeout)
	defer cancel()

	status, err := s.GetStatus()
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   fmt.Sprintf("Error getting status: %v", err),
		}, nil
	}

	// Convert status to JSON for response
	statusJSON, err := json.Marshal(status)
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   fmt.Sprintf("Error marshaling status: %v", err),
		}, nil
	}

	// Determine overall availability
	available := true

	for _, targetStatus := range status {
		if !targetStatus.Available {
			available = false

			break
		}
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     string(statusJSON),
		ServiceName: "snmp",
		ServiceType: "snmp",
	}, nil
}

// initializeTarget sets up collector and aggregator for a target.
func (s *SNMPService) initializeTarget(ctx context.Context, target *Target) error {
	// Create collector
	collector, err := s.collectorFactory.CreateCollector(target)
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateCollector, target.Name)
	}

	// Create aggregator
	aggregator, err := s.aggregatorFactory.CreateAggregator(time.Duration(target.Interval))
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateAggregator, target.Name)
	}

	// Start collector
	if err := collector.Start(ctx); err != nil {
		return fmt.Errorf("%w: %s", errFailedToStartCollector, target.Name)
	}

	// Store components
	s.collectors[target.Name] = collector
	s.aggregators[target.Name] = aggregator

	// Initialize status
	s.status[target.Name] = TargetStatus{
		Available: true,
		LastPoll:  time.Now(),
		OIDStatus: make(map[string]OIDStatus),
	}

	// Start processing results
	go s.processResults(ctx, target.Name, collector, aggregator)

	return nil
}

// processResults handles the data points from a collector.
func (s *SNMPService) processResults(ctx context.Context, targetName string, collector Collector, aggregator Aggregator) {
	results := collector.GetResults()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case point, ok := <-results:
			if !ok {
				return
			}

			s.handleDataPoint(targetName, point, aggregator)
		}
	}
}

// handleDataPoint processes a single data point.
func (s *SNMPService) handleDataPoint(targetName string, point DataPoint, aggregator Aggregator) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update aggregator
	aggregator.AddPoint(point)

	// Update status
	if status, exists := s.status[targetName]; exists {
		if status.OIDStatus == nil {
			status.OIDStatus = make(map[string]OIDStatus)
		}

		status.OIDStatus[point.OIDName] = OIDStatus{
			LastValue:  point.Value,
			LastUpdate: point.Timestamp,
		}

		status.LastPoll = point.Timestamp
		s.status[targetName] = status
	}
}

// defaultCollectorFactory implements CollectorFactory.
type defaultCollectorFactory struct{}

func (*defaultCollectorFactory) CreateCollector(target *Target) (Collector, error) {
	return NewCollector(target)
}

// defaultAggregatorFactory implements AggregatorFactory.
type defaultAggregatorFactory struct{}

// CreateAggregator creates a new Aggregator with the given interval.
func (*defaultAggregatorFactory) CreateAggregator(interval time.Duration) (Aggregator, error) {
	return NewAggregator(interval), nil
}
