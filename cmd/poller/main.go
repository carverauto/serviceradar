// cmd/poller/main.go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/homemon/pkg/poller"
)

func loadConfig(path string) (poller.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return poller.Config{}, err
	}

	var config poller.Config
	if err := json.Unmarshal(data, &config); err != nil {
		return poller.Config{}, err
	}

	return config, nil
}

func main() {
	configPath := flag.String("config", "/etc/homemon/poller.json", "Path to config file")
	flag.Parse()

	config, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	p, err := poller.New(config)
	if err != nil {
		log.Fatalf("Failed to create poller: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		cancel()
	}()

	if err := p.Start(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatalf("Poller failed: %v", err)
	}
}
