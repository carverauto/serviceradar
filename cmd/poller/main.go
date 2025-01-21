package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/serviceradar/pkg/poller"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/poller.json", "Path to config file")
	flag.Parse()

	config, err := poller.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create context that can be canceled
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Create poller with context
	p, err := poller.New(ctx, config)
	if err != nil {
		log.Printf("Failed to create poller: %v", err)
		cancel()

		return
	}

	// Ensure poller is closed after main exits
	defer func() {
		log.Printf("Closing poller...")

		if err := p.Close(); err != nil {
			log.Printf("Failed to close poller: %v", err)
		}
	}()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start poller in a goroutine
	errChan := make(chan error, 1)
	go func() {
		log.Printf("Starting poller...")
		errChan <- p.Start(ctx)

		log.Printf("Poller Start() goroutine finished")

		close(errChan) // Ensure channel is closed after Start returns
	}()

	// Wait for either error or shutdown signal
	select {
	case err := <-errChan:
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("Poller failed: %v", err)
			cancel()
		}
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
		cancel()
	}

	log.Println("Shutdown complete")
}
