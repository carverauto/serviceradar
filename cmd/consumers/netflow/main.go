package main

import (
	"context"
	"encoding/json"
	"log"
	"os"

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

	var netflowCfg netflow.Config
	if err := json.Unmarshal(data, &netflowCfg); err != nil {
		log.Fatalf("Failed to parse config: %v", err)
	}
	log.Printf("Loaded NetFlow configuration: %+v", netflowCfg)

	// Validate configuration
	if err := netflowCfg.Validate(); err != nil {
		log.Fatalf("Config validation failed: %v", err)
	}

	// Use DBConfig from netflowCfg, override ServerName for Proton
	dbConfig := &models.DBConfig{
		DBAddr:   netflowCfg.DBConfig.DBAddr,
		DBName:   netflowCfg.DBConfig.DBName,
		DBUser:   netflowCfg.DBConfig.DBUser,
		DBPass:   netflowCfg.DBConfig.DBPass,
		Database: netflowCfg.DBConfig.Database,
		Security: &models.SecurityConfig{
			TLS:        netflowCfg.Security.TLS,
			CertDir:    netflowCfg.Security.CertDir,
			ServerName: netflowCfg.Security.ServerName,
		},
	}
	log.Printf("Database configuration: DBAddr=%s, ServerName=%s", dbConfig.DBAddr, dbConfig.Security.ServerName)

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
