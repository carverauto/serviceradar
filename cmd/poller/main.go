package main

import (
	"context"
	"flag"
	"log"

	"github.com/mfreeman451/serviceradar/pkg/config"
	"github.com/mfreeman451/serviceradar/pkg/lifecycle"
	"github.com/mfreeman451/serviceradar/pkg/poller"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/poller.json", "Path to poller config file")
	flag.Parse()

	// Load and validate configuration using shared config package
	var cfg poller.Config
	if err := config.LoadAndValidate(*configPath, &cfg); err != nil {
		return err
	}

	// Create context for lifecycle management
	ctx := context.Background()

	// Create poller instance
	p, err := poller.New(ctx, cfg)
	if err != nil {
		return err
	}

	// Run poller with lifecycle management
	return lifecycle.RunServer(ctx, lifecycle.ServerOptions{
		Service:           p,
		EnableHealthCheck: false,
	})
}
