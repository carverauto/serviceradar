package main

import (
	"context"
	"flag"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/kv"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
)

const (
	defaultTTL = 24 * time.Hour
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/kv.json", "Path to config file")
	natsURL := flag.String("nats-url", "nats://localhost:4222", "NATS server URL")
	flag.Parse()

	ctx := context.Background()

	// Load KV service config
	cfgLoader := config.NewConfig()

	var cfg kv.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create NATS JetStream KV store
	store, err := kv.NewNatsStore(ctx, *natsURL, "serviceradar-config", defaultTTL)
	if err != nil {
		log.Fatalf("Failed to create NATS KV store: %v", err)
	}

	// Set KV store for config package
	cfgLoader.SetKVStore(store)

	// Create KV server
	server, err := kv.NewServer(cfg, store)
	if err != nil {
		log.Fatalf("Failed to create KV server: %v", err)
	}

	// Run with lifecycle management
	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "kv",
		Service:           server,
		EnableHealthCheck: true,
		Security:          cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
