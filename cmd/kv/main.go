package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/kv"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	ggrpc "google.golang.org/grpc"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/kv.json", "Path to config file")
	natsURL := flag.String("nats-url", "", "NATS server URL (overrides config)")
	flag.Parse()

	ctx := context.Background()

	cfgLoader := config.NewConfig()

	var cfg kv.Config
	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	if *natsURL != "" {
		cfg.NatsURL = *natsURL
	}

	if err := cfg.Validate(); err != nil {
		log.Fatalf("Invalid configuration: %v", err)
	}

	server, err := kv.NewServer(ctx, &cfg)
	if err != nil {
		log.Fatalf("Failed to create KV server: %v", err)
	}

	cfgLoader.SetKVStore(server.Store())

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "kv",
		Service:           server,
		EnableHealthCheck: true,
		Security:          cfg.Security,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(srv *ggrpc.Server) error {
				proto.RegisterKVServiceServer(srv, server)
				return nil
			},
		},
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
