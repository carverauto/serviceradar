// cmd/cloud/main.go
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

	// Load configuration using the cloud package's Config type
	cfg, err := cloud.LoadConfig(*configPath)
	if err != nil {
		return err
	}

	// Create cloud server
	server, err := cloud.NewServer(context.Background(), &cfg)
	if err != nil {
		return err
	}

	// Create and configure API server
	apiServer := api.NewAPIServer()
	server.SetAPIServer(apiServer)

	// Start HTTP API server in background
	go func() {
		log.Printf("Starting HTTP API server on %s", cfg.ListenAddr)

		if err := apiServer.Start(cfg.ListenAddr); err != nil {
			log.Printf("HTTP API server error: %v", err)
		}
	}()

	// Create gRPC service registrar
	registerService := func(s *grpc.Server) error {
		proto.RegisterPollerServiceServer(s.GetGRPCServer(), server)
		return nil
	}

	// Run gRPC server with lifecycle management
	return lifecycle.RunServer(context.Background(), lifecycle.ServerOptions{
		ListenAddr:           cfg.GrpcAddr,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true,
	})
}
