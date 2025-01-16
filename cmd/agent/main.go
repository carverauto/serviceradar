// cmd/agent/main.go
package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/homemon/pkg/agent"
	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"

	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	maxRecvSize = 4 * 1024 * 1024 // 4MB
	maxSendSize = 4 * 1024 * 1024 // 4MB
)

func main() {
	log.Printf("Starting homemon agent...")

	// Command line flags
	configDir := flag.String("config", "/etc/homemon/checkers", "Path to checkers config directory")
	listenAddr := flag.String("listen", ":50051", "gRPC listen address")
	flag.Parse()

	// Create gRPC server
	grpcServer := grpc.NewServer(*listenAddr,
		grpc.WithMaxRecvSize(maxRecvSize),
		grpc.WithMaxSendSize(maxSendSize),
	)

	hs := health.NewServer()
	hs.SetServingStatus("AgentService", healthpb.HealthCheckResponse_SERVING)
	err := grpcServer.RegisterHealthServer(hs)
	if err != nil {
		log.Fatalf("Failed to register health server: %v", err)
	}

	// Create agent server
	server, err := agent.NewServer(*configDir)
	if err != nil {
		log.Fatalf("Failed to create agent server: %v", err)
	}
	defer func(server *agent.Server) {
		err := server.Close()
		if err != nil {
			log.Printf("Failed to close agent server: %v", err)
		}
	}(server)

	// Register agent service with gRPC server
	proto.RegisterAgentServiceServer(grpcServer.GetGRPCServer(), server)

	// Start gRPC server in a goroutine
	errChan := make(chan error, 1)
	go func() {
		log.Printf("gRPC server listening on %s", *listenAddr)
		if err := grpcServer.Start(); err != nil {
			errChan <- err
		}
	}()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Wait for shutdown signal or error
	select {
	case err := <-errChan:
		log.Printf("Server error: %v", err)
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
	}

	// Begin graceful shutdown
	log.Printf("Starting graceful shutdown...")
	grpcServer.Stop()
	log.Printf("Shutdown complete")
}
