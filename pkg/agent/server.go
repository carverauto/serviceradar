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
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultTimeout     = 30 * time.Second
	jsonSuffix         = ".json"
	fallBackSuffix     = "fallback"
	grpcType           = "grpc"
	defaultErrChansize = 10
)

func NewServer(ctx context.Context, configDir string, cfg *ServerConfig) (*Server, error) {
	cfgLoader := config.NewConfig()

	// Determine agent ID
	agentID := os.Getenv("AGENT_ID")
	if agentID == "" {
		agentID = "default-agent"
	}

	if cfg.AgentID == "" {
		cfg.AgentID = agentID
	}

	// Set up KV store if enabled
	kvStore, err := setupKVStore(ctx, cfgLoader, cfg)
	if err != nil {
		return nil, err
	}

	s := &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]*CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   cfg.ListenAddr,
		registry:     initRegistry(),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		config:       cfg,
		connections:  make(map[string]*CheckerConnection),
		kvStore:      kvStore,
	}

	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

// setupKVStore configures the KV store if enabled by KVAddress and KVSecurity.
func setupKVStore(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig) (KVStore, error) {
	if cfg.KVAddress == "" {
		log.Printf("KVAddress not set, skipping KV store setup")

		return nil, nil
	}

	clientCfg := grpc.ClientConfig{
		Address:    cfg.KVAddress,
		MaxRetries: 3,
	}

	securityConfig := cfg.Security
	if cfg.KVSecurity != nil {
		securityConfig = cfg.KVSecurity
	}

	if securityConfig == nil {
		return nil, errNoSecurityConfigKV
	}

	provider, err := grpc.NewSecurityProvider(ctx, securityConfig)
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

	// Verify client is non-nil
	if kvStore.client == nil {
		err := client.Close()
		if err != nil {
			log.Printf("Error closing client: %v", err)

			return nil, err
		}

		return nil, fmt.Errorf("failed to initialize KV service client")
	}

	cfgLoader.SetKVStore(kvStore)

	return kvStore, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")

	// Use AgentName for KV path, fall back to AgentID if not set
	serverName := s.config.AgentID // Default to AgentID

	if s.config.AgentName != "" {
		serverName = s.config.AgentName // Prefer AgentName
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

// tryLoadFromKV attempts to load config from KV store.
func (s *Server) tryLoadFromKV(ctx context.Context, kvPath string, sweepConfig *SweepConfig) (Service, error) {
	if s.kvStore == nil {
		log.Printf("KV store not initialized, skipping KV fetch for sweep config")
		return nil, nil
	}

	value, found, err := s.kvStore.Get(ctx, kvPath)
	if err != nil {
		log.Printf("Failed to get sweep config from KV %s: %v", kvPath, err)
		return nil, err
	}

	if !found {
		log.Printf("Sweep config not found in KV at %s", kvPath)
		return nil, nil
	}

	if err = json.Unmarshal(value, sweepConfig); err != nil {
		log.Printf("Failed to unmarshal sweep config from KV %s: %v", kvPath, err)
		return nil, err
	}

	log.Printf("Loaded sweep config from KV: %s", kvPath)

	service, err := s.createSweepService(sweepConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service from KV config: %w", err)
	}

	return service, nil
}

// loadSweepService loads and initializes the sweep service.
func (s *Server) loadSweepService(ctx context.Context, cfgLoader *config.Config, kvPath, filePath string) (Service, error) {
	var sweepConfig SweepConfig

	// Attempt to load from KV store first if available
	if service, err := s.tryLoadFromKV(ctx, kvPath, &sweepConfig); err == nil && service != nil {
		return service, nil
	}

	// Fallback to file loading
	if err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig); err != nil {
		return nil, fmt.Errorf("failed to load sweep config from file %s: %w", filePath, err)
	}

	suffix := s.getLogSuffix()
	log.Printf("Loaded sweep config from file%s: %s", suffix, filePath)

	service, err := s.createSweepService(&sweepConfig) // Unpack the tuple here too
	if err != nil {
		return nil, err
	}

	return service, nil
}

// getLogSuffix returns appropriate suffix based on KV store availability.
func (s *Server) getLogSuffix() string {
	if s.kvStore != nil {
		return " " + fallBackSuffix
	}

	return ""
}

// createSweepService constructs a Service from a SweepConfig.
func (s *Server) createSweepService(sweepConfig *SweepConfig) (Service, error) {
	if sweepConfig == nil {
		return nil, errSweepConfigNil
	}

	c := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
	}

	// Pass kvStore and config key to enable watching
	serverName := s.config.AgentID
	if s.config.AgentName != "" {
		serverName = s.config.AgentName
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", serverName)

	service, err := NewSweepService(c, s.kvStore, configKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service: %w", err)
	}

	log.Printf("Initialized sweep service with config: %+v", c)

	return service, nil
}

func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting agent service...")

	if err := s.initializeCheckers(ctx); err != nil {
		return fmt.Errorf("failed to initialize checkers: %w", err)
	}

	log.Printf("Found %d services to start", len(s.services))

	for i, svc := range s.services {
		log.Printf("Starting service #%d: %s", i, svc.Name())

		go func(svc Service) { // Run in goroutine to avoid blocking
			if err := svc.Start(ctx); err != nil {
				log.Printf("Failed to start service %s: %v", svc.Name(), err)
			} else {
				log.Printf("Service %s started successfully", svc.Name())
			}
		}(svc)
	}

	return nil
}

func (s *Server) Stop(_ context.Context) error {
	log.Printf("Stopping agent service...")

	for _, svc := range s.services {
		if err := svc.Stop(context.Background()); err != nil {
			log.Printf("Failed to stop service %s: %v", svc.Name(), err)
		}
	}

	for name, conn := range s.connections {
		if err := conn.client.Close(); err != nil {
			log.Printf("Error closing connection to checker %s: %v", name, err)
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

	cfgLoader := config.NewConfig()

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
			log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

			continue
		}

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, conf)
			if err != nil {
				log.Printf("Warning: Failed to connect to checker %s: %v", conf.Name, err)
				continue
			}

			s.connections[conf.Name] = conn
		}

		s.checkerConfs[conf.Name] = conf

		log.Printf("Loaded checker config: %s (type: %s)", conf.Name, conf.Type)
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
	}

	if s.config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, s.config.Security)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	log.Printf("Connecting to checker service %s at %s", checkerConfig.Name, checkerConfig.Address)

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to checker %s: %w", checkerConfig.Name, err)
	}

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
	}, nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Received status request: %+v", req)

	if req.ServiceType == "icmp" && req.Details != "" {
		for _, svc := range s.services {
			sweepSvc, ok := svc.(*SweepService)
			if !ok {
				continue // Skip if svc is not a SweepService
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
				Message:      string(jsonResp),
				ServiceName:  "icmp_check",
				ServiceType:  "icmp",
				ResponseTime: result.RespTime.Nanoseconds(),
			}, nil
		}

		return nil, errNoSweepService
	}

	if req.ServiceType == "sweep" {
		return s.getSweepStatus(ctx)
	}

	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, err
	}

	available, message := c.Check(ctx)

	return &proto.StatusResponse{
		Available:   available,
		Message:     message,
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
	}, nil
}

func (s *Server) loadCheckerConfig(ctx context.Context, cfgLoader *config.Config, filePath string) (*CheckerConfig, error) {
	var conf *CheckerConfig

	// Determine KV path
	kvPath := filepath.Base(filePath)
	if s.config.AgentID != "" {
		kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, filepath.Base(filePath))
	}

	// Try KV if available
	var err error
	if s.kvStore != nil {
		if err = cfgLoader.LoadAndValidate(ctx, kvPath, &conf); err == nil {
			log.Printf("Loaded checker config from KV: %s", kvPath)

			return s.applyCheckerDefaults(conf), nil
		}

		log.Printf("Failed to load checker config from KV %s: %v", kvPath, err)
	}

	// Load from file (either directly or as fallback)
	if err = cfgLoader.LoadAndValidate(ctx, filePath, &conf); err != nil {
		return conf, fmt.Errorf("failed to load checker config %s: %w", filePath, err)
	}

	suffix := ""
	if s.kvStore != nil {
		suffix = " " + fallBackSuffix
	}

	log.Printf("Loaded checker config from file%s: %s", suffix, filePath)

	return s.applyCheckerDefaults(conf), nil
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
			log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

			continue
		}

		s.checkerConfs[conf.Name] = conf

		log.Printf("Loaded checker config: %s (type: %s)", conf.Name, conf.Type)
	}

	return nil
}

func (s *Server) getSweepStatus(ctx context.Context) (*proto.StatusResponse, error) {
	for _, svc := range s.services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			return provider.GetStatus(ctx)
		}
	}

	return &proto.StatusResponse{
		Available:   false,
		Message:     "Sweep service not configured",
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

func (s *Server) getChecker(ctx context.Context, req *proto.StatusRequest) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	log.Printf("Getting checker for request - Type: %s, Name: %s, Details: %s",
		req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	if check, exists := s.checkers[key]; exists {
		log.Printf("Retrieved cached checker for key: %s", key)

		return check, nil
	}

	details := req.GetDetails()

	log.Printf("Creating new checker with details: %s", details)

	check, err := s.registry.Get(ctx, req.ServiceType, req.ServiceName, details, s.config.Security)
	if err != nil {
		log.Printf("Failed to create checker for key %s: %v", key, err)

		return nil, fmt.Errorf("failed to create checker: %w", err)
	}

	s.checkers[key] = check

	log.Printf("Cached new checker for key: %s", key)

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
		log.Printf("Error during stop: %v", err)

		return err
	}

	close(s.errChan)

	return nil
}
