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
	"os"

	"github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc" // For the underlying gRPC server type
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/agent.json", "Path to agent config file")
	flag.Parse()

	// setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Check if KV config source is enabled
	configSource := os.Getenv("CONFIG_SOURCE")
	if configSource == "kv" {
		log.Printf("Using KV config source, ensuring KV store is initialized first")

		// Load minimal configuration from file to get KV address
		var cfg config.AgentConfig
		if err := config.LoadFile(*configPath, &cfg); err != nil {
			return fmt.Errorf("failed to load initial config to get KV address: %w", err)
		}

		if cfg.KVAddress == "" {
			return fmt.Errorf("CONFIG_SOURCE=kv but no KV address specified in config")
		}

		log.Printf("KV address from config: %s", cfg.KVAddress)
	}

	// Initialize configuration loader
	cfgLoader := config.NewConfig()

	// Load configuration with context
	var cfg config.AgentConfig

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return err
	}

	// Create agent server
	server, err := agent.NewServer(ctx, cfg.CheckersDir, &agent.ServerConfig{
		ListenAddr: cfg.ListenAddr,
		Security:   cfg.Security,
		KVAddress:  cfg.KVAddress,
		AgentID:    cfg.ServiceName,
	})
	if err != nil {
		return fmt.Errorf("failed to create server: %w", err)
	}

	// Create server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        server.ListenAddr(),
		ServiceName:       cfg.ServiceName,
		Service:           server,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error { // s is *google.golang.org/grpc.Server due to lifecycle update
				proto.RegisterAgentServiceServer(s, server)
				return nil
			},
		},
		Security: server.SecurityConfig(),
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(ctx, opts)
}
