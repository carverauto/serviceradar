/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
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
	"github.com/carverauto/serviceradar/pkg/consumers/netflow"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/consumers/netflow.json", "Path to config file")
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

	// Initialize configuration loader
	cfgLoader := config.NewConfig(nil)

	// Load configuration
	var netflowCfg netflow.NetflowConfig

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &netflowCfg); err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Validate configuration
	if err := netflowCfg.Validate(); err != nil {
		log.Fatalf("NetflowConfig validation failed: %v", err)
	}

	// Use CoreServiceConfig from netflowCfg, override ServerName for Proton
	dbConfig := &models.CoreServiceConfig{
		DBAddr: netflowCfg.DBConfig.DBAddr,
		DBName: netflowCfg.DBConfig.DBName,
		DBUser: netflowCfg.DBConfig.DBUser,
		DBPass: netflowCfg.DBConfig.DBPass,
		Security: &models.SecurityConfig{
			TLS: models.TLSConfig{
				CertFile:     netflowCfg.Security.TLS.CertFile,
				KeyFile:      netflowCfg.Security.TLS.KeyFile,
				CAFile:       netflowCfg.Security.TLS.CAFile,
				ClientCAFile: netflowCfg.Security.TLS.ClientCAFile,
			},
			CertDir:    netflowCfg.Security.CertDir,
			ServerName: netflowCfg.Security.ServerName,
			Mode:       netflowCfg.Security.Mode,
			Role:       netflowCfg.Security.Role,
		},
	}

	// Initialize logger for database
	dbLogger, err := lifecycle.CreateComponentLogger(ctx, "netflow-db", &logger.Config{
		Level: "info",
	})
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Initialize database service
	dbService, err := db.New(ctx, dbConfig, dbLogger)
	if err != nil {
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	// Initialize NetFlow service
	svc, err := netflow.NewService(&netflowCfg, dbService)
	if err != nil {
		log.Fatalf("Failed to initialize NetFlow service: %v", err)
	}

	// Configure server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        netflowCfg.ListenAddr,
		ServiceName:       "netflow-consumer",
		Service:           svc,
		EnableHealthCheck: true,
		Security:          netflowCfg.Security,
	}

	// Run the server
	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
