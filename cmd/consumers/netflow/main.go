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
	"encoding/json"
	"log"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/pkg/consumers/netflow"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	ctx := context.Background()

	// Load NetFlow configuration directly
	configPath := "/etc/serviceradar/consumers/netflow.json"
	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("Failed to read config file: %v", err)
	}

	var netflowCfg netflow.NetflowConfig
	if err := json.Unmarshal(data, &netflowCfg); err != nil {
		log.Fatalf("Failed to parse config: %v", err)
	}
	log.Printf("Loaded NetFlow configuration: %+v", netflowCfg)

	// Validate configuration
	if err := netflowCfg.Validate(); err != nil {
		log.Fatalf("NetflowConfig validation failed: %v", err)
	}

	// Use DBConfig from netflowCfg, override ServerName for Proton
	dbConfig := &models.DBConfig{
		DBAddr:   netflowCfg.DBConfig.DBAddr,
		DBName:   netflowCfg.DBConfig.DBName,
		DBUser:   netflowCfg.DBConfig.DBUser,
		DBPass:   netflowCfg.DBConfig.DBPass,
		Database: netflowCfg.DBConfig.Database,
		Security: &models.SecurityConfig{
			TLS: models.TLSConfig{
				CertFile:     filepath.Join(netflowCfg.Security.CertDir, netflowCfg.Security.TLS.CertFile),
				KeyFile:      filepath.Join(netflowCfg.Security.CertDir, netflowCfg.Security.TLS.KeyFile),
				CAFile:       filepath.Join(netflowCfg.Security.CertDir, netflowCfg.Security.TLS.CAFile),
				ClientCAFile: filepath.Join(netflowCfg.Security.CertDir, netflowCfg.Security.TLS.CAFile),
			},
			CertDir:    netflowCfg.Security.CertDir,
			ServerName: netflowCfg.Security.ServerName,
			Mode:       netflowCfg.Security.Mode,
			Role:       netflowCfg.Security.Role,
		},
	}
	log.Printf("Database configuration: DBAddr=%s, ServerName=%s", dbConfig.DBAddr, dbConfig.Security.ServerName)

	log.Println("TLS configuration:", dbConfig.Security.TLS)

	// Initialize database service
	dbService, err := db.New(ctx, dbConfig)
	if err != nil {
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	// Initialize NetFlow service
	svc, err := netflow.NewService(netflowCfg, dbService)
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
