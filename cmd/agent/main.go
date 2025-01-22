// cmd/agent/main.go
package main

import (
	"context"
	"flag"
	"log"

	"github.com/mfreeman451/serviceradar/pkg/agent"
	"github.com/mfreeman451/serviceradar/pkg/config"
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
	configPath := flag.String("config", "/etc/serviceradar/agent.json", "Path to agent config file")
	flag.Parse()

	// Load configuration
	var cfg config.AgentConfig
	if err := config.LoadAndValidate(*configPath, &cfg); err != nil {
		return err
	}

	// Create agent server - it will discover checkers from the CheckersDir
	server, err := agent.NewServer(cfg.CheckersDir)
	if err != nil {
		return err
	}

	// Create gRPC service registrar
	registerService := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s.GetGRPCServer(), server)
		return nil
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(context.Background(), lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true, // Agent needs health checks for poller monitoring
	})
}
