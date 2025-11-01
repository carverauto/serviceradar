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

	"google.golang.org/grpc" // For the underlying gRPC server type

	"github.com/carverauto/serviceradar/pkg/checker/dusk"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	log.Printf("Starting Dusk checker...")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/dusk.json", "Path to config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
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
		log.Printf("Using edge-onboarded configuration from: %s", *configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	// Initialize configuration loader
	cfgLoader := config.NewConfig(nil)

	// Load configuration with context
	var cfg dusk.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create the checker
	checker := &dusk.DuskChecker{
		Config: cfg,
		Done:   make(chan struct{}),
	}

	// Create health server and block service
	blockService := dusk.NewDuskBlockService(checker)

	// Create gRPC service registrar
	registerServices := func(s *grpc.Server) error { // s is *google.golang.org/grpc.Server due to lifecycle update
		proto.RegisterAgentServiceServer(s, blockService)
		return nil
	}

	// Create and configure service options
	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              &duskService{checker: checker},
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

// duskService wraps the DuskChecker to implement lifecycle.Service.
type duskService struct {
	checker *dusk.DuskChecker
}

func (s *duskService) Start(ctx context.Context) error {
	log.Printf("Starting Dusk service...")

	return s.checker.StartMonitoring(ctx)
}

func (s *duskService) Stop(_ context.Context) error {
	log.Printf("Stopping Dusk service...")
	close(s.checker.Done)

	return nil
}
