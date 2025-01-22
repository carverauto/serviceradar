// cmd/poller/main.go
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

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

	// Create a cancellable context for shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Load configuration
	cfg, err := poller.LoadConfig(*configPath)
	if err != nil {
		return err
	}

	// Create poller instance
	p, err := poller.New(ctx, cfg)
	if err != nil {
		return err
	}
	defer p.Close()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start poller in background
	errChan := make(chan error, 1)
	go func() {
		defer close(errChan)
		if err := p.Start(ctx); err != nil {
			errChan <- err
		}
	}()

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
	case err := <-errChan:
		if err != nil {
			log.Printf("Poller error: %v", err)
			return err
		}
	}

	// Initiate graceful shutdown
	cancel()

	return nil
}
