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
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

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

	s.initPluginManager(ctx)

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

func (s *Server) initPluginManager(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.pluginManager != nil {
		return
	}

	cacheDir := filepath.Join(s.configDir, "plugins")
	s.pluginManager = NewPluginManager(ctx, PluginManagerConfig{
		CacheDir:      cacheDir,
		LocalStoreDir: s.configDir,
		Logger:        s.logger,
	})
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

	if s.pluginManager != nil {
		s.pluginManager.Stop()
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

// Close gracefully shuts down the server and releases resources.
func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		s.logger.Error().Err(err).Msg("Error during stop")

		return err
	}

	close(s.errChan)

	return nil
}
