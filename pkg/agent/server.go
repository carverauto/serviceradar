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

// Package agent pkg/agent/server.go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
)

var (
	// ErrAgentIDRequired indicates agent_id is required in configuration
	ErrAgentIDRequired = errors.New("agent_id is required in configuration")
)

const (
	defaultPartition   = "default"
	sweepType          = "sweep"
	defaultErrChansize = 10
)

// safeIntToInt32 safely converts an int to int32, capping at int32 max value
func safeIntToInt32(val int) int32 {
	if val > math.MaxInt32 {
		return math.MaxInt32
	}

	if val < math.MinInt32 {
		return math.MinInt32
	}

	return int32(val)
}

// NewServer initializes a new Server instance.
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig, log logger.Logger) (*Server, error) {
	cfgLoader := config.NewConfig(log)

	s := initializeServer(configDir, cfg, log)

	s.createSweepService = func(ctx context.Context, sweepConfig *SweepConfig) (Service, error) {
		return createSweepService(ctx, sweepConfig, cfg, log)
	}

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	// Initialize embedded sysmon service
	if err := s.initSysmonService(ctx); err != nil {
		log.Warn().Err(err).Msg("Failed to initialize sysmon service, continuing without it")
	}

	// Initialize embedded SNMP service
	if err := s.initSNMPService(ctx); err != nil {
		log.Warn().Err(err).Msg("Failed to initialize SNMP service, continuing without it")
	}

	// Initialize embedded dusk service
	if err := s.initDuskService(ctx); err != nil {
		log.Warn().Err(err).Msg("Failed to initialize dusk service, continuing without it")
	}

	return s, nil
}

// initializeServer creates a new Server struct with default values.
func initializeServer(configDir string, cfg *ServerConfig, log logger.Logger) *Server {
	return &Server{
		configDir: configDir,
		services:  make([]Service, 0),
		errChan:   make(chan error, defaultErrChansize),
		done:      make(chan struct{}),
		config:    cfg,
		logger:    log,
	}
}

// createSweepService constructs a new SweepService instance.
func createSweepService(
	ctx context.Context,
	sweepConfig *SweepConfig,
	cfg *ServerConfig,
	log logger.Logger,
) (Service, error) {
	sweepModelConfig, err := buildSweepModelConfig(cfg, sweepConfig, log)
	if err != nil {
		return nil, err
	}

	return NewSweepService(ctx, sweepModelConfig, log)
}

func buildSweepModelConfig(cfg *ServerConfig, sweepConfig *SweepConfig, log logger.Logger) (*models.Config, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	if cfg == nil {
		return nil, ErrAgentIDRequired
	}

	// Validate required configuration
	partition := cfg.Partition
	if partition == "" {
		log.Warn().Msg("Partition not configured, using 'default'. Consider setting partition in agent config")
		partition = defaultPartition
	}

	if cfg.AgentID == "" {
		return nil, ErrAgentIDRequired
	}

	return &models.Config{
		Networks:      sweepConfig.Networks,
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		DeviceTargets: sweepConfig.DeviceTargets,
		Interval:      time.Duration(sweepConfig.Interval),
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       time.Duration(sweepConfig.Timeout),
		AgentID:       cfg.AgentID,
		GatewayID:     cfg.AgentID, // Use AgentID as GatewayID for now
		Partition:     partition,
		SweepGroupID:  sweepConfig.SweepGroupID,
		ConfigHash:    sweepConfig.ConfigHash,
	}, nil
}

func (s *Server) loadSweepService(
	ctx context.Context, cfgLoader *config.Config, filePath string,
) (Service, error) {
	var sweepConfig SweepConfig

	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			s.logger.Info().Str("path", filePath).Msg("Sweep config file not found, using defaults")
			sweepConfig = SweepConfig{}
		} else {
			return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
		}
	} else {
		s.logger.Info().Str("path", filePath).Msg("Loaded sweep config from file")
	}

	service, err := s.createSweepService(ctx, &sweepConfig)
	if err != nil {
		return nil, err
	}

	return service, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, sweepType, "sweep.json")

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, fileSweepConfigPath)
	if err != nil {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	return nil
}

// initSysmonService creates and initializes the embedded sysmon service.
func (s *Server) initSysmonService(ctx context.Context) error {
	sysmonSvc, err := NewSysmonService(SysmonServiceConfig{
		AgentID:   s.config.AgentID,
		Partition: s.config.Partition,
		ConfigDir: s.configDir,
		Logger:    s.logger,
	})
	if err != nil {
		return fmt.Errorf("failed to create sysmon service: %w", err)
	}

	// Start the sysmon service
	if err := sysmonSvc.Start(ctx); err != nil {
		return fmt.Errorf("failed to start sysmon service: %w", err)
	}

	s.sysmonService = sysmonSvc
	s.logger.Info().Msg("Sysmon service initialized and started")
	return nil
}

// GetSysmonStatus returns the current sysmon metrics if the service is running.
func (s *Server) GetSysmonStatus(ctx context.Context) (*sysmon.MetricSample, error) {
	s.mu.RLock()
	svc := s.sysmonService
	s.mu.RUnlock()

	if svc == nil || !svc.IsEnabled() {
		return nil, nil
	}

	return svc.GetLatestSample(), nil
}

// initSNMPService creates and initializes the embedded SNMP service.
func (s *Server) initSNMPService(ctx context.Context) error {
	snmpSvc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:   s.config.AgentID,
		Partition: s.config.Partition,
		ConfigDir: s.configDir,
		Logger:    s.logger,
	})
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Start the SNMP service
	if err := snmpSvc.Start(ctx); err != nil {
		return fmt.Errorf("failed to start SNMP service: %w", err)
	}

	s.snmpService = snmpSvc
	s.logger.Info().Msg("SNMP service initialized and started")
	return nil
}

// GetSNMPStatus returns the current SNMP status if the service is running.
func (s *Server) GetSNMPStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	svc := s.snmpService
	s.mu.RUnlock()

	if svc == nil || !svc.IsEnabled() {
		return nil, nil
	}

	return svc.GetStatus(ctx)
}

// initDuskService creates and initializes the embedded dusk service.
func (s *Server) initDuskService(ctx context.Context) error {
	duskSvc, err := NewDuskService(DuskServiceConfig{
		AgentID:   s.config.AgentID,
		Partition: s.config.Partition,
		ConfigDir: s.configDir,
		Logger:    s.logger,
	})
	if err != nil {
		return fmt.Errorf("failed to create dusk service: %w", err)
	}

	// Start the dusk service
	if err := duskSvc.Start(ctx); err != nil {
		return fmt.Errorf("failed to start dusk service: %w", err)
	}

	s.duskService = duskSvc
	s.logger.Info().Msg("Dusk service initialized and started")
	return nil
}

// GetDuskStatus returns the current dusk status if the service is running.
func (s *Server) GetDuskStatus(ctx context.Context) (*proto.StatusResponse, error) {
	s.mu.RLock()
	svc := s.duskService
	s.mu.RUnlock()

	if svc == nil || !svc.IsEnabled() {
		return nil, nil
	}

	return svc.GetStatus(ctx)
}

// Start initializes and starts all agent services.
func (s *Server) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting agent service...")

	s.logger.Info().Int("services", len(s.services)).Msg("Found services to start")

	for i, svc := range s.services {
		s.logger.Info().Int("index", i).Str("service", svc.Name()).Msg("Starting service")

		go func(svc Service) { // Run in goroutine to avoid blocking
			if err := svc.Start(ctx); err != nil {
				s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service")
			} else {
				s.logger.Info().Str("service", svc.Name()).Msg("Service started successfully")
			}
		}(svc)
	}

	return nil
}

// Stop gracefully shuts down all agent services.
func (s *Server) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping agent service...")

	// Stop sysmon service if running
	if s.sysmonService != nil {
		if err := s.sysmonService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop sysmon service")
		}
	}

	// Stop SNMP service if running
	if s.snmpService != nil {
		if err := s.snmpService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop SNMP service")
		}
	}

	// Stop dusk service if running
	if s.duskService != nil {
		if err := s.duskService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop dusk service")
		}
	}

	// Stop mapper service if running
	if s.mapperService != nil {
		if err := s.mapperService.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Msg("Failed to stop mapper service")
		}
	}

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to stop service")
		}
	}

	close(s.done)

	return nil
}

// UpdateConfig applies logging/security updates at runtime where possible.
// Security changes typically require a restart to fully apply to gRPC servers/clients.
func (s *Server) UpdateConfig(newCfg *ServerConfig) {
	if newCfg == nil {
		return
	}
	// Apply logging level changes if provided
	if newCfg.Logging != nil {
		lvl := strings.ToLower(newCfg.Logging.Level)
		switch lvl {
		case "debug":
			s.logger.SetDebug(true)
		case "info", "":
			s.logger.SetDebug(false)
		}
		s.logger.Info().Str("level", newCfg.Logging.Level).Msg("Agent logger level updated")
	}
	// Security changes: log advisory; full restart may be required
	if newCfg.Security != nil && s.config.Security != nil {
		// naive compare of cert paths
		if newCfg.Security.TLS != s.config.Security.TLS || newCfg.Security.Mode != s.config.Security.Mode {
			s.logger.Warn().Msg("Security config changed; restart recommended to apply TLS changes")
		}
	}
	s.config = newCfg
}

// RestartServices stops and starts all managed services using the current configuration.
func (s *Server) RestartServices(ctx context.Context) {
	s.logger.Info().Msg("Restarting agent services due to config changes")
	for _, svc := range s.services {
		if err := svc.Stop(ctx); err != nil {
			s.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to stop service during restart")
		}
	}
	for _, svc := range s.services {
		if err := svc.Start(ctx); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to start service during restart")
		} else {
			s.logger.Info().Str("service", svc.Name()).Msg("Service restarted")
		}
	}
}

// SecurityConfig returns the server's security configuration.
func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

// Error implements the error interface for ServiceError.
func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %s error: %v", e.ServiceName, e.Err)
}

// GetStatus handles status requests for various service types.
func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	// Ensure AgentId and GatewayId are set
	if req.AgentId == "" {
		req.AgentId = s.config.AgentID
	}

	if req.GatewayId == "" {
		// Internal calls (e.g., from push loop) don't have GatewayId set - this is expected
		req.GatewayId = "internal" // Mark as internal call
	}

	var response *proto.StatusResponse

	switch {
	case isICMPRequest(req):
		response, _ = s.handleICMPCheck(ctx, req)
	case isSweepRequest(req):
		response, _ = s.getSweepStatus(ctx)
	case req.ServiceType == SNMPServiceType:
		response, _ = s.GetSNMPStatus(ctx)
	case req.ServiceType == DuskServiceType:
		response, _ = s.GetDuskStatus(ctx)
	default:
		return nil, status.Errorf(
			codes.Unimplemented, "GetStatus not supported for service type '%s'", req.ServiceType,
		)
	}

	// Include AgentID in the response
	if response != nil {
		response.AgentId = s.config.AgentID
		if response.GatewayId == "" {
			response.GatewayId = req.GatewayId
		}

		response.Available = true
	}

	return response, nil
}

// GetResults implements the AgentService GetResults method.
// For grpc services, this forwards the call to the actual service.
// For sweep services, this calls the local sweep service.
// For other services, this returns a "not supported" response.
// GetResults handles results requests for various service types.
func (s *Server) GetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("serviceType", req.ServiceType).Msg("GetResults called")

	// Handle sweep services with local implementation
	if req.ServiceType == sweepType {
		return s.handleSweepGetResults(ctx, req)
	}

	// For non-grpc services, return "not supported"
	s.logger.Info().Str("serviceType", req.ServiceType).Msg("GetResults not supported for service type")

	return nil, status.Errorf(codes.Unimplemented, "GetResults not supported for service type '%s'", req.ServiceType)
}

// StreamResults implements the AgentService StreamResults method for large datasets.
// For sweep services, this calls the local sweep service and streams the results.
// For grpc services, this forwards the streaming call to the actual service.
// For other services, this returns a "not supported" response.
// StreamResults handles streaming results requests for large datasets.
func (s *Server) StreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("serviceType", req.ServiceType).Msg("StreamResults called")

	// Handle sweep services with local implementation
	if req.ServiceType == sweepType {
		return s.handleSweepStreamResults(req, stream)
	}

	// For non-grpc services, return "not supported"
	s.logger.Info().Str("serviceType", req.ServiceType).Msg("StreamResults not supported for service type")

	return status.Errorf(codes.Unimplemented, "StreamResults not supported for service type '%s'", req.ServiceType)
}

// findSweepService finds the first sweep service from the server's services
func (s *Server) findSweepService() *SweepService {
	for _, svc := range s.services {
		if sweepSvc, ok := svc.(*SweepService); ok {
			return sweepSvc
		}
	}

	return nil
}

// sendEmptyChunk sends an empty final chunk when there's no new data
func (*Server) sendEmptyChunk(stream proto.AgentService_StreamResultsServer, response *proto.ResultsResponse) error {
	return stream.Send(&proto.ResultsChunk{
		Data:            []byte("{}"),
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	})
}

// sendSingleChunk sends a single chunk when data fits in one chunk
func (*Server) sendSingleChunk(stream proto.AgentService_StreamResultsServer, response *proto.ResultsResponse) error {
	return stream.Send(&proto.ResultsChunk{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	})
}

// streamMultipleChunks handles streaming when data needs to be split into multiple chunks
func (s *Server) streamMultipleChunks(
	stream proto.AgentService_StreamResultsServer,
	response *proto.ResultsResponse,
	sweepData map[string]interface{},
	hosts []interface{},
) error {
	maxChunkSize, maxHostsPerChunk := sweepResultsChunkLimits()

	totalHosts := len(hosts)

	metadata := make(map[string]interface{})
	for key, value := range sweepData {
		if key != "hosts" {
			metadata[key] = value
		}
	}

	baseData := make(map[string]interface{}, len(metadata))
	for key, value := range metadata {
		baseData[key] = value
	}
	baseData["hosts"] = []interface{}{}

	baseBytes, err := json.Marshal(baseData)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to marshal sweep metadata for chunk sizing")
		return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
	}

	baseSize := len(baseBytes) - 2
	if baseSize < 0 {
		baseSize = len(baseBytes)
	}

	hostSizes := make([]int, totalHosts)
	for i, host := range hosts {
		hostBytes, err := json.Marshal(host)
		if err != nil {
			s.logger.Error().Err(err).Int("host_index", i).Msg("Failed to marshal sweep host for chunk sizing")
			return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
		}
		hostSizes[i] = len(hostBytes)
	}

	type hostRange struct {
		start int
		end   int
	}

	var ranges []hostRange
	start := 0
	currentSize := baseSize + 2

	for i, hostSize := range hostSizes {
		additional := hostSize
		if i > start {
			additional++
		}

		if (currentSize+additional > maxChunkSize || i-start >= maxHostsPerChunk) && i > start {
			ranges = append(ranges, hostRange{start: start, end: i})
			start = i
			currentSize = baseSize + 2
			additional = hostSize
		}

		currentSize += additional

		if currentSize > maxChunkSize && i == start {
			s.logger.Warn().
				Int("host_index", i).
				Int("host_size", hostSize).
				Int("max_chunk_bytes", maxChunkSize).
				Msg("Sweep host exceeds chunk size; sending oversized chunk")
		}
	}

	if start < totalHosts {
		ranges = append(ranges, hostRange{start: start, end: totalHosts})
	}

	totalChunks := len(ranges)

	for chunkIndex, chunkRange := range ranges {
		chunkHosts := hosts[chunkRange.start:chunkRange.end]

		chunkData := make(map[string]interface{}, len(metadata))
		for key, value := range metadata {
			chunkData[key] = value
		}
		chunkData["hosts"] = chunkHosts

		chunkBytes, err := json.Marshal(chunkData)
		if err != nil {
			s.logger.Error().Err(err).Int("chunk", chunkIndex).Msg("Failed to marshal chunk data")
			return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
		}

		chunk := &proto.ResultsChunk{
			Data:            chunkBytes,
			IsFinal:         chunkIndex == totalChunks-1,
			ChunkIndex:      safeIntToInt32(chunkIndex),
			TotalChunks:     safeIntToInt32(totalChunks),
			CurrentSequence: response.CurrentSequence,
			Timestamp:       response.Timestamp,
		}

		if err := stream.Send(chunk); err != nil {
			s.logger.Error().Err(err).Int("chunk", chunkIndex).Msg("Error sending sweep results chunk")
			return status.Errorf(codes.Internal, "Failed to send chunk: %v", err)
		}
	}

	s.logger.Info().
		Int("total_chunks", totalChunks).
		Int("total_hosts", totalHosts).
		Str("sequence", response.CurrentSequence).
		Msg("Completed streaming sweep results")

	return nil
}

// handleSweepStreamResults handles StreamResults calls for sweep services with chunking for large datasets.
func (s *Server) handleSweepStreamResults(req *proto.ResultsRequest, stream proto.AgentService_StreamResultsServer) error {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("lastSequence", req.LastSequence).Msg("Handling sweep StreamResults")

	// Find the sweep service
	sweepSvc := s.findSweepService()

	if sweepSvc == nil {
		s.logger.Error().Msg("No sweep service found for StreamResults")
		return status.Errorf(codes.NotFound, "No sweep service configured")
	}

	ctx := stream.Context()

	response, err := sweepSvc.GetSweepResults(ctx, req.LastSequence)
	if err != nil {
		s.logger.Error().Err(err).Msg("Failed to get sweep results for streaming")
		return status.Errorf(codes.Internal, "Failed to get sweep results: %v", err)
	}

	// Set AgentId and GatewayId from the request
	response.AgentId = s.config.AgentID
	response.GatewayId = req.GatewayId

	// If no new data, send empty final chunk
	if !response.HasNewData || len(response.Data) == 0 {
		return s.sendEmptyChunk(stream, response)
	}

	// Calculate chunk size to keep each chunk under ~1MB
	const maxChunkSize = 1024 * 1024 // 1MB

	totalBytes := len(response.Data)

	if totalBytes <= maxChunkSize {
		// Single chunk case
		return s.sendSingleChunk(stream, response)
	}

	// Multi-chunk case: Parse JSON and chunk by complete elements to avoid corruption
	var sweepData map[string]interface{}
	if err := json.Unmarshal(response.Data, &sweepData); err != nil {
		s.logger.Error().Err(err).Msg("Failed to parse sweep data for chunking")
		return status.Errorf(codes.Internal, "Failed to parse sweep data: %v", err)
	}

	// Extract hosts array from the sweep data
	hostsInterface, ok := sweepData["hosts"]
	if !ok {
		s.logger.Error().Msg("No hosts field found in sweep data")
		return status.Errorf(codes.Internal, "No hosts field found in sweep data")
	}

	hosts, ok := hostsInterface.([]interface{})
	if !ok {
		s.logger.Error().Msg("Hosts field is not an array")
		return status.Errorf(codes.Internal, "Hosts field is not an array")
	}

	return s.streamMultipleChunks(stream, response, sweepData, hosts)
}

// handleSweepGetResults handles GetResults calls for sweep services.
func (s *Server) handleSweepGetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("lastSequence", req.LastSequence).Msg("Handling sweep GetResults")

	// Find the sweep service
	for _, svc := range s.services {
		sweepSvc, ok := svc.(*SweepService)
		if !ok {
			continue
		}

		response, err := sweepSvc.GetSweepResults(ctx, req.LastSequence)
		if err != nil {
			s.logger.Error().Err(err).Msg("Failed to get sweep results")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "Failed to get sweep results: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				GatewayId:   req.GatewayId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		// Set AgentId and GatewayId from the request
		response.AgentId = s.config.AgentID
		response.GatewayId = req.GatewayId

		// Ensure the initial sweep response (sequence 0) returns a JSON payload for clients that expect it.
		if !response.HasNewData && len(response.Data) == 0 && response.CurrentSequence == "0" {
			statusResp, statusErr := sweepSvc.GetStatus(ctx)
			if statusErr == nil && len(statusResp.Message) > 0 {
				var summary map[string]interface{}
				if err := json.Unmarshal(statusResp.Message, &summary); err == nil {
					if _, ok := summary["hosts"]; !ok {
						summary["hosts"] = []interface{}{}
					}
					if response.ExecutionId != "" {
						summary["execution_id"] = response.ExecutionId
					}
					if response.SweepGroupId != "" {
						summary["sweep_group_id"] = response.SweepGroupId
					}
					if resultData, err := json.Marshal(summary); err == nil {
						response.Data = resultData
					}
				}
			}

			if len(response.Data) == 0 {
				response.Data = []byte(`{"hosts":[]}`)
			}
		}

		return response, nil
	}

	s.logger.Error().Msg("No sweep service found")

	return &proto.ResultsResponse{
		Available:   false,
		Data:        []byte(`{"error": "No sweep service configured"}`),
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     s.config.AgentID,
		GatewayId:   req.GatewayId,
		Timestamp:   time.Now().Unix(),
	}, nil
}

func isICMPRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "icmp" && req.Details != ""
}

func isSweepRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == sweepType
}

func (s *Server) handleICMPCheck(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		sweepSvc, ok := svc.(*SweepService)
		if !ok {
			continue
		}

		result, err := sweepSvc.CheckICMP(ctx, req.Details)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", errICMPCheck, err)
		}

		resp := &ICMPResponse{
			Host:         result.Target.Host,
			ResponseTime: result.RespTime.Nanoseconds(),
			PacketLoss:   result.PacketLoss,
			Available:    result.Available,
		}

		jsonResp, _ := json.Marshal(resp)

		return &proto.StatusResponse{
			Available:    result.Available,
			Message:      jsonResp,
			ServiceName:  "icmp_check",
			ServiceType:  "icmp",
			ResponseTime: result.RespTime.Nanoseconds(),
			AgentId:      s.config.AgentID,
		}, nil
	}

	return nil, errNoSweepService
}

func (s *Server) getSweepStatus(ctx context.Context) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			return provider.GetStatus(ctx)
		}
	}

	message := jsonError("No sweep service configured")

	return &proto.StatusResponse{
		Available:   false,
		Message:     message,
		ServiceName: "network_sweep",
		ServiceType: sweepType,
		AgentId:     s.config.AgentID,
	}, nil
}

// Close gracefully shuts down the server and releases resources.
func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Error during stop")

		return err
	}

	close(s.errChan)

	return nil
}
