/*-
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package snmp pkg/checker/snmp/service.go

package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultServiceStatusTimeout = 5 * time.Second
)

func (s *SNMPService) Check(ctx context.Context) (status bool, msg string) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	_, cancel := context.WithTimeout(ctx, defaultServiceStatusTimeout)
	defer cancel()

	// If no targets are configured, the service is not available
	if len(s.collectors) == 0 {
		return false, "no targets configured"
	}

	// Check each target's status
	for name, collector := range s.collectors {
		status := collector.GetStatus()

		// If any target is unavailable, the service is considered unavailable
		if !status.Available {
			return false, fmt.Sprintf("target %s is unavailable: %s", name, status.Error)
		}
	}

	return true, ""
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
	}

	// Create collector factory with database service
	service.collectorFactory = &defaultCollectorFactory{}
	service.aggregatorFactory = &defaultAggregatorFactory{}

	return service, nil
}

// Start implements the Service interface.
func (s *SNMPService) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	log.Printf("Starting SNMP Service with %d targets", len(s.config.Targets))

	// Initialize collectors for each target using indexing to avoid copying
	for i := range s.config.Targets {
		target := &s.config.Targets[i] // Get pointer to target
		log.Printf("Initializing target %s (%s) with %d OIDs",
			target.Name, target.Host, len(target.OIDs))

		if err := s.initializeTarget(ctx, target); err != nil {
			return fmt.Errorf("failed to initialize target %s: %w", target.Name, err)
		}
	}

	log.Printf("SNMP Service started with %d targets", len(s.collectors))

	return nil
}

func (s *SNMPService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	select {
	case <-s.done:
		// Already stopped
	default:
		close(s.done)
	}

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
func (s *SNMPService) AddTarget(ctx context.Context, target *Target) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.collectors[target.Name]; exists {
		return fmt.Errorf("%w: %s", ErrTargetExists, target.Name)
	}

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
func (s *SNMPService) GetStatus(_ context.Context) (map[string]TargetStatus, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	log.Printf("SNMP GetStatus called with %d collectors", len(s.collectors))

	status := make(map[string]TargetStatus)

	// Check each collector's status
	for name, collector := range s.collectors {
		log.Printf("Getting status for collector: %s", name)

		collectorStatus := collector.GetStatus()
		log.Printf("Collector %s status: %+v", name, collectorStatus)

		status[name] = collectorStatus
	}

	if len(status) == 0 {
		log.Printf("No SNMP status found, checking configuration...")
		log.Printf("Config: %+v", s.config)
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

	status, err := s.GetStatus(ctx)
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
	log.Printf("Creating collector for target %s", target.Name)

	// Create collector
	collector, err := s.collectorFactory.CreateCollector(target)
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateCollector, target.Name)
	}

	log.Printf("Creating aggregator for target %s with interval %v",
		target.Name, time.Duration(target.Interval))

	// Create aggregator
	aggregator, err := s.aggregatorFactory.CreateAggregator(time.Duration(target.Interval), target.MaxPoints)
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateAggregator, target.Name)
	}

	// Start collector
	if err := collector.Start(ctx); err != nil {
		return fmt.Errorf("%w: %s", errFailedToStartCollector, target.Name)
	}

	log.Printf("Started collector for target %s", target.Name)

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

	log.Printf("Successfully initialized target %s", target.Name)

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

			s.handleDataPoint(targetName, &point, aggregator)
		}
	}
}

// handleDataPoint processes a single data point.
func (s *SNMPService) handleDataPoint(targetName string, point *DataPoint, aggregator Aggregator) {
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

		// Create message for service status
		message := map[string]interface{}{
			"oid_name":  point.OIDName,
			"value":     point.Value,
			"timestamp": point.Timestamp,
			"data_type": point.DataType,
			"scale":     point.Scale,
			"delta":     point.Delta,
		}

		messageJSON, err := json.Marshal(message)
		if err != nil {
			log.Printf("Error marshaling data point: %v", err)
			return
		}

		log.Printf("Updated status for target %s, OID %s: %s",
			targetName, point.OIDName, string(messageJSON))
	}
}

// defaultCollectorFactory implements CollectorFactory.
type defaultCollectorFactory struct{}

func (*defaultCollectorFactory) CreateCollector(target *Target) (Collector, error) {
	return NewCollector(target)
}

// defaultAggregatorFactory implements AggregatorFactory.
type defaultAggregatorFactory struct{}

// CreateAggregator creates a new Aggregator with the given interval and max points per series to store.
func (*defaultAggregatorFactory) CreateAggregator(interval time.Duration, maxPoints int) (Aggregator, error) {
	return NewAggregator(interval, maxPoints), nil
}
