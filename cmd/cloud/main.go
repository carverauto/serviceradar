package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/homemon/pkg/cloud"
	"github.com/mfreeman451/homemon/pkg/cloud/api"
)

func main() {
	configPath := flag.String("config", "/etc/homemon/cloud.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()

	config, err := cloud.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	server, err := cloud.NewServer(ctx, &config)
	if err != nil {
		log.Fatalf("Failed to create server: %v", err)
	}

	// Create and start API server
	apiServer := api.NewAPIServer()
	server.SetAPIServer(apiServer)

	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Printf("Received signal %v, initiating shutdown", sig)
		server.Shutdown(ctx)
	}()

	// Start monitoring goroutine
	go server.MonitorPollers(context.Background())

	// Start HTTP server for API and web interface on the configured listen address
	go func() {
		log.Printf("Starting HTTP server on %s", config.ListenAddr)

		if err := apiServer.Start(config.ListenAddr); err != nil {
			log.Fatalf("HTTP server failed: %v", err)
		}
	}()

	// Block until shutdown
	<-server.ShutdownChan
}
