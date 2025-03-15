package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	ggrpc "google.golang.org/grpc" // Alias for Google's gRPC
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
type GRPCServiceRegistrar func(*ggrpc.Server) error

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

	grpcServer, err := setupGRPCServer(ctx, opts)
	if err != nil {
		return fmt.Errorf("failed to setup gRPC server: %w", err)
	}

	errChan := make(chan error, 1)

	go func() {
		if err := opts.Service.Start(ctx); err != nil {
			errChan <- fmt.Errorf("service start failed: %w", err)
		}
	}()

	go func() {
		log.Printf("Starting gRPC server on %s", opts.ListenAddr)
		if err := grpcServer.Start(); err != nil {
			errChan <- fmt.Errorf("gRPC server failed: %w", err)
		}
	}()

	return handleShutdown(ctx, cancel, grpcServer, opts.Service, errChan)
}

// setupGRPCServer configures and initializes a gRPC server
func setupGRPCServer(ctx context.Context, opts *ServerOptions) (*grpc.Server, error) {
	logSecurityConfig(opts.Security)

	securityProvider, err := initializeSecurityProvider(ctx, opts.Security)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize security provider: %w", err)
	}

	defer func() {
		if err != nil {
			_ = securityProvider.Close()
		}
	}()

	serverOpts, err := configureServerOptions(ctx, securityProvider)
	if err != nil {
		return nil, err
	}

	grpcServer := grpc.NewServer(opts.ListenAddr, serverOpts...)
	log.Printf("Created gRPC server with address: %s", opts.ListenAddr)

	underlyingServer := grpcServer.GetGRPCServer()
	if underlyingServer == nil {
		return nil, errGrpcServer
	}
	registerServices(underlyingServer, opts.RegisterGRPCServices)

	if opts.EnableHealthCheck {
		setupHealthCheck(grpcServer, opts.ServiceName)
	}

	return grpcServer, nil
}

// logSecurityConfig logs the security configuration details
func logSecurityConfig(security *models.SecurityConfig) {
	if security == nil {
		log.Printf("WARNING: No security configuration provided")

		return
	}
	log.Printf("Security configuration: Mode=%s, CertDir=%s, Role=%s",
		security.Mode, security.CertDir, security.Role)
}

// initializeSecurityProvider sets up the appropriate security provider
func initializeSecurityProvider(ctx context.Context, security *models.SecurityConfig) (grpc.SecurityProvider, error) {
	if security == nil {
		log.Printf("No security configuration provided, using no security")

		return &grpc.NoSecurityProvider{}, nil
	}

	secConfig := copySecurityConfig(security)
	normalizeSecurityMode(secConfig)

	provider, err := grpc.NewSecurityProvider(ctx, secConfig)
	if err != nil {
		log.Printf("ERROR creating security provider: %v", err)

		return nil, err
	}

	log.Printf("Successfully created security provider")

	return provider, nil
}

// copySecurityConfig creates a deep copy of the security configuration
func copySecurityConfig(security *models.SecurityConfig) *models.SecurityConfig {
	return &models.SecurityConfig{
		Mode:           security.Mode,
		CertDir:        security.CertDir,
		Role:           security.Role,
		ServerName:     security.ServerName,
		WorkloadSocket: security.WorkloadSocket,
		TrustDomain:    security.TrustDomain,
	}
}

// normalizeSecurityMode ensures the security mode is valid and normalized
func normalizeSecurityMode(config *models.SecurityConfig) {
	if config.Mode == "" {
		log.Printf("WARNING: Security mode is empty, defaulting to 'none'")
		config.Mode = "none"

		return
	}

	log.Printf("Using security mode: %s", config.Mode)

	config.Mode = models.SecurityMode(strings.ToLower(string(config.Mode)))
}

// configureServerOptions sets up gRPC server options including security
func configureServerOptions(ctx context.Context, provider grpc.SecurityProvider) ([]grpc.ServerOption, error) {
	opts := []grpc.ServerOption{
		grpc.WithMaxRecvSize(MaxRecvSize),
		grpc.WithMaxSendSize(MaxSendSize),
	}

	if provider == nil {
		return opts, nil
	}

	creds, err := provider.GetServerCredentials(ctx)
	if err != nil {
		log.Printf("ERROR getting server credentials: %v", err)
		return nil, fmt.Errorf("failed to get server credentials: %w", err)
	}

	// Convert google.golang.org/grpc.ServerOption to pkg/grpc.ServerOption
	opts = append(opts, grpc.WithServerOptions(creds))

	log.Printf("Added server credentials to gRPC options")

	return opts, nil
}

// registerServices registers all provided gRPC services
func registerServices(server *ggrpc.Server, services []GRPCServiceRegistrar) {
	for _, register := range services {
		if err := register(server); err != nil {
			log.Printf("Failed to register gRPC service: %v", err)
		}
	}
}

// setupHealthCheck configures the health check service if enabled
func setupHealthCheck(server *grpc.Server, serviceName string) {
	if err := server.RegisterHealthServer(); err != nil {
		log.Printf("Warning: Failed to register health server: %v", err)

		return
	}

	log.Printf("Successfully registered health server")

	healthCheck := server.GetHealthCheck()
	if healthCheck != nil {
		healthCheck.SetServingStatus(serviceName, healthpb.HealthCheckResponse_SERVING)

		log.Printf("Set health status to SERVING for service: %s", serviceName)
	}
}

const (
	defaultShutdownWait = 100 * time.Millisecond
	defaultErrChan      = 2
)

var (
	errShutdownTimeout = errors.New("timeout shutting down")
	errGrpcServer      = errors.New("failed to get underlying gRPC server")
	errServiceStop     = errors.New("service stop failed")
)

// handleShutdown manages the graceful shutdown process
func handleShutdown(
	ctx context.Context,
	cancel context.CancelFunc,
	grpcServer *grpc.Server,
	svc Service,
	errChan chan error,
) error {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigChan:
		log.Printf("Received signal %v, initiating shutdown", sig)
	case err := <-errChan:
		log.Printf("Received error: %v, initiating shutdown", err)

		return err
	case <-ctx.Done():
		log.Printf("Context canceled, initiating shutdown")

		return ctx.Err()
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), ShutdownTimeout)
	defer shutdownCancel()

	cancel()

	errChanShutdown := make(chan error, defaultErrChan)

	go func() {
		grpcServer.Stop(shutdownCtx)
	}()

	go func() {
		if err := svc.Stop(shutdownCtx); err != nil {
			errChanShutdown <- fmt.Errorf("%w: %w", errServiceStop, err)
		}
	}()

	select {
	case <-shutdownCtx.Done():
		log.Printf("Shutdown timed out")

		return fmt.Errorf("%w: %w", errShutdownTimeout, shutdownCtx.Err())
	case err := <-errChanShutdown:
		return err
	case <-time.After(defaultShutdownWait):
		return nil
	}
}
