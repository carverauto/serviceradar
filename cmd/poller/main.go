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

	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
)

//go:embed config.json
var defaultConfig []byte

var (
	errFailedToLoadConfig      = fmt.Errorf("failed to load config")
	errPollerDescriptorMissing = fmt.Errorf("service descriptor for poller missing")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/poller.json", "Path to poller config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypePoller, nil)
	if err != nil {
		return fmt.Errorf("edge onboarding failed: %w", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		*configPath = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", *configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	var cfg poller.Config
	desc, ok := config.ServiceDescriptorFor("poller")
	if !ok {
		return errPollerDescriptorMissing
	}
	bootstrapResult, err := cfgbootstrap.ServiceWithTemplateRegistration(ctx, desc, &cfg, defaultConfig, cfgbootstrap.ServiceOptions{
		Role:         models.RolePoller,
		ConfigPath:   *configPath,
		DisableWatch: true,
		KeyContextFn: func(conf interface{}) config.KeyContext {
			if pollerCfg, ok := conf.(*poller.Config); ok {
				return config.KeyContext{PollerID: pollerCfg.PollerID}
			}
			return config.KeyContext{}
		},
	})
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
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

	pollerLogger, err := lifecycle.CreateComponentLogger(ctx, "poller", logConfig)
	if err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	// Create poller instance with a real clock for production
	p, err := poller.New(ctx, &cfg, nil, pollerLogger) // nil clock defaults to realClock in poller.New
	if err != nil {
		return err
	}

	// KV Watch: overlay and apply hot-reload on relevant changes
	if cfg.PollerID != "" {
		bootstrapResult.SetInstanceID(cfg.PollerID)
	}
	bootstrapResult.StartWatch(ctx, pollerLogger, &cfg, func() {
		_ = p.UpdateConfig(ctx, &cfg)
	})

	// No gRPC services to register - simplified architecture
	registerServices := func(_ *grpc.Server) error {
		return nil
	}

	// Run poller with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          cfg.ServiceName,
		Service:              p,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
}
