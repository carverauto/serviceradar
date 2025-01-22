// cmd/checkers/dusk/main.go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"

	"github.com/mfreeman451/serviceradar/pkg/checker/dusk"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/lifecycle"
	"github.com/mfreeman451/serviceradar/proto"
)

const (
	maxRecvSize = 4 * 1024 * 1024 // 4MB
	maxSendSize = 4 * 1024 * 1024 // 4MB
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

	// Load configuration
	config, err := dusk.LoadConfig(*configPath)
	if err != nil {
		return fmt.Errorf("failed to load config: %v", err)
	}

	// Create the checker
	checker := &dusk.DuskChecker{
		Config: config,
		Done:   make(chan struct{}),
	}

	// Create block service
	blockService := dusk.NewDuskBlockService(checker)

	// Create gRPC service registrar
	registerService := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s.GetGRPCServer(), blockService)
		return nil
	}

	// Create a wrapper service that implements lifecycle.Service
	service := &duskService{
		checker: checker,
	}

	// Run service with lifecycle management
	return lifecycle.RunServer(context.Background(), lifecycle.ServerOptions{
		ListenAddr:           config.ListenAddr,
		Service:              service,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true,
	})
}

// duskService wraps the DuskChecker to implement lifecycle.Service
type duskService struct {
	checker *dusk.DuskChecker
}

func (s *duskService) Start(ctx context.Context) error {
	return s.checker.StartMonitoring(ctx)
}

func (s *duskService) Stop() error {
	close(s.checker.Done)
	return nil
}
