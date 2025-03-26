package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/sync"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/sync.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()
	cfgLoader := config.NewConfig()

	var cfg sync.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	syncer, err := sync.NewDefault(ctx, &cfg)
	if err != nil {
		log.Fatalf("Failed to create syncer: %v", err)
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        "localhost:0",
		ServiceName:       "sync",
		Service:           syncer,
		EnableHealthCheck: false,
		Security:          cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Sync service failed: %v", err)
	}
}
