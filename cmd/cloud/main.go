package main

import (
	"context"
	"flag"
	"log"

	"github.com/mfreeman451/serviceradar/pkg/cloud"
	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/lifecycle"
	"github.com/mfreeman451/serviceradar/proto"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/cloud.json", "Path to cloud config file")
	flag.Parse()

	// Load configuration
	cfg, err := cloud.LoadConfig(*configPath)
	if err != nil {
		return err
	}

	// Create root context for lifecycle management
	ctx := context.Background()

	// Create cloud server
	server, err := cloud.NewServer(ctx, &cfg)
	if err != nil {
		return err
	}

	apiServer := api.NewAPIServer(
		api.WithMetricsManager(server.GetMetricsManager()),
		api.WithSNMPManager(server.GetSNMPManager()),
	)

	server.SetAPIServer(apiServer)

	// Start HTTP API server in background
	errCh := make(chan error, 1)

	go func() {
		log.Printf("Starting HTTP API server on %s", cfg.ListenAddr)

		if err := apiServer.Start(cfg.ListenAddr); err != nil {
			select {
			case errCh <- err:
			default:
				log.Printf("HTTP API server error: %v", err)
			}
		}
	}()

	// Create gRPC service registrar
	registerService := func(s *grpc.Server) error {
		proto.RegisterPollerServiceServer(s.GetGRPCServer(), server)
		return nil
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.GrpcAddr,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
}
