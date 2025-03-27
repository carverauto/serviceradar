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
	snmpPrefix         = "snmp"
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

	// Check if KV is enabled and set up the KV store if so
	var kvStore *grpcKVStore

	var err error

	if os.Getenv("CONFIG_SOURCE") == "kv" && cfg.KVAddress != "" {
		clientCfg := grpc.ClientConfig{
			Address:    cfg.KVAddress,
			MaxRetries: 3,
		}
		if cfg.Security != nil {
			provider, err := grpc.NewSecurityProvider(ctx, cfg.Security)
			if err != nil {
				return nil, fmt.Errorf("failed to create security provider: %w", err)
			}
			clientCfg.SecurityProvider = provider
		}

		client, err := grpc.NewClient(ctx, clientCfg)
		if err != nil {
			return nil, fmt.Errorf("failed to create KV gRPC client: %w", err)
		}
		defer func() {
			if err != nil {
				if closeErr := client.Close(); closeErr != nil {
					log.Printf("Failed to close KV gRPC client: %v", closeErr)
				}
			}
		}()

		kvStore = &grpcKVStore{
			client: proto.NewKVServiceClient(client.GetConnection()),
			conn:   client,
		}
		cfgLoader.SetKVStore(kvStore)
	}

	s := &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   cfg.ListenAddr,
		registry:     initRegistry(),
		errChan:      make(chan error, defaultErrChansize),
		done:         make(chan struct{}),
		config:       cfg,
		connections:  make(map[string]*CheckerConnection),
		kvStore:      kvStore, // Assign kvStore to s.kvStore
	}

	if err = s.loadConfigurations(ctx, cfgLoader); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

func (s *Server) loadConfigurations(ctx context.Context, cfgLoader *config.Config) error {
	if err := s.loadCheckerConfigs(ctx, cfgLoader); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Define paths for sweep config
	fileSweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")

	var kvSweepConfigPath string

	if s.config.AgentID != "" {
		kvSweepConfigPath = fmt.Sprintf("agents/%s/sweep/sweep.json", s.config.AgentID)
	} else {
		kvSweepConfigPath = "sweep/sweep.json" // Fallback for KV if no AgentID
	}

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

func (s *Server) loadSweepService(ctx context.Context, cfgLoader *config.Config, kvPath, filePath string) (Service, error) {
	var sweepConfig SweepConfig

	if s.kvStore != nil {
		err := cfgLoader.LoadAndValidate(ctx, kvPath, &sweepConfig)
		if err == nil {
			log.Printf("Loaded sweep config from KV: %s", kvPath)
		} else {
			log.Printf("Failed to load sweep config from KV %s: %v", kvPath, err)
			err = cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig)
			if err != nil {
				return nil, err
			}
			log.Printf("Loaded sweep config from file fallback: %s", filePath)
		}
	} else {
		err := cfgLoader.LoadAndValidate(ctx, filePath, &sweepConfig)
		if err != nil {
			return nil, err
		}
		log.Printf("Loaded sweep config from file: %s", filePath)
	}

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
		kvPath := file.Name()
		if s.config.AgentID != "" {
			kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, file.Name())
		}

		var conf CheckerConfig
		if s.kvStore != nil {
			err := cfgLoader.LoadAndValidate(ctx, kvPath, &conf)
			if err == nil {
				log.Printf("Loaded checker config from KV in initializeCheckers: %s", kvPath)
			} else {
				log.Printf("Failed to load checker config from KV %s: %v", kvPath, err)
				err = cfgLoader.LoadAndValidate(ctx, filePath, &conf)
				if err != nil {
					log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)
					continue
				}
				log.Printf("Loaded checker config from file fallback in initializeCheckers: %s", filePath)
			}
		} else {
			err := cfgLoader.LoadAndValidate(ctx, filePath, &conf)
			if err != nil {
				log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)
				continue
			}
			log.Printf("Loaded checker config from file in initializeCheckers: %s", filePath)
		}

		if conf.Timeout == 0 {
			conf.Timeout = Duration(defaultTimeout)
		}
		if conf.Type == grpcType && conf.Address == "" {
			conf.Address = conf.ListenAddr
		}

		if conf.Type == grpcType {
			conn, err := s.connectToChecker(ctx, &conf)
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

		kvPath := file.Name()

		if s.config.AgentID != "" {
			kvPath = fmt.Sprintf("agents/%s/checkers/%s", s.config.AgentID, file.Name())
		}

		var conf CheckerConfig

		if s.kvStore != nil {
			err := cfgLoader.LoadAndValidate(ctx, kvPath, &conf)
			if err == nil {
				log.Printf("Loaded checker config from KV: %s", kvPath)
			} else {
				log.Printf("Failed to load checker config from KV %s: %v", kvPath, err)

				err = cfgLoader.LoadAndValidate(ctx, filePath, &conf)
				if err != nil {
					log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

					continue
				}

				log.Printf("Loaded checker config from file fallback: %s", filePath)
			}
		} else {
			err := cfgLoader.LoadAndValidate(ctx, filePath, &conf)
			if err != nil {
				log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

				continue
			}

			log.Printf("Loaded checker config from file: %s", filePath)
		}

		if conf.Timeout == 0 {
			conf.Timeout = Duration(defaultTimeout)
		}

		if conf.Type == grpcType && conf.Address == "" {
			conf.Address = conf.ListenAddr
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

	check, err := s.registry.Get(ctx, req.ServiceType, req.ServiceName, details)
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
