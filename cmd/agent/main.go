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

	// Create agent server
	server, err := agent.NewServer(cfg.CheckersDir)
	if err != nil {
		return err
	}

	// Register services function
	registerServices := func(s *grpc.Server) error {
		// Register agent service
		proto.RegisterAgentServiceServer(s.GetGRPCServer(), server)

		return nil
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(context.Background(), &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          cfg.ServiceName,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
}
