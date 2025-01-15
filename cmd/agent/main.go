// cmd/agent/main.go
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/mfreeman451/homemon/pkg/agent"
	"github.com/mfreeman451/homemon/pkg/grpc"
	"github.com/mfreeman451/homemon/proto"
)

func main() {
	log.Printf("Starting homemon agent...")

	// Command line flags
	configDir := flag.String("config", "/etc/homemon/checkers", "Path to checkers config directory")
	listenAddr := flag.String("listen", ":50051", "gRPC listen address")
	flag.Parse()

	// Create context that can be canceled
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Create gRPC server
	grpcServer := grpc.NewServer(*listenAddr,
		grpc.WithMaxRecvSize(4*1024*1024), // 4MB
		grpc.WithMaxSendSize(4*1024*1024), // 4MB
	)

	// Create agent server
	server := agent.NewServer(*configDir)
	defer server.Close()

	// Register agent service with gRPC server
	proto.RegisterAgentServiceServer(grpcServer, server)

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

	// Cancel context to stop any ongoing operations
	cancel()

	// Stop gRPC server
	grpcServer.Stop()

	log.Printf("Shutdown complete")
}
