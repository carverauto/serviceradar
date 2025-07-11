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

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/sync"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/sync.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()
	
	// Step 1: Load config with basic logger
	cfgLoader := config.NewConfigWithDefaults()
	var cfg sync.Config
	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Step 2: Create proper logger from config
	logger, err := lifecycle.CreateComponentLogger("sync", cfg.Logging)
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
