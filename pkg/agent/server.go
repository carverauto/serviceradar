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
	// Use Security.ServerName if available, otherwise fall back to env AGENT_ID
	agentID := os.Getenv("AGENT_ID")

	if cfg.Security != nil && cfg.Security.ServerName != "" {
		agentID = cfg.Security.ServerName
	}

	if agentID == "" {
		agentID = "default-agent"
	}

	if cfg.AgentID == "" {
		cfg.AgentID = agentID
	}

	log.Println("Agent ID:", cfg.AgentID)

	// Initialize config loader
	cfgLoader := config.NewConfig()

	// Set up KV store if enabled
	kvStore, err := setupKVStore(ctx, cfgLoader, cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to setup KV store: %w", err)
	}

	// Create server instance
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

	// Load checker and sweep configurations
	if err := s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

// setupKVStore configures the KV store if enabled by CONFIG_SOURCE and KVAddress.
func setupKVStore(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig) (*grpcKVStore, error) {
	log.Printf("Checking KV store setup: CONFIG_SOURCE=%s, KVAddress=%s", os.Getenv("CONFIG_SOURCE"), cfg.KVAddress)

	if os.Getenv("CONFIG_SOURCE") != "kv" || cfg.KVAddress == "" {
		log.Printf("KV store skipped: CONFIG_SOURCE=%s, KVAddress=%s", os.Getenv("CONFIG_SOURCE"), cfg.KVAddress)
		return nil, nil
	}

	clientCfg := grpc.ClientConfig{
		Address:    cfg.KVAddress,
		MaxRetries: 3,
	}

	log.Printf("Attempting to connect to KV store at %s", cfg.KVAddress)

	security := cfg.KVSecurity
	if security == nil {
		security = cfg.Security // Fallback to agent security if kv_security not specified
	}
	if security != nil {
		log.Printf("Creating security provider with mode=%s, certDir=%s", security.Mode, security.CertDir)
		provider, err := grpc.NewSecurityProvider(ctx, security)
		if err != nil {
			log.Printf("Failed to create security provider: %v", err)
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}
		clientCfg.SecurityProvider = provider
	}

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		log.Printf("Failed to create KV gRPC client: %v", err)
		return nil, fmt.Errorf("failed to create KV gRPC client: %w", err)
	}

	log.Printf("Successfully created KV gRPC client for %s", cfg.KVAddress)

	kvStore := &grpcKVStore{
		client: proto.NewKVServiceClient(client.GetConnection()),
		conn:   client,
	}

	cfgLoader.SetKVStore(kvStore)

	log.Printf("KV store initialized and set on config loader")

	return kvStore, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")
	kvSweepConfigPath := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", s.config.AgentID)
	log.Printf("KV sweep config path: %s", kvSweepConfigPath)

	// Load sweep service
	service, err := s.loadSweepService(ctx, cfgLoader, kvSweepConfigPath, fileSweepConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("failed to load sweep service: %w", err)
	}
	if service != nil {
		log.Printf("Adding sweep service to server")
		s.services = append(s.services, service)
	} else {
		log.Printf("No sweep service loaded")
	}

	return nil
}

func (s *Server) loadSweepService(ctx context.Context, cfgLoader *config.Config, kvPath, filePath string) (Service, error) {
	var sweepConfig *SweepConfig
	defaultFilePath := "/etc/serviceradar/checkers/sweep/sweep.json"

	// Determine the proper KV path based on Security.ServerName if available
	correctKVPath := kvPath
	if s.config.Security != nil && s.config.Security.ServerName != "" {
		correctKVPath = fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", s.config.Security.ServerName)
		log.Printf("Using server name %s for KV path: %s", s.config.Security.ServerName, correctKVPath)
	}

	log.Printf("Attempting to load sweep config from KV: %s", correctKVPath)
	if os.Getenv("CONFIG_SOURCE") == "kv" && s.kvStore != nil {
		log.Printf("Calling LoadAndValidate for KV key: %s", correctKVPath)
		if err := cfgLoader.LoadAndValidate(ctx, correctKVPath, &sweepConfig); err != nil {
			log.Printf("KV load failed: %v", err)
			data, found, err := s.kvStore.Get(ctx, correctKVPath)
			if err != nil {
				log.Printf("Direct KV check failed: %v", err)
			} else {
				log.Printf("Direct KV check: found=%v, data=%s", found, string(data))
			}
			log.Printf("Falling back to file: %s", defaultFilePath)
			if err := cfgLoader.LoadAndValidate(ctx, defaultFilePath, &sweepConfig); err != nil {
				log.Printf("Fallback failed: %v", err)
				return nil, nil
			}
			log.Printf("Successfully loaded sweep config from fallback file: %s", defaultFilePath)
		} else {
			log.Printf("Successfully loaded sweep config from KV: %s", correctKVPath)
		}
	} else {
		log.Printf("KV store not enabled (CONFIG_SOURCE=%s, kvStore=%v), loading from file: %s", os.Getenv("CONFIG_SOURCE"), s.kvStore != nil, defaultFilePath)
		if err := cfgLoader.LoadAndValidate(ctx, defaultFilePath, &sweepConfig); err != nil {
			log.Printf("Failed to load sweep config from file %s: %v", defaultFilePath, err)
			return nil, nil
		}
		log.Printf("Successfully loaded sweep config from file: %s", defaultFilePath)
	}

	if sweepConfig == nil {
		log.Printf("No sweep config loaded, skipping sweep service")
		return nil, nil
	}

	log.Printf("Creating sweep service with loaded config")
	service, err := s.createSweepService(sweepConfig)
	if err != nil {
		log.Printf("Failed to create sweep service: %v", err)
		return nil, err
	}
	log.Printf("Sweep service created successfully with config: %+v", sweepConfig)
	return service, nil
}

// createSweepService constructs a Service from a SweepConfig.
func (*Server) createSweepService(sweepConfig *SweepConfig) (Service, error) {
	c := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
	}

	service, err := NewSweepService(c)
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

	log.Printf("Loaded %d checkers", len(s.checkerConfs))
	for name := range s.checkerConfs {
		log.Printf("Checker %s is configured", name)
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

// initializeCheckerConnections sets up gRPC clients for all checkers with addresses.
func (s *Server) initializeCheckerConnections(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for name, conf := range s.checkerConfs {
		if conf.Address != "" || conf.ListenAddr != "" {
			address := conf.Address
			if address == "" {
				address = conf.ListenAddr
			}
			if _, exists := s.connections[address]; !exists {
				conn, err := s.connectToChecker(ctx, conf)
				if err != nil {
					log.Printf("Failed to connect to checker %s at %s: %v", name, address, err)
					continue
				}
				s.connections[address] = conn
			}
		}
	}
	return nil
}

func (s *Server) initializeCheckers(ctx context.Context) error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}
	s.connections = make(map[string]*CheckerConnection)
	cfgLoader := config.NewConfig()
	// Do not set KV store for checkers
	// if s.kvStore != nil { cfgLoader.SetKVStore(s.kvStore) } // Comment out

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

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, conf)
			if err != nil {
				log.Printf("Warning: Failed to connect to checker %s: %v", conf.Name, err)
				continue
			}
			s.connections[conf.Address] = conn
			log.Printf("Established connection to checker %s at %s", conf.Name, conf.Address)
		}
	}
	return nil
}

func (s *Server) connectToChecker(ctx context.Context, checkerConfig *CheckerConfig) (*CheckerConnection, error) {
	address := checkerConfig.Address
	if address == "" {
		address = checkerConfig.ListenAddr
	}
	if address == "" {
		return nil, fmt.Errorf("no address specified for checker %s", checkerConfig.Name)
	}

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

	log.Printf("Successfully connected to checker %s at %s", checkerConfig.Name, checkerConfig.Address)

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
	}, nil
}

var (
	errNoSweepService = errors.New("no sweep service available for ICMP check")
	errICMPCheck      = errors.New("ICMP check failed")
)

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
	// Skip KV for checkers; only SweepService uses KV
	if err := cfgLoader.LoadAndValidate(ctx, filePath, &conf, config.WithFileOnly()); err != nil {
		return nil, fmt.Errorf("failed to load checker config from file %s: %w", filePath, err)
	}
	log.Printf("Loaded checker config from file: %s", filePath)
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

	log.Printf("Getting checker for request - Type: %s, Name: %s, Details: %s",
		req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())
	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	details := req.GetDetails()

	log.Printf("Creating new checker with details: %s", details)

	// Pass Server in context
	ctxWithServer := context.WithValue(ctx, "server", s)
	check, err := s.registry.Get(ctxWithServer, req.ServiceType, req.ServiceName, details)
	if err != nil {
		return nil, err
	}

	s.checkers[key] = check

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
