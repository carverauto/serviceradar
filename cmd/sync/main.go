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
	"log"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync"
	"github.com/carverauto/serviceradar/proto"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/sync.json", "Path to config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeAgent, nil)
	if err != nil {
		log.Fatalf("Edge onboarding failed: %v", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		*configPath = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", *configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	var cfg sync.Config
	desc, ok := config.ServiceDescriptorFor("sync")
	if !ok {
		log.Fatalf("Failed to load config: service descriptor for sync missing")
	}
	bootstrapResult, err := cfgbootstrap.Service(ctx, desc, &cfg, cfgbootstrap.ServiceOptions{
		Role:         models.RoleCore,
		ConfigPath:   *configPath,
		DisableWatch: true,
	})
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	// Step 2: Create logger from config
	logger, err := lifecycle.CreateComponentLogger(ctx, "sync", cfg.Logging)
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Step 3: Create config loader with proper logger for any future config operations
	_ = config.NewConfig(logger)

	syncer, err := sync.NewDefault(ctx, &cfg, logger)
	if err != nil {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}
		log.Fatalf("Failed to create syncer: %v", err)
	}

	bootstrapResult.StartWatch(ctx, logger, &cfg, func() {
		syncer.UpdateConfig(&cfg)
	})

	registerServices := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s, syncer)
		return nil
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          "sync",
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		Service:              syncer,
		EnableHealthCheck:    true,
		Security:             cfg.Security,
		Logger:               logger,
	}

	// Start server and handle shutdown
	serverErr := lifecycle.RunServer(ctx, opts)

	// Always shutdown logger before exiting
	if err := lifecycle.ShutdownLogger(); err != nil {
		log.Printf("Failed to shutdown logger: %v", err)
	}

	if serverErr != nil {
		log.Fatalf("Sync service failed: %v", serverErr)
	}
}
