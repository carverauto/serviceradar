package main

import (
	"context"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/consumers/netflow"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
)

func main() {
	ctx := context.Background()

	// Initialize configuration loader
	cfgLoader := config.NewConfig()

	// Load configuration
	var cfg netflow.Config

	configPath := "/etc/serviceradar/consumers/netflow.json"

	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Initialize service
	svc, err := netflow.NewService(cfg)
	if err != nil {
		log.Fatalf("Failed to initialize service: %v", err)
	}

	// Configure server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "netflow-consumer",
		Service:           svc,
		EnableHealthCheck: true,
		Security:          cfg.Security,
	}

	// Run the server
	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
