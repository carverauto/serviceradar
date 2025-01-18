// cmd/agent/main.go
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/serviceradar/pkg/agent"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/proto"

	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	maxRecvSize = 4 * 1024 * 1024 // 4MB
	maxSendSize = 4 * 1024 * 1024 // 4MB
)

func main() {
	log.Printf("Starting serviceradar agent...")

	// Command line flags
	configDir := flag.String("config", "/etc/serviceradar/checkers", "Path to checkers config directory")
	listenAddr := flag.String("listen", ":50051", "gRPC listen address")
	flag.Parse()

	// Create main context
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Create agent server first
	server, err := agent.NewServer(*configDir)
	if err != nil {
		log.Fatalf("Failed to create agent server: %v", err)
	}

	// Create and configure gRPC server
	grpcServer := grpc.NewServer(*listenAddr,
		grpc.WithMaxRecvSize(maxRecvSize),
		grpc.WithMaxSendSize(maxSendSize),
	)

	// Setup health check
	hs := health.NewServer()
	hs.SetServingStatus("AgentService", healthpb.HealthCheckResponse_SERVING)
	if err := grpcServer.RegisterHealthServer(hs); err != nil {
		log.Fatalf("Failed to register health server: %v", err)
	}

	// Register agent service
	proto.RegisterAgentServiceServer(grpcServer.GetGRPCServer(), server)

	// Start the gRPC server
	errChan := make(chan error, 1)
	go func() {
		log.Printf("Starting gRPC server on %s", *listenAddr)
		if err := grpcServer.Start(); err != nil {
			errChan <- err
		}
	}()

	// Start the agent services
	if err := server.Start(ctx); err != nil {
		log.Printf("Warning: Failed to start some agent services: %v", err)
	}

	// Handle shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
	case err := <-errChan:
		log.Printf("Server error: %v, initiating shutdown", err)
	}

	// Begin graceful shutdown
	log.Printf("Starting graceful shutdown...")

	// Stop gRPC server
	grpcServer.Stop()

	// Close agent server
	if err := server.Close(); err != nil {
		log.Printf("Error during server shutdown: %v", err)
	}

	log.Printf("Shutdown complete")
}
