/*
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
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Check implements the checker interface by returning the overall status of all SNMP targets.
func (s *SNMPService) Check(ctx context.Context) (available bool, msg string) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Re-using the GetStatus logic to get the detailed map
	statusMap, err := s.GetStatus(ctx)
	if err != nil {
		return false, string(jsonError(fmt.Sprintf("Error getting detailed SNMP status: %v", err)))
	}

	// Marshal the status map to JSON for the message content
	statusJSON, err := json.Marshal(statusMap)
	if err != nil {
		return false, string(jsonError(fmt.Sprintf("Error marshaling SNMP status to JSON: %v", err)))
	}

	// Determine overall availability
	overallAvailable := true

	for _, targetStatus := range statusMap {
		if !targetStatus.Available {
			overallAvailable = false
			break
		}
	}

	// Always return the marshaled JSON in the message, regardless of overall availability
	return overallAvailable, string(statusJSON)
}

// NewSNMPService creates a new SNMP monitoring service.
func NewSNMPService(config *SNMPConfig, log logger.Logger) (*SNMPService, error) {
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidConfig, err)
	}

	service := &SNMPService{
		collectors:  make(map[string]Collector),
		aggregators: make(map[string]Aggregator),
		config:      config,
		done:        make(chan struct{}),
		status:      make(map[string]TargetStatus),
		logger:      log,
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

	s.logger.Info().Int("target_count", len(s.config.Targets)).Msg("Starting SNMP Service")

	// Initialize collectors for each target using indexing to avoid copying
	for i := range s.config.Targets {
		target := &s.config.Targets[i] // Get pointer to target
		s.logger.Info().
			Str("target_name", target.Name).
			Str("target_host", target.Host).
			Int("oid_count", len(target.OIDs)).
			Msg("Initializing target")

		if err := s.initializeTarget(ctx, target); err != nil {
			return fmt.Errorf("failed to initialize target %s: %w", target.Name, err)
		}
	}

	s.logger.Info().Int("collector_count", len(s.collectors)).Msg("SNMP Service started")

	return nil
}

// Stop shuts down the SNMP service and all its collectors.
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

	s.logger.Debug().Int("collector_count", len(s.collectors)).Msg("SNMP GetStatus called")

	status := make(map[string]TargetStatus)

	// Check each collector's status
	for name, collector := range s.collectors {
		s.logger.Debug().Str("collector_name", name).Msg("Getting status for collector")

		collectorStatus := collector.GetStatus()
		s.logger.Debug().Str("collector_name", name).Interface("status", collectorStatus).Msg("Collector status")

		// Merge collector status with service status to preserve HostIP and HostName
		if serviceStatus, exists := s.status[name]; exists {
			s.logger.Debug().
				Str("target_name", name).
				Str("host_ip", serviceStatus.HostIP).
				Str("host_name", serviceStatus.HostName).
				Msg("Merging status")
			// Use service status as base and update with collector data
			mergedStatus := serviceStatus
			mergedStatus.Available = collectorStatus.Available
			mergedStatus.LastPoll = collectorStatus.LastPoll
			mergedStatus.OIDStatus = collectorStatus.OIDStatus
			mergedStatus.Error = collectorStatus.Error
			// HostIP and HostName are preserved from serviceStatus

			status[name] = mergedStatus
			s.logger.Debug().
				Str("target_name", name).
				Str("host_ip", mergedStatus.HostIP).
				Str("host_name", mergedStatus.HostName).
				Msg("Merged status")
		} else {
			s.logger.Warn().Str("target_name", name).Msg("No service status found, using collector status only")
			// Fallback to collector status if service status doesn't exist
			status[name] = collectorStatus
		}
	}

	if len(status) == 0 {
		s.logger.Warn().Msg("No SNMP status found, checking configuration")
		s.logger.Debug().Interface("config", s.config).Msg("SNMPConfig")
	}

	return status, nil
}

// GetServiceStatus implements the proto.AgentServiceServer interface.
// This is the gRPC endpoint for status requests.
func (s *SNMPService) GetServiceStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	if req.ServiceType != "snmp" {
		return nil, fmt.Errorf("%w: %s", ErrInvalidServiceType, req.ServiceType)
	}

	status, err := s.GetStatus(ctx)
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   jsonError(fmt.Sprintf("Error getting status: %v", err)),
		}, nil
	}

	// Convert status to JSON for response
	statusJSON, err := json.Marshal(status)
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   jsonError(fmt.Sprintf("Error marshaling status: %v", err)),
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
		Message:     statusJSON, // Use []byte directly
		ServiceName: "snmp",
		ServiceType: "snmp",
	}, nil
}

// jsonError creates a JSON-encoded error message as []byte
func jsonError(msg string) []byte {
	data, _ := json.Marshal(map[string]string{"error": msg})
	return data
}

// initializeTarget sets up collector and aggregator for a target.
func (s *SNMPService) initializeTarget(ctx context.Context, target *Target) error {
	s.logger.Info().Str("target_name", target.Name).Msg("Creating collector for target")

	// Create collector
	collector, err := s.collectorFactory.CreateCollector(target, s.logger)
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateCollector, target.Name)
	}

	s.logger.Info().
		Str("target_name", target.Name).
		Dur("interval", time.Duration(target.Interval)).
		Msg("Creating aggregator for target")

	// Create aggregator
	aggregator, err := s.aggregatorFactory.CreateAggregator(time.Duration(target.Interval), target.MaxPoints)
	if err != nil {
		return fmt.Errorf("%w: %s", errFailedToCreateAggregator, target.Name)
	}

	// Start collector
	if err := collector.Start(ctx); err != nil {
		return fmt.Errorf("%w: %s", errFailedToStartCollector, target.Name)
	}

	s.logger.Info().Str("target_name", target.Name).Msg("Started collector for target")

	// Store components
	s.collectors[target.Name] = collector
	s.aggregators[target.Name] = aggregator

	// Initialize status
	s.status[target.Name] = TargetStatus{
		Available: true,
		LastPoll:  time.Now(),
		OIDStatus: make(map[string]OIDStatus),
		HostIP:    target.Host, // Actual IP address for device registration
		HostName:  target.Name, // Target name for display
		Target:    target,      // Include target configuration for internal use
	}

	s.logger.Info().
		Str("target_name", target.Name).
		Str("host_ip", target.Host).
		Str("host_name", target.Name).
		Msg("Initialized service status")

	// Start processing results
	go s.processResults(ctx, target.Name, collector, aggregator)

	s.logger.Info().Str("target_name", target.Name).Msg("Successfully initialized target")

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

		// Update hostname if this is the sysName OID
		if point.OIDName == ".1.3.6.1.2.1.1.5.0" || point.OIDName == "sysName" {
			if stringValue, ok := point.Value.(string); ok && stringValue != "" {
				s.logger.Info().
					Str("target_name", targetName).
					Str("old_hostname", status.HostName).
					Str("new_hostname", stringValue).
					Msg("Updating hostname")

				status.HostName = stringValue
			}
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
			s.logger.Error().Err(err).Msg("Error marshaling data point")
			return
		}

		s.logger.Debug().
			Str("target_name", targetName).
			Str("oid_name", point.OIDName).
			RawJSON("message", messageJSON).
			Msg("Updated status for target")
	}
}

// defaultCollectorFactory implements CollectorFactory.
type defaultCollectorFactory struct{}

func (*defaultCollectorFactory) CreateCollector(target *Target, log logger.Logger) (Collector, error) {
	return NewCollector(target, log)
}

// defaultAggregatorFactory implements AggregatorFactory.
type defaultAggregatorFactory struct{}

// CreateAggregator creates a new Aggregator with the given interval and max points per series to store.
func (*defaultAggregatorFactory) CreateAggregator(interval time.Duration, maxPoints int) (Aggregator, error) {
	return NewAggregator(interval, maxPoints), nil
}
