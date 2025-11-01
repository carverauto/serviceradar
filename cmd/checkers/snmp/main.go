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

package main

import (
	"context"
	"flag"
	"fmt"
	"time"

	"google.golang.org/grpc" // For the underlying gRPC server type

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultSNMPStopTimeout = 10 * time.Second
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		logger.Fatal().Err(err).Msg("Fatal error")
	}
}

func run() error {
	logger.Info().Msg("Starting SNMP checker")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/snmp.json", "Path to config file")
	onboardingToken := flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	kvEndpoint := flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeChecker, nil)
	if err != nil {
		return fmt.Errorf("edge onboarding failed: %w", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		*configPath = onboardingResult.ConfigPath
		logger.Info().
			Str("config_path", *configPath).
			Str("spiffe_id", onboardingResult.SPIFFEID).
			Msg("Using edge-onboarded configuration")
	}

	// Initialize configuration loader
	cfgLoader := config.NewConfig(nil)

	// Load configuration with context
	var cfg snmp.SNMPConfig

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create logger instance for the service
	var loggerConfig *logger.Config
	if cfg.Logger != nil {
		loggerConfig = cfg.Logger
	} else {
		loggerConfig = logger.DefaultConfig()
	}

	log, err := lifecycle.CreateComponentLogger(ctx, "snmp-checker", loggerConfig)
	if err != nil {
		return fmt.Errorf("failed to create logger: %w", err)
	}

	// Create SNMP service
	service, err := snmp.NewSNMPService(&cfg, log)
	if err != nil {
		return fmt.Errorf("failed to create SNMP service: %w", err)
	}

	// Create and register block service
	snmpAgentService := snmp.NewSNMPPollerService(&snmp.Poller{Config: cfg}, service, log)

	// Create gRPC service registrar
	registerServices := func(s *grpc.Server) error { // s is *google.golang.org/grpc.Server due to lifecycle update
		proto.RegisterAgentServiceServer(s, snmpAgentService)

		return nil
	}

	// Create and configure service options
	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              &snmpService{service: service},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	}

	// Run service with lifecycle management
	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// snmpService wraps the SNMPService to implement lifecycle.Service.
type snmpService struct {
	service *snmp.SNMPService
}

func (s *snmpService) Start(ctx context.Context) error {
	logger.Info().Msg("Starting SNMP service")

	return s.service.Start(ctx)
}

func (s *snmpService) Stop(ctx context.Context) error {
	logger.Info().Msg("Stopping SNMP service")

	_, cancel := context.WithTimeout(ctx, defaultSNMPStopTimeout)
	defer cancel()

	return s.service.Stop()
}
