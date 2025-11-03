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
	"log"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/mapper"
	"github.com/carverauto/serviceradar/pkg/models"
	monitoringpb "github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

var (
	errFailedToLoadMapperConfig    = fmt.Errorf("failed to load mapper configuration")
	errFailedToTypeCastEngine      = fmt.Errorf("failed to cast discovery engine to *mapper.DiscoveryEngine for health service")
	errFailedToInitDiscoveryEngine = fmt.Errorf("failed to initialize discovery engine")
)

func run() error {
	// Parse command line flags
	configFile := flag.String("config", "/etc/serviceradar/mapper.json", "Path to mapper config file")
	listenAddr := flag.String("listen", ":50056", "Address for mapper to listen on")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")

	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeAgent, nil)
	if err != nil {
		return fmt.Errorf("edge onboarding failed: %w", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		*configFile = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", *configFile)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	// Initialize configuration loader
	cfgLoader := config.NewConfig(nil)

	// Load configuration with context
	var cfg mapper.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configFile, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadMapperConfig, err)
	}

	// Step 2: Create logger from config
	logger, err := lifecycle.CreateComponentLogger(ctx, "mapper", cfg.Logging)
	if err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	// Step 3: Create config loader with proper logger for any future config operations
	_ = config.NewConfig(logger)

	// Create discovery engine with a nil publisher for now
	// TODO: Create a proper publisher implementation
	var publisher mapper.Publisher

	engine, err := mapper.NewDiscoveryEngine(&cfg, publisher, logger)
	if err != nil {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}

		return fmt.Errorf("%w: %w", errFailedToInitDiscoveryEngine, err)
	}

	// Create gRPC services
	grpcDiscoveryService := mapper.NewGRPCDiscoveryService(engine, logger)

	snmpEngine, ok := engine.(*mapper.DiscoveryEngine)
	if !ok {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}

		return errFailedToTypeCastEngine
	}

	grpcMapperAgentService := mapper.NewAgentService(snmpEngine)

	// Create server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        *listenAddr,
		ServiceName:       "serviceradar-mapper",
		Service:           engine,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				discoverypb.RegisterDiscoveryServiceServer(s, grpcDiscoveryService)
				monitoringpb.RegisterAgentServiceServer(s, grpcMapperAgentService)
				return nil
			},
		},
		Security: cfg.Security,
		Logger:   logger,
	}

	logger.Info().Str("listen_addr", *listenAddr).Msg("Starting ServiceRadar Mapper Service")

	// Start server and handle shutdown
	serverErr := lifecycle.RunServer(ctx, opts)

	// Always shutdown logger before exiting
	if err := lifecycle.ShutdownLogger(); err != nil {
		log.Printf("Failed to shutdown logger: %v", err)
	}

	if serverErr != nil {
		return fmt.Errorf("mapper service failed: %w", serverErr)
	}

	return nil
}
