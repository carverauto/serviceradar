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
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	defaultTimeout     = 30 * time.Second
	jsonSuffix         = ".json"
	fallBackSuffix     = "fallback"
	grpcType           = "grpc"
	defaultErrChansize = 10
)

// NewServer initializes a new Server instance.
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig, log logger.Logger) (*Server, error) {
	cfgLoader := config.NewConfig(log)

	s := initializeServer(configDir, cfg, log)

	kvStore, err := setupKVStore(ctx, cfgLoader, cfg, log)
	if err != nil {
		return nil, err
	}

	s.kvStore = kvStore

	s.createSweepService = func(sweepConfig *SweepConfig, kvStore KVStore) (Service, error) {
		return createSweepService(sweepConfig, kvStore, cfg, log)
	}

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

// initializeServer creates a new Server struct with default values.
func initializeServer(configDir string, cfg *ServerConfig, log logger.Logger) *Server {
	return &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   cfg.ListenAddr,
		registry:     initRegistry(log),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		config:       cfg,
		connections:  make(map[string]*CheckerConnection),
		logger:       log,
	}
}

// setupKVStore configures the KV store if an address is provided.
func setupKVStore(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig, log logger.Logger) (KVStore, error) {
	if cfg.KVAddress == "" {
		log.Info().Msg("KVAddress not set, skipping KV store setup")
		return nil, nil
	}

	clientCfg := grpc.ClientConfig{
		Address:    cfg.KVAddress,
		MaxRetries: 3,
		Logger:     log,
	}

	securityConfig := cfg.Security
	if cfg.KVSecurity != nil {
		securityConfig = cfg.KVSecurity
	}

	if securityConfig == nil {
		return nil, errNoSecurityConfigKV
	}

	provider, err := grpc.NewSecurityProvider(ctx, securityConfig, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV security provider: %w", err)
	}

	clientCfg.SecurityProvider = provider

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create KV gRPC client: %w", err)
	}

	kvStore := &grpcKVStore{
		client: proto.NewKVServiceClient(client.GetConnection()),
		conn:   client,
	}

	if kvStore.client == nil {
		if err := client.Close(); err != nil {
			log.Error().Err(err).Msg("Error closing client")
			return nil, err
		}

		return nil, errFailedToInitializeKVClient
	}

	cfgLoader.SetKVStore(kvStore)

	return kvStore, nil
}

// createSweepService constructs a new SweepService instance.
func createSweepService(sweepConfig *SweepConfig, kvStore KVStore, cfg *ServerConfig, log logger.Logger) (Service, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	// Validate required configuration
	if cfg.Partition == "" {
		log.Warn().Msg("Partition not configured, using 'default'. Consider setting partition in agent config")

		cfg.Partition = "default"
	}

	if cfg.AgentID == "" {
		return nil, fmt.Errorf("agent_id is required in configuration")
	}

	c := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
		AgentID:     cfg.AgentID,
		PollerID:    cfg.AgentID, // Use AgentID as PollerID for now
		Partition:   cfg.Partition,
	}

	// Prioritize AgentID as the unique identifier for the KV path.
	// Fall back to AgentName if AgentID is not set.
	serverName := cfg.AgentName
	if cfg.AgentID != "" {
		serverName = cfg.AgentID
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	return NewSweepService(c, kvStore, configKey)
}

func (s *Server) loadSweepService(ctx context.Context, cfgLoader *config.Config, kvPath, filePath string) (Service, error) {
	var sweepConfig SweepConfig

	if service, err := s.tryLoadFromKV(ctx, kvPath, &sweepConfig); err == nil && service != nil {
		return service, nil
	}

	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
	}

	suffix := s.getLogSuffix()
	s.logger.Info().Str("path", filePath).Str("suffix", suffix).Msg("Loaded sweep config from file")

	service, err := s.createSweepService(&sweepConfig, s.kvStore) // Pass s.kvStore
	if err != nil {
		return nil, err
	}

	return service, nil
}

func (s *Server) tryLoadFromKV(ctx context.Context, kvPath string, sweepConfig *SweepConfig) (Service, error) {
	if s.kvStore == nil {
		s.logger.Info().Msg("KV store not initialized, skipping KV fetch for sweep config")
		return nil, nil
	}

	value, found, err := s.kvStore.Get(ctx, kvPath)
	if err != nil {
		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to get sweep config from KV")
		return nil, err
	}

	if !found {
		s.logger.Info().Str("kvPath", kvPath).Msg("Sweep config not found in KV")
		return nil, nil
	}

	if err = json.Unmarshal(value, sweepConfig); err != nil {
		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to unmarshal sweep config from KV")
		return nil, err
	}

	s.logger.Info().Str("kvPath", kvPath).Msg("Loaded sweep config from KV")

	service, err := s.createSweepService(sweepConfig, s.kvStore) // Pass s.kvStore
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service from KV config: %w", err)
	}

	return service, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")

	// Prioritize AgentID as the unique identifier for the KV path.
	// Fall back to AgentName if AgentID is not set.
	serverName := s.config.AgentName // Default to AgentName
	if s.config.AgentID != "" {
		serverName = s.config.AgentID // Prefer AgentID
	}

	if serverName == "" {
		s.logger.Warn().Msg("agent_id and agent_name are not set. KV paths for sweep config will be incorrect.")
	}

	kvSweepConfigPath := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, kvSweepConfigPath, fileSweepConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	return nil
}

// getLogSuffix returns appropriate suffix based on KV store availability.
func (s *Server) getLogSuffix() string {
	if s.kvStore != nil {
		return " " + fallBackSuffix
	}

	return ""
}

func (s *Server) Start(ctx context.Context) error {
	s.logger.Info().Msg("Starting agent service...")

	if err := s.initializeCheckers(ctx); err != nil {
		return fmt.Errorf("failed to initialize checkers: %w", err)
	}

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

func (s *Server) Stop(_ context.Context) error {
	s.logger.Info().Msg("Stopping agent service...")

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			s.logger.Error().Err(err).Str("service", svc.Name()).Msg("Failed to stop service")
		}
	}

	for name, conn := range s.connections {
		if err := conn.client.Close(); err != nil {
			s.logger.Error().Err(err).Str("checker", name).Msg("Error closing connection to checker")
		}
	}

	close(s.done)

	return nil
}

func (s *Server) ListenAddr() string {
	return s.config.ListenAddr
}

func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %s error: %v", e.ServiceName, e.Err)
}

func (s *Server) initializeCheckers(ctx context.Context) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	s.connections = make(map[string]*CheckerConnection)

	cfgLoader := config.NewConfig(s.logger)

	if s.kvStore != nil {
		cfgLoader.SetKVStore(s.kvStore)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			s.logger.Warn().Err(err).Str("file", file.Name()).Msg("Failed to load checker config")

			continue
		}

		// Validate required fields
		if conf.Name == "" {
			s.logger.Warn().Str("file", file.Name()).Msg("Skipping checker config with empty name")
			continue
		}

		if conf.Type == "" {
			s.logger.Warn().Str("file", file.Name()).Str("name", conf.Name).Msg("Skipping checker config with empty type")
			continue
		}

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, conf)
			if err != nil {
				s.logger.Warn().Err(err).Str("checker", conf.Name).Msg("Failed to connect to checker")
				continue
			}

			s.connections[conf.Name] = conn
		}

		s.checkerConfs[conf.Name] = conf

		s.logger.Info().Str("name", conf.Name).Str("type", conf.Type).Msg("Loaded checker config")
	}

	return nil
}

func (c *CheckerConnection) EnsureConnected(ctx context.Context) (*grpc.Client, error) {
	c.mu.RLock()
	if c.healthy && c.client != nil {
		c.mu.RUnlock()
		return c.client, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after locking
	if c.healthy && c.client != nil {
		return c.client, nil
	}

	// Close existing connection if it exists
	if c.client != nil {
		_ = c.client.Close()
	}

	clientCfg := grpc.ClientConfig{
		Address:    c.address,
		MaxRetries: 3,
		Logger:     c.logger,
	}

	// Add security provider as needed
	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		c.healthy = false

		return nil, fmt.Errorf("failed to reconnect to %s: %w", c.serviceName, err)
	}

	c.client = client
	c.healthy = true

	return client, nil
}

func (s *Server) connectToChecker(ctx context.Context, checkerConfig *CheckerConfig) (*CheckerConnection, error) {
	clientCfg := grpc.ClientConfig{
		Address:    checkerConfig.Address,
		MaxRetries: 3,
		Logger:     s.logger,
	}

	if s.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, s.config.Security, s.logger)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	s.logger.Info().Str("service", checkerConfig.Name).Str("address", checkerConfig.Address).Msg("Connecting to checker service")

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to checker %s: %w", checkerConfig.Name, err)
	}

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
		logger:      s.logger,
	}, nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	// Ensure AgentId and PollerId are set
	if req.AgentId == "" {
		req.AgentId = s.config.AgentID
	}

	if req.PollerId == "" {
		s.logger.Warn().Interface("request", req).Msg("PollerId is empty in request")
		req.PollerId = "unknown-poller" // Fallback to avoid empty
	}

	var response *proto.StatusResponse

	switch {
	case isRperfCheckerRequest(req):
		response, _ = s.handleRperfChecker(ctx, req)
	case isICMPRequest(req):
		response, _ = s.handleICMPCheck(ctx, req)
	case isSweepRequest(req):
		response, _ = s.getSweepStatus(ctx)
	default:
		response, _ = s.handleDefaultChecker(ctx, req)
	}

	// Include AgentID in the response
	if response != nil {
		response.AgentId = s.config.AgentID
		if response.PollerId == "" {
			response.PollerId = req.PollerId
		}

		response.Available = true
	}

	return response, nil
}

// GetResults implements the AgentService GetResults method.
// For grpc services, this forwards the call to the actual service.
// For other services, this returns a "not supported" response.
func (s *Server) GetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.logger.Info().Str("serviceName", req.ServiceName).Str("serviceType", req.ServiceType).Msg("GetResults called")

	// Handle grpc services by forwarding the call
	if req.ServiceType == "grpc" {
		return s.handleGrpcGetResults(ctx, req)
	}

	// For non-grpc services, return "not supported"
	s.logger.Info().Str("serviceType", req.ServiceType).Msg("GetResults not supported for service type")

	return nil, status.Errorf(codes.Unimplemented, "GetResults not supported for service type '%s'", req.ServiceType)
}

// handleGrpcGetResults forwards GetResults calls to grpc services.
// This works similarly to handleDefaultChecker but for GetResults calls.
func (s *Server) handleGrpcGetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	// Convert ResultsRequest to StatusRequest to reuse existing getChecker logic
	statusReq := &proto.StatusRequest{
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
		Details:     req.Details,
	}

	// Use the same getChecker lookup logic as GetStatus
	statusReq.AgentId = s.config.AgentID

	getChecker, err := s.getChecker(ctx, statusReq)
	if err != nil {
		s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Failed to get getChecker for service")

		return &proto.ResultsResponse{
			Available:   false,
			Data:        []byte(fmt.Sprintf(`{"error": "Failed to get getChecker: %v"}`, err)),
			ServiceName: req.ServiceName,
			ServiceType: req.ServiceType,
			AgentId:     s.config.AgentID,
			PollerId:    req.PollerId,
			Timestamp:   time.Now().Unix(),
		}, nil
	}

	// For grpc checkers, we need to call GetResults on the underlying service
	// First check if the getChecker is a grpc getChecker that supports GetResults
	if externalChecker, ok := getChecker.(*ExternalChecker); ok {
		// Forward GetResults to the external grpc service
		s.logger.Info().Str("serviceName", req.ServiceName).Str("details", req.Details).Msg("Forwarding GetResults call to service")

		err := externalChecker.ensureConnected(ctx)
		if err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("Failed to connect to grpc service")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "Failed to connect to service: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				PollerId:    req.PollerId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		grpcClient := proto.NewAgentServiceClient(externalChecker.grpcClient.GetConnection())

		// Forward the GetResults call
		response, err := grpcClient.GetResults(ctx, req)
		if err != nil {
			s.logger.Error().Err(err).Str("serviceName", req.ServiceName).Msg("GetResults call to service failed")

			return &proto.ResultsResponse{
				Available:   false,
				Data:        []byte(fmt.Sprintf(`{"error": "GetResults call failed: %v"}`, err)),
				ServiceName: req.ServiceName,
				ServiceType: req.ServiceType,
				AgentId:     s.config.AgentID,
				PollerId:    req.PollerId,
				Timestamp:   time.Now().Unix(),
			}, nil
		}

		return response, nil
	}

	// If it's not a grpc getChecker, return not supported
	s.logger.Info().Str("checkerType", fmt.Sprintf("%T", getChecker)).Msg("GetResults not supported for getChecker type")

	return nil, status.Errorf(codes.Unimplemented, "GetResults not supported by getChecker type %T", getChecker)
}

func isRperfCheckerRequest(req *proto.StatusRequest) bool {
	return req.ServiceName == "rperf-checker" && req.ServiceType == "grpc"
}

func isICMPRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "icmp" && req.Details != ""
}

func isSweepRequest(req *proto.StatusRequest) bool {
	return req.ServiceType == "sweep"
}

var (
	errNotExternalChecker = errors.New("checker is not an ExternalChecker")
)

func (s *Server) handleRperfChecker(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to get rperf checker: %w", err)
	}

	extChecker, ok := c.(*ExternalChecker)
	if !ok {
		return nil, errNotExternalChecker
	}

	if err := extChecker.ensureConnected(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Failed to ensure connection for rperf-checker")

		return nil, fmt.Errorf("failed to ensure rperf-checker connection: %w", err)
	}

	agentClient := proto.NewAgentServiceClient(extChecker.grpcClient.GetConnection())

	return agentClient.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: "",
		ServiceType: "grpc",
		Details:     "",
		AgentId:     s.config.AgentID,
	})
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

func (s *Server) handleDefaultChecker(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	req.AgentId = s.config.AgentID

	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, err
	}

	available, message := c.Check(ctx, req)

	s.logger.Info().Str("type", req.GetServiceType()).Str("name", req.GetServiceName()).Str("details", req.GetDetails()).Msg("Checker request")

	if !json.Valid(message) {
		s.logger.Error().Str("serviceName", req.ServiceName).RawJSON("message", message).Msg("Invalid JSON from checker")
		return nil, fmt.Errorf("invalid JSON response from checker")
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     message, // json.RawMessage is []byte
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     req.AgentId,
		PollerId:    req.PollerId,
	}, nil
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
		ServiceType: "sweep",
		AgentId:     s.config.AgentID,
	}, nil
}

func (s *Server) loadCheckerConfig(ctx context.Context, cfgLoader *config.Config, filePath string) (*CheckerConfig, error) {
	var conf CheckerConfig

	// Determine KV path
	kvPath := filepath.Base(filePath)
	if s.config.AgentID != "" {
		kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, filepath.Base(filePath))
	}

	// Try KV if available
	var err error
	if s.kvStore != nil {
		if err = cfgLoader.LoadAndValidate(ctx, kvPath, &conf); err == nil {
			s.logger.Info().Str("kvPath", kvPath).Msg("Loaded checker config from KV")

			return s.applyCheckerDefaults(&conf), nil
		}

		s.logger.Error().Err(err).Str("kvPath", kvPath).Msg("Failed to load checker config from KV")
	}

	// Load from file (either directly or as fallback)
	if err = cfgLoader.LoadAndValidate(ctx, filePath, &conf); err != nil {
		return nil, fmt.Errorf("failed to load checker config %s: %w", filePath, err)
	}

	suffix := ""
	if s.kvStore != nil {
		suffix = " " + fallBackSuffix
	}

	s.logger.Info().Str("filePath", filePath).Str("suffix", suffix).Msg("Loaded checker config from file")

	return s.applyCheckerDefaults(&conf), nil
}

// applyCheckerDefaults sets default values for a CheckerConfig.
func (*Server) applyCheckerDefaults(conf *CheckerConfig) *CheckerConfig {
	if conf.Timeout == 0 {
		conf.Timeout = Duration(defaultTimeout)
	}

	if conf.Type == grpcType && conf.Address == "" {
		conf.Address = conf.ListenAddr
	}

	return conf
}

func (s *Server) loadCheckerConfigs(ctx context.Context, cfgLoader *config.Config) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		filePath := filepath.Join(s.configDir, file.Name())

		conf, err := s.loadCheckerConfig(ctx, cfgLoader, filePath)
		if err != nil {
			s.logger.Warn().Err(err).Str("file", file.Name()).Msg("Failed to load checker config")

			continue
		}

		// Validate required fields
		if conf.Name == "" {
			s.logger.Warn().Str("file", file.Name()).Msg("Skipping checker config with empty name")
			continue
		}

		if conf.Type == "" {
			s.logger.Warn().Str("file", file.Name()).Str("name", conf.Name).Msg("Skipping checker config with empty type")
			continue
		}

		s.checkerConfs[conf.Name] = conf

		s.logger.Info().Str("name", conf.Name).Str("type", conf.Type).Msg("Loaded checker config")
	}

	return nil
}

func (s *Server) getChecker(ctx context.Context, req *proto.StatusRequest) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	var check checker.Checker

	var err error

	if req.ServiceType == "icmp" {
		s.logger.Info().Str("host", req.Details).Msg("ICMP checker requested")

		host := req.Details
		if host == "" {
			host = "127.0.0.1"
		}

		// Construct device ID for the TARGET being pinged (partition:target_ip)
		var deviceID string

		if s.config.Partition != "" {
			deviceID = fmt.Sprintf("%s:%s", s.config.Partition, s.config.HostIP)
			s.logger.Info().
				Str("deviceID", deviceID).
				Str("partition", s.config.Partition).
				Str("targetIP", host).
				Msg("Creating ICMP checker with target device ID")
		} else {
			s.logger.Info().Str("partition", s.config.Partition).Msg("Creating ICMP checker without device ID - missing partition")
		}

		check, err = NewICMPCheckerWithDeviceID(host, deviceID)
	} else {
		// Use registry for other service types
		check, err = s.registry.Get(ctx, req.ServiceType, req.ServiceName, req.Details, s.config.Security)
	}

	if err != nil {
		s.logger.Error().Err(err).Str("key", key).Msg("Failed to create checker")
		return nil, fmt.Errorf("failed to create checker: %w", err)
	}

	s.checkers[key] = check

	s.logger.Info().Str("key", key).Msg("Cached new checker")

	return check, nil
}

func (s *Server) ListServices() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	services := make([]string, 0, len(s.checkerConfs))
	for name := range s.checkerConfs {
		services = append(services, name)
	}

	return services
}

func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Error during stop")

		return err
	}

	close(s.errChan)

	return nil
}
