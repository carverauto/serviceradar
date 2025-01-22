package main

import (
	"context"
	"flag"
	"fmt"
	"log"

	"github.com/mfreeman451/serviceradar/pkg/checker/dusk"
	"github.com/mfreeman451/serviceradar/pkg/config"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/lifecycle"
	"github.com/mfreeman451/serviceradar/proto"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	log.Printf("Starting Dusk checker...")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/dusk.json", "Path to config file")
	flag.Parse()

	// Load and validate configuration using shared config package
	var cfg dusk.Config
	if err := config.LoadAndValidate(*configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create the checker
	checker := &dusk.DuskChecker{
		Config: cfg,
		Done:   make(chan struct{}),
	}

	// Create health server and block service
	healthServer := dusk.NewHealthServer(checker)
	blockService := dusk.NewDuskBlockService(checker)

	// Create gRPC service registrar
	registerServices := func(s *grpc.Server) error {
		// Register agent service
		proto.RegisterAgentServiceServer(s.GetGRPCServer(), blockService)

		// Register health service
		healthpb.RegisterHealthServer(s.GetGRPCServer(), healthServer)

		return nil
	}

	// Create and configure service options
	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              &duskService{checker: checker},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
	}

	// Run service with lifecycle management
	if err := lifecycle.RunServer(context.Background(), opts); err != nil {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// duskService wraps the DuskChecker to implement lifecycle.Service.
type duskService struct {
	checker *dusk.DuskChecker
}

func (s *duskService) Start(ctx context.Context) error {
	log.Printf("Starting Dusk service...")

	return s.checker.StartMonitoring(ctx)
}

func (s *duskService) Stop() error {
	log.Printf("Stopping Dusk service...")
	close(s.checker.Done)

	return nil
}
