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
	_ "embed"
	"flag"
	"fmt"
	"log"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

//go:embed config.json
var defaultConfig []byte

var (
	errServiceDescriptorMissing = fmt.Errorf("service descriptor for agent missing")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/agent.json", "Path to agent config file")
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
		*configPath = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", *configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	var cfg agent.ServerConfig
	desc, ok := config.ServiceDescriptorFor("agent")
	if !ok {
		return errServiceDescriptorMissing
	}
	bootstrapResult, err := cfgbootstrap.ServiceWithTemplateRegistration(ctx, desc, &cfg, defaultConfig, cfgbootstrap.ServiceOptions{
		Role:         models.RoleAgent,
		ConfigPath:   *configPath,
		DisableWatch: true,
		KeyContextFn: func(conf interface{}) config.KeyContext {
			if agentCfg, ok := conf.(*agent.ServerConfig); ok {
				return config.KeyContext{AgentID: agentCfg.AgentID}
			}
			return config.KeyContext{}
		},
	})
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	// Step 2: Create logger from loaded config
	logConfig := cfg.Logging
	if logConfig == nil {
		// Use default config if not specified
		logConfig = &logger.Config{
			Level:  "info",
			Output: "stdout",
		}
	}

	agentLogger, err := lifecycle.CreateComponentLogger(ctx, "agent", logConfig)
	if err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	// Step 3: Create agent server with proper logger
	server, err := agent.NewServer(ctx, cfg.CheckersDir, &cfg, agentLogger)
	if err != nil {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}

		return fmt.Errorf("failed to create server: %w", err)
	}

	// KV Watch: overlay and apply hot-reload on relevant changes
	if cfg.AgentID != "" {
		bootstrapResult.SetInstanceID(cfg.AgentID)
	}
	bootstrapResult.StartWatch(ctx, agentLogger, &cfg, func() {
		server.UpdateConfig(&cfg)
		server.RestartServices(ctx)
	})

	// Create server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        server.ListenAddr(),
		ServiceName:       "AgentService",
		Service:           server,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				proto.RegisterAgentServiceServer(s, server)
				return nil
			},
		},
		Security: server.SecurityConfig(),
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(ctx, opts)
}
