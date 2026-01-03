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
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

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

// Version is set at build time via ldflags
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

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
	if err := agent.SeedCheckerConfigsFromDisk(ctx, bootstrapResult.Manager(), &cfg, *configPath, agentLogger); err != nil {
		agentLogger.Warn().Err(err).Msg("Failed to seed checker configs to KV")
	}

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

	// Gateway address is required - agents must push status to gateway
	if cfg.GatewayAddr == "" {
		return agent.ErrGatewayAddrRequired
	}

	return runPushMode(ctx, server, &cfg, agentLogger)
}

// runPushMode runs the agent in push mode, pushing status to the gateway.
func runPushMode(ctx context.Context, server *agent.Server, cfg *agent.ServerConfig, log logger.Logger) error {
	log.Info().
		Str("gateway_addr", cfg.GatewayAddr).
		Str("agent_id", cfg.AgentID).
		Msg("Starting agent in push mode")

	// Create gateway client
	gatewayClient := agent.NewGatewayClient(cfg.GatewayAddr, cfg.GatewaySecurity, log)

	// Connect to gateway
	if err := gatewayClient.Connect(ctx); err != nil {
		return fmt.Errorf("failed to connect to gateway: %w", err)
	}

	// Step 1: Send Hello to register with gateway
	hostname, _ := os.Hostname()
	helloReq := &proto.AgentHelloRequest{
		AgentId:       cfg.AgentID,
		Version:       Version,
		Capabilities:  getAgentCapabilities(server),
		Hostname:      hostname,
		Os:            runtime.GOOS,
		Arch:          runtime.GOARCH,
		Partition:     cfg.Partition,
		ConfigVersion: "", // Empty on first connect, will be populated after GetConfig
	}

	helloResp, err := gatewayClient.Hello(ctx, helloReq)
	if err != nil {
		return fmt.Errorf("failed to enroll agent: %w", err)
	}

	// Update config with tenant info from gateway if not already set
	if cfg.TenantID == "" && helloResp.TenantId != "" {
		cfg.TenantID = helloResp.TenantId
	}
	if cfg.TenantSlug == "" && helloResp.TenantSlug != "" {
		cfg.TenantSlug = helloResp.TenantSlug
	}

	// Step 2: Get configuration from gateway
	configReq := &proto.AgentConfigRequest{
		AgentId:       cfg.AgentID,
		ConfigVersion: "", // Empty to get full config
	}

	configResp, err := gatewayClient.GetConfig(ctx, configReq)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get config from gateway, using local config")
		// Continue with local config - this is not fatal
	} else if !configResp.NotModified {
		// TODO: Apply config from gateway (checks, intervals, etc.)
		// For now, just use the heartbeat interval from the config
		log.Info().
			Str("config_version", configResp.ConfigVersion).
			Int("checks_count", len(configResp.Checks)).
			Msg("Received configuration from gateway")
	}

	// Determine push interval (prefer gateway config, fall back to local)
	pushInterval := time.Duration(cfg.PushInterval)
	if helloResp.HeartbeatIntervalSec > 0 {
		pushInterval = time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
	}
	if pushInterval <= 0 {
		pushInterval = 30 * time.Second
	}

	// Create push loop
	pushLoop := agent.NewPushLoop(server, gatewayClient, pushInterval, log)

	// Create a cancellable context for the push loop
	pushCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Start the server's services (checkers, sweep, etc.)
	if err := server.Start(pushCtx); err != nil {
		return fmt.Errorf("failed to start agent services: %w", err)
	}
	defer func() {
		if err := server.Stop(context.Background()); err != nil {
			log.Error().Err(err).Msg("Error stopping agent services")
		}
	}()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start push loop in a goroutine
	errChan := make(chan error, 1)
	go func() {
		errChan <- pushLoop.Start(pushCtx)
	}()

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Info().Str("signal", sig.String()).Msg("Received shutdown signal")
		cancel()
		// Wait for push loop to stop
		<-errChan

	case err := <-errChan:
		if err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("push loop error: %w", err)
		}
	}

	// Disconnect from gateway
	if err := gatewayClient.Disconnect(); err != nil {
		log.Warn().Err(err).Msg("Error disconnecting from gateway")
	}

	log.Info().Msg("Agent shutdown complete")
	return nil
}

// getAgentCapabilities returns the capabilities of this agent based on configured services.
func getAgentCapabilities(server *agent.Server) []string {
	// Base capabilities that all agents have
	capabilities := []string{"status", "push"}

	// Add capabilities based on configured checkers/services
	// TODO: Query the server for its configured services and add their types
	// For now, return base capabilities

	return capabilities
}
