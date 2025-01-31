// Package lifecycle pkg/lifecycle/server.go
package lifecycle

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	MaxRecvSize     = 4 * 1024 * 1024 // 4MB
	MaxSendSize     = 4 * 1024 * 1024 // 4MB
	ShutdownTimeout = 10 * time.Second
)

// Service defines the interface that all services must implement.
type Service interface {
	Start(context.Context) error
	Stop(context.Context) error
}

// GRPCServiceRegistrar is a function type for registering gRPC services.
type GRPCServiceRegistrar func(*grpc.Server) error

// ServerOptions holds configuration for creating a server.
type ServerOptions struct {
	ListenAddr           string
	ServiceName          string
	Service              Service
	RegisterGRPCServices []GRPCServiceRegistrar
	EnableHealthCheck    bool
}

// RunServer starts a service with the provided options and handles lifecycle.
func RunServer(ctx context.Context, opts *ServerOptions) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Setup and start gRPC server
	grpcServer := setupGRPCServer(opts.ListenAddr, opts.ServiceName, opts.RegisterGRPCServices)

	// Create error channel for service errors
	errChan := make(chan error, 1)

	// Start the service
	go func() {
		if err := opts.Service.Start(ctx); err != nil {
			select {
			case errChan <- err:
			default:
				log.Printf("Service error: %v", err)
			}
		}
	}()

	// Start gRPC server
	go func() {
		log.Printf("Starting gRPC server on %s", opts.ListenAddr)

		if err := grpcServer.Start(); err != nil {
			select {
			case errChan <- err:
			default:
				log.Printf("gRPC server error: %v", err)
			}
		}
	}()

	// Handle shutdown
	return handleShutdown(ctx, cancel, grpcServer, opts.Service, errChan)
}

func setupGRPCServer(addr, serviceName string, registrars []GRPCServiceRegistrar) *grpc.Server {
	// Create and configure gRPC server
	grpcServer := grpc.NewServer(addr,
		grpc.WithMaxRecvSize(MaxRecvSize),
		grpc.WithMaxSendSize(MaxSendSize),
	)

	// Setup health check
	hs := health.NewServer()
	hs.SetServingStatus(serviceName, healthpb.HealthCheckResponse_SERVING)

	if err := grpcServer.RegisterHealthServer(hs); err != nil {
		log.Printf("Failed to register health server: %v", err)
	}

	// Register all provided services
	for _, register := range registrars {
		if err := register(grpcServer); err != nil {
			log.Printf("Failed to register gRPC service: %v", err)
		}
	}

	return grpcServer
}

func handleShutdown(
	ctx context.Context, cancel context.CancelFunc, grpcServer *grpc.Server, svc Service, errChan chan error) error {
	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
	case err := <-errChan:
		log.Printf("Received error: %v, initiating shutdown", err)

		return fmt.Errorf("service error: %w", err)
	case <-ctx.Done():
		log.Printf("Context canceled, initiating shutdown")

		return ctx.Err()
	}

	// Create timeout context for shutdown
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), ShutdownTimeout)
	defer shutdownCancel()

	// Cancel main context
	cancel()

	// Stop gRPC server
	grpcServer.Stop(ctx)

	// Stop the service
	if err := svc.Stop(ctx); err != nil {
		log.Printf("Error during service shutdown: %v", err)

		return fmt.Errorf("shutdown error: %w", err)
	}

	// Wait for shutdown context
	<-shutdownCtx.Done()

	return nil
}
