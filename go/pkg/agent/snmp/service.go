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

// Package snmp pkg/agent/snmp/service.go
package snmp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// ErrNilResultsChannel indicates the collector returned a nil results channel.
var ErrNilResultsChannel = errors.New("collector returned nil results channel")

// sysNameOID is SNMPv2-MIB::sysName.0; a polled value becomes the target's host name.
const sysNameOID = ".1.3.6.1.2.1.1.5.0"

type targetStatusSummary struct {
	Available  bool      `json:"available"`
	LastPoll   time.Time `json:"last_poll,omitempty"`
	ErrorCount int       `json:"error_count,omitempty"`
	Error      string    `json:"error,omitempty"`
	HostIP     string    `json:"host_ip,omitempty"`
	HostName   string    `json:"host_name,omitempty"`
	OIDCount   int       `json:"oid_count,omitempty"`
}

// Check implements the checker interface by returning the overall status of all SNMP targets.
func (s *SNMPService) Check(ctx context.Context) (available bool, msg string) {
	// NOTE: Avoid recursive RWMutex read locking. GetStatus performs its own locking and
	// Check must not hold a read lock while calling GetStatus, otherwise a waiting writer
	// can deadlock the service due to RWMutex write-preferring semantics.
	statusMap, err := s.GetStatus(ctx)
	if err != nil {
		return false, string(jsonError(fmt.Sprintf("Error getting detailed SNMP status: %v", err)))
	}

	// Status JSON is deliberately lightweight. Full OID values are shipped only
	// through the protobuf metric envelope drained by the agent push loop.
	statusJSON, err := json.Marshal(summarizeTargetStatuses(statusMap))
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

	return newSNMPServiceInternal(config, log), nil
}

// NewSNMPServiceForAgent creates a new SNMP monitoring service for agent use.
// This uses less strict validation that doesn't require NodeAddress, ListenAddr, and Partition.
func NewSNMPServiceForAgent(config *SNMPConfig, log logger.Logger) (*SNMPService, error) {
	if err := validateForAgent(config, log); err != nil {
		return nil, err
	}

	return newSNMPServiceInternal(config, log), nil
}

// validateForAgent applies the agent's target validation to config, dropping
// invalid targets.
//
// Rejections are logged whether or not validation ultimately succeeds. A
// dropped target is silent data loss otherwise: the service starts, reports
// healthy, and simply never polls that device.
func validateForAgent(config *SNMPConfig, log logger.Logger) error {
	rejections, err := config.ValidateForAgent()

	for _, rejection := range rejections {
		log.Warn().
			Int("target_index", rejection.Index).
			Str("target_name", rejection.Name).
			Str("target_host", rejection.Host).
			Err(rejection.Err).
			Msg("Dropping invalid SNMP target; remaining targets still poll")
	}

	if err != nil {
		return fmt.Errorf("%w: %w", errInvalidConfig, err)
	}

	return nil
}

// newSNMPServiceInternal creates the service without validation.
func newSNMPServiceInternal(config *SNMPConfig, log logger.Logger) *SNMPService {
	return &SNMPService{
		targets:           make(map[string]*targetRuntime),
		config:            config,
		done:              make(chan struct{}),
		logger:            log,
		collectorFactory:  &defaultCollectorFactory{sessions: newSessionSlots(maxOpenSessions)},
		aggregatorFactory: &defaultAggregatorFactory{},
	}
}

// Start implements the Service interface.
//
// A target that cannot be set up is reported as unavailable with the reason and
// the remaining targets still start: one bad target must not stop polling of
// every other one.
func (s *SNMPService) Start(ctx context.Context) error {
	s.logger.Info().Int("target_count", len(s.config.Targets)).Msg("Starting SNMP Service")

	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
		s.serviceCtx = nil

		// Ensure collectors from the previous run are stopped and cleared.
		s.stopTargetsLocked()
	}
	select {
	case <-s.done:
		s.done = make(chan struct{})
	default:
	}
	s.serviceCtx, s.cancel = context.WithCancel(ctx)
	s.mu.Unlock()

	failed := 0

	for i := range s.config.Targets {
		target := &s.config.Targets[i]
		s.logger.Info().
			Str("target_name", target.Name).
			Str("target_host", target.Host).
			Int("oid_count", len(target.OIDs)).
			Msg("Initializing target")

		if err := s.initializeTarget(target); err != nil {
			failed++
			s.recordFailedTarget(target, err)
		}
	}

	s.mu.RLock()
	targetCount := len(s.targets)
	s.mu.RUnlock()
	s.logger.Info().
		Int("target_count", targetCount).
		Int("failed_target_count", failed).
		Msg("SNMP Service started")

	return nil
}

// ReconfigureSummary counts what Reconfigure did to the running targets.
type ReconfigureSummary struct {
	Unchanged int // kept running: same collector, socket and poll schedule
	Restarted int // definition changed, so the collector was replaced
	Added     int
	Removed   int
}

// Reconfigure moves a started service to config, validated as for
// NewSNMPServiceForAgent.
//
// Only targets whose definition changed are touched. A target whose definition
// is identical keeps its collector, its socket, its in-flight requests and its
// poll phase. Stopping and restarting every collector on any change cancels
// in-flight requests and shifts every poll schedule, which leaves a gap in
// every series even when the target itself was not changed.
//
// A target that previously failed to start is retried. A config that fails
// validation leaves the running targets as they are. A service that was never
// started, or has been stopped, returns ErrServiceNotStarted.
func (s *SNMPService) Reconfigure(config *SNMPConfig) (ReconfigureSummary, error) {
	if err := validateForAgent(config, s.logger); err != nil {
		return ReconfigureSummary{}, err
	}

	desired := make(map[string]*Target, len(config.Targets))
	for i := range config.Targets {
		desired[config.Targets[i].Name] = &config.Targets[i]
	}

	var summary ReconfigureSummary

	s.mu.Lock()
	if s.serviceCtx == nil || s.serviceCtx.Err() != nil {
		s.mu.Unlock()
		return summary, ErrServiceNotStarted
	}

	keep := make(map[string]bool, len(s.targets))
	for name, rt := range s.targets {
		want, ok := desired[name]
		if ok && rt.collector != nil && reflect.DeepEqual(*rt.target, *want) {
			keep[name] = true
			summary.Unchanged++
			continue
		}

		if rt.collector != nil {
			if err := rt.collector.Stop(); err != nil {
				s.logger.Warn().Err(err).Str("target_name", name).Msg("Failed to stop collector")
			}
		}
		delete(s.targets, name)

		if ok {
			summary.Restarted++
		} else {
			summary.Removed++
		}
	}

	s.config = config
	s.mu.Unlock()

	for i := range config.Targets {
		target := &config.Targets[i]
		if keep[target.Name] {
			continue
		}

		if err := s.initializeTarget(target); err != nil {
			s.recordFailedTarget(target, err)
		}
	}

	summary.Added = len(config.Targets) - summary.Unchanged - summary.Restarted

	return summary, nil
}

// Stop shuts down the SNMP service and all its collectors.
func (s *SNMPService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cancel != nil {
		s.cancel()
	}

	select {
	case <-s.done:
		// Already stopped
	default:
		close(s.done)
	}

	if errs := s.stopTargetsLocked(); len(errs) > 0 {
		return fmt.Errorf("%w: %v", ErrStoppingCollectors, errs)
	}

	return nil
}

// stopTargetsLocked stops every collector and forgets every target. The caller
// holds s.mu.
func (s *SNMPService) stopTargetsLocked() []error {
	var errs []error

	for name, rt := range s.targets {
		if rt.collector == nil {
			continue
		}

		if err := rt.collector.Stop(); err != nil {
			s.logger.Warn().Err(err).Str("target_name", name).Msg("Failed to stop collector")
			errs = append(errs, fmt.Errorf("failed to stop collector %s: %w", name, err))
		}
	}

	s.targets = make(map[string]*targetRuntime)

	return errs
}

// AddTarget implements the Service interface.
func (s *SNMPService) AddTarget(ctx context.Context, target *Target) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := s.initializeTarget(target); err != nil {
		return fmt.Errorf("%w: %w", errFailedToInitTarget, err)
	}

	return nil
}

// RemoveTarget implements the Service interface.
func (s *SNMPService) RemoveTarget(targetName string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	rt, exists := s.targets[targetName]
	if !exists {
		return fmt.Errorf("%w: %s", ErrTargetNotFound, targetName)
	}

	if rt.collector != nil {
		if err := rt.collector.Stop(); err != nil {
			return fmt.Errorf("%w: %s", errFailedToStopCollector, targetName)
		}
	}

	delete(s.targets, targetName)

	return nil
}

// runningTargets returns the current targets without holding s.mu afterwards.
func (s *SNMPService) runningTargets() []*targetRuntime {
	s.mu.RLock()
	defer s.mu.RUnlock()

	runtimes := make([]*targetRuntime, 0, len(s.targets))
	for _, rt := range s.targets {
		runtimes = append(runtimes, rt)
	}

	return runtimes
}

// GetStatus implements the Service interface.
func (s *SNMPService) GetStatus(_ context.Context) (map[string]TargetStatus, error) {
	runtimes := s.runningTargets()

	s.logger.Debug().Int("target_count", len(runtimes)).Msg("SNMP GetStatus called")

	status := make(map[string]TargetStatus, len(runtimes))
	for _, rt := range runtimes {
		status[rt.target.Name] = rt.status()
	}

	if len(status) == 0 {
		s.logger.Warn().Msg("No SNMP status found, checking configuration")
		s.logger.Debug().Interface("config", s.config).Msg("SNMPConfig")
	}

	return status, nil
}

// DrainMetrics implements the MetricProvider interface. Each target's
// aggregator is drained on its own, so a drain never blocks another target's
// results.
//
// The result is keyed by metric key ("<target>|<oid name>"). A drain visits
// only the series written since the previous drain, and each series builds its
// key once, when it is created, so the cost of a drain follows the points it
// moves, not the number of series.
func (s *SNMPService) DrainMetrics(_ context.Context) (map[string][]DataPoint, error) {
	allMetrics := make(map[string][]DataPoint, s.lastDrainSize.Load())

	for _, rt := range s.runningTargets() {
		if rt.aggregator == nil {
			continue
		}

		rt.aggregator.DrainInto(allMetrics)
	}

	s.lastDrainSize.Store(int64(len(allMetrics)))

	return allMetrics, nil
}

// metricKey is the key of one target's series in the DrainMetrics result. The
// agent push loop splits it at the first "|".
func metricKey(targetName, oidName string) string {
	return targetName + "|" + oidName
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

	// Convert summary status to JSON for response. Full OID values are shipped
	// only through the protobuf metric envelope drained by the agent push loop.
	statusJSON, err := json.Marshal(summarizeTargetStatuses(status))
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

func summarizeTargetStatuses(statusMap map[string]TargetStatus) map[string]targetStatusSummary {
	if len(statusMap) == 0 {
		return nil
	}

	summaries := make(map[string]targetStatusSummary, len(statusMap))
	for targetName, targetStatus := range statusMap {
		summary := targetStatusSummary{
			Available: targetStatus.Available,
			LastPoll:  targetStatus.LastPoll,
			Error:     targetStatus.Error,
			HostIP:    targetStatus.HostIP,
			HostName:  targetStatus.HostName,
			OIDCount:  len(targetStatus.OIDStatus),
		}

		for _, oidStatus := range targetStatus.OIDStatus {
			summary.ErrorCount += oidStatus.ErrorCount
		}

		summaries[targetName] = summary
	}

	return summaries
}

// initializeTarget sets up collector and aggregator for a target.
func (s *SNMPService) initializeTarget(target *Target) error {
	s.logger.Info().Str("target_name", target.Name).Msg("Creating collector for target")

	// Create collector
	collector, err := s.collectorFactory.CreateCollector(target, s.logger)
	if err != nil {
		return fmt.Errorf("%w %s: %w", errFailedToCreateCollector, target.Name, err)
	}

	s.logger.Info().
		Str("target_name", target.Name).
		Dur("interval", time.Duration(target.Interval)).
		Msg("Creating aggregator for target")

	// Create aggregator
	aggregator, err := s.aggregatorFactory.CreateAggregator(target.Name, time.Duration(target.Interval), target.MaxPoints)
	if err != nil {
		return fmt.Errorf("%w %s: %w", errFailedToCreateAggregator, target.Name, err)
	}

	s.mu.RLock()
	serviceCtx := s.serviceCtx
	s.mu.RUnlock()
	if serviceCtx == nil {
		return ErrServiceNotStarted
	}

	// Start collector with the service context so it stops on service shutdown.
	if err := collector.Start(serviceCtx); err != nil {
		return fmt.Errorf("%w %s: %w", errFailedToStartCollector, target.Name, err)
	}

	s.logger.Info().Str("target_name", target.Name).Msg("Started collector for target")

	// Start processing results
	results := collector.GetResults()
	if results == nil {
		if err := collector.Stop(); err != nil {
			s.logger.Warn().Err(err).Str("target_name", target.Name).Msg("Failed to stop collector after nil results channel")
		}
		return ErrNilResultsChannel
	}

	rt := &targetRuntime{
		target:     target,
		collector:  collector,
		aggregator: aggregator,
		hostName:   target.Name, // Target name for display until sysName is polled
	}

	// Store components
	s.mu.Lock()
	if _, exists := s.targets[target.Name]; exists {
		s.mu.Unlock()
		if err := collector.Stop(); err != nil {
			s.logger.Warn().Err(err).Str("target_name", target.Name).Msg("Failed to stop duplicate collector")
		}
		return fmt.Errorf("%w: %s", ErrTargetExists, target.Name)
	}
	s.targets[target.Name] = rt
	s.mu.Unlock()

	s.logger.Info().
		Str("target_name", target.Name).
		Str("host_ip", target.Host).
		Str("host_name", target.Name).
		Msg("Initialized service status")

	go s.processResults(serviceCtx, rt, results)

	s.logger.Info().Str("target_name", target.Name).Msg("Successfully initialized target")

	return nil
}

// recordFailedTarget keeps a target that could not start in the status, as
// unavailable with the reason, so it is reported rather than silently missing.
func (s *SNMPService) recordFailedTarget(target *Target, err error) {
	s.logger.Error().
		Err(err).
		Str("target_name", target.Name).
		Str("target_host", target.Host).
		Msg("Failed to initialize SNMP target; remaining targets still poll")

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.targets[target.Name]; exists {
		return
	}

	s.targets[target.Name] = &targetRuntime{
		target:   target,
		startErr: err.Error(),
		hostName: target.Name,
	}
}

// processResults handles the data points from a collector.
func (s *SNMPService) processResults(ctx context.Context, rt *targetRuntime, results <-chan DataPoint) {
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

			s.handleDataPoint(rt, &point)
		}
	}
}

// handleDataPoint processes a single data point. It touches only the target's
// own state.
func (s *SNMPService) handleDataPoint(rt *targetRuntime, point *DataPoint) {
	rt.aggregator.AddPoint(point)

	// Update hostname if this is the sysName OID
	if point.OIDName != sysNameOID && point.OIDName != "sysName" {
		return
	}

	if hostName, ok := point.Value.(string); ok && hostName != "" {
		if previous, changed := rt.setHostName(hostName); changed {
			s.logger.Info().
				Str("target_name", rt.target.Name).
				Str("old_hostname", previous).
				Str("new_hostname", hostName).
				Msg("Updating hostname")
		}
	}
}

// setHostName records the target's polled sysName and reports the previous
// value when it changed.
func (rt *targetRuntime) setHostName(hostName string) (previous string, changed bool) {
	rt.mu.Lock()
	defer rt.mu.Unlock()

	previous = rt.hostName
	rt.hostName = hostName

	return previous, previous != hostName
}

// status merges the collector's poll state with the target's identity.
func (rt *targetRuntime) status() TargetStatus {
	rt.mu.Lock()
	hostName := rt.hostName
	rt.mu.Unlock()

	var status TargetStatus
	if rt.collector != nil {
		status = rt.collector.GetStatus()
	} else {
		status = TargetStatus{
			Available: false,
			Error:     rt.startErr,
			OIDStatus: make(map[string]OIDStatus),
		}
	}

	status.HostIP = rt.target.Host // Actual IP address for device registration
	status.HostName = hostName
	status.Target = rt.target // Include target configuration for internal use

	return status
}

// defaultCollectorFactory implements CollectorFactory. Its collectors share one
// bound on open SNMP sessions.
type defaultCollectorFactory struct {
	sessions sessionSlots
}

func (f *defaultCollectorFactory) CreateCollector(target *Target, log logger.Logger) (Collector, error) {
	return newCollector(target, log, f.sessions)
}

// defaultAggregatorFactory implements AggregatorFactory.
type defaultAggregatorFactory struct{}

// CreateAggregator creates a new Aggregator for one target's series with the given interval and max points per series to store.
func (*defaultAggregatorFactory) CreateAggregator(targetName string, interval time.Duration, maxPoints int) (Aggregator, error) {
	return NewAggregator(targetName, interval, maxPoints), nil
}
