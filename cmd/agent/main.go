package main

import (
	"context"
	"flag"
	"fmt"
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
	server, err := agent.NewServer(*configPath)
	if err != nil {
		return fmt.Errorf("failed to create server: %w", err)
	}

	// Create server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        server.ListenAddr(),
		ServiceName:       "AgentService",
		Service:           server,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				proto.RegisterAgentServiceServer(s.GetGRPCServer(), server)
				return nil
			},
		},
		Security: server.SecurityConfig(),
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(context.Background(), opts)
}
