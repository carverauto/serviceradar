package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/poller.json", "Path to poller config file")
	flag.Parse()

	// Load configuration
	var cfg poller.Config
	if err := config.LoadAndValidate(*configPath, &cfg); err != nil {
		return err
	}

	// Create context for lifecycle management
	ctx := context.Background()

	// Create poller instance
	p, err := poller.New(ctx, &cfg)
	if err != nil {
		return err
	}

	// Register services function
	registerServices := func(s *grpc.Server) error {
		// Register poller service if needed
		proto.RegisterPollerServiceServer(s.GetGRPCServer(), p)

		return nil
	}

	// Run poller with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          cfg.ServiceName,
		Service:              p,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
}
