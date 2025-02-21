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
	"github.com/mfreeman451/serviceradar/pkg/models"
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
	Security             *models.SecurityConfig
}

// RunServer starts a service with the provided options and handles lifecycle.
func RunServer(ctx context.Context, opts *ServerOptions) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	log.Printf("*** Starting service %s", opts.ServiceName)

	// Setup and start gRPC server
	grpcServer, err := setupGRPCServer(ctx, opts.ListenAddr, opts.ServiceName, opts.RegisterGRPCServices, opts.Security)
	if err != nil {
		return fmt.Errorf("failed to setup gRPC server: %w", err)
	}

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

func setupGRPCServer(
	ctx context.Context,
	addr, serviceName string,
	registrars []GRPCServiceRegistrar,
	security *models.SecurityConfig) (*grpc.Server, error) {
	// Setup server options
	serverOpts := []grpc.ServerOption{
		grpc.WithMaxRecvSize(MaxRecvSize),
		grpc.WithMaxSendSize(MaxSendSize),
	}

	// Setup security if configured
	if security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, security)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}

		creds, err := provider.GetServerCredentials(ctx)
		if err != nil {
			err := provider.Close()
			if err != nil {
				return nil, err
			}

			return nil, fmt.Errorf("failed to get server credentials: %w", err)
		}

		serverOpts = append(serverOpts, grpc.WithServerOptions(creds))
	}

	// Create and configure gRPC server
	grpcServer := grpc.NewServer(addr, serverOpts...)

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

	return grpcServer, nil
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
	grpcServer.Stop(shutdownCtx)

	// Stop the service
	if err := svc.Stop(shutdownCtx); err != nil {
		log.Printf("Error during service shutdown: %v", err)
		return fmt.Errorf("shutdown error: %w", err)
	}

	// Wait for shutdown context
	<-shutdownCtx.Done()

	return nil
}
