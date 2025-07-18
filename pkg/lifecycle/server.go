/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package lifecycle

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
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
	LoggerConfig         *logger.Config
	Logger               logger.Logger // Optional: if provided, uses this logger instead of creating a new one
}

// RunServer starts a service with the provided options and handles lifecycle.
func RunServer(ctx context.Context, opts *ServerOptions) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Initialize logger if not provided
	var log logger.Logger

	if opts.Logger == nil {
		// No logger was provided, create one
		createdLogger, err := CreateComponentLogger(ctx, opts.ServiceName, opts.LoggerConfig)
		if err != nil {
			return fmt.Errorf("failed to initialize logger: %w", err)
		}

		log = createdLogger

		defer func() {
			if err := ShutdownLogger(); err != nil {
				log.Error().Err(err).Msg("Failed to shutdown logger")
			}
		}()
	} else {
		log = opts.Logger
	}

	grpcServer, err := setupGRPCServer(ctx, opts, log)
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
		log.Info().Str("address", opts.ListenAddr).Msg("Starting gRPC server")

		if err := grpcServer.Start(); err != nil {
			errChan <- fmt.Errorf("gRPC server failed: %w", err)
		}
	}()

	return handleShutdown(ctx, cancel, grpcServer, opts.Service, errChan, log)
}

// setupGRPCServer configures and initializes a gRPC server.
func setupGRPCServer(ctx context.Context, opts *ServerOptions, log logger.Logger) (*grpc.Server, error) {
	logSecurityConfig(opts.Security, log)

	securityProvider, err := initializeSecurityProvider(ctx, opts.Security, log)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize security provider: %w", err)
	}

	defer func() {
		if err != nil {
			_ = securityProvider.Close()
		}
	}()

	serverOpts, err := configureServerOptions(ctx, securityProvider, log)
	if err != nil {
		return nil, err
	}

	grpcServer := grpc.NewServer(opts.ListenAddr, log, serverOpts...)

	log.Info().Str("address", opts.ListenAddr).Msg("Created gRPC server")

	underlyingServer := grpcServer.GetGRPCServer()
	if underlyingServer == nil {
		return nil, errGrpcServer
	}

	registerServices(underlyingServer, opts.RegisterGRPCServices, log)

	if opts.EnableHealthCheck {
		setupHealthCheck(grpcServer, opts.ServiceName, log)
	}

	return grpcServer, nil
}

// logSecurityConfig logs the security configuration details.
func logSecurityConfig(security *models.SecurityConfig, log logger.Logger) {
	if security == nil {
		log.Warn().Msg("No security configuration provided")

		return
	}

	log.Info().
		Str("mode", string(security.Mode)).
		Str("certDir", security.CertDir).
		Str("role", string(security.Role)).
		Msg("Security configuration")
}

// initializeSecurityProvider sets up the appropriate security provider.
func initializeSecurityProvider(ctx context.Context, security *models.SecurityConfig, log logger.Logger) (grpc.SecurityProvider, error) {
	if security == nil {
		log.Info().Msg("No security configuration provided, using no security")

		return &grpc.NoSecurityProvider{}, nil
	}

	secConfig := copySecurityConfig(security)
	normalizeSecurityMode(secConfig, log)

	provider, err := grpc.NewSecurityProvider(ctx, secConfig, log)
	if err != nil {
		log.Error().Err(err).Msg("Failed to create security provider")

		return nil, err
	}

	log.Info().Msg("Successfully created security provider")

	return provider, nil
}

// copySecurityConfig creates a deep copy of the security configuration.
func copySecurityConfig(security *models.SecurityConfig) *models.SecurityConfig {
	return &models.SecurityConfig{
		Mode:           security.Mode,
		CertDir:        security.CertDir,
		Role:           security.Role,
		ServerName:     security.ServerName,
		WorkloadSocket: security.WorkloadSocket,
		TrustDomain:    security.TrustDomain,
		TLS: struct {
			CertFile     string `json:"cert_file"`
			KeyFile      string `json:"key_file"`
			CAFile       string `json:"ca_file"`
			ClientCAFile string `json:"client_ca_file"`
		}{
			CertFile:     security.TLS.CertFile,
			KeyFile:      security.TLS.KeyFile,
			CAFile:       security.TLS.CAFile,
			ClientCAFile: security.TLS.ClientCAFile,
		},
	}
}

// normalizeSecurityMode ensures the security mode is valid and normalized.
func normalizeSecurityMode(config *models.SecurityConfig, log logger.Logger) {
	if config.Mode == "" {
		log.Warn().Msg("Security mode is empty, defaulting to 'none'")

		config.Mode = "none"

		return
	}

	log.Info().Str("mode", string(config.Mode)).Msg("Using security mode")

	config.Mode = models.SecurityMode(strings.ToLower(string(config.Mode)))
}

// configureServerOptions sets up gRPC server options including security.
func configureServerOptions(ctx context.Context, provider grpc.SecurityProvider, log logger.Logger) ([]grpc.ServerOption, error) {
	opts := []grpc.ServerOption{
		grpc.WithMaxRecvSize(MaxRecvSize),
		grpc.WithMaxSendSize(MaxSendSize),
	}

	if provider == nil {
		return opts, nil
	}

	creds, err := provider.GetServerCredentials(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get server credentials")
		return nil, fmt.Errorf("failed to get server credentials: %w", err)
	}

	// Convert google.golang.org/grpc.ServerOption to pkg/grpc.ServerOption
	opts = append(opts, grpc.WithServerOptions(creds))

	log.Info().Msg("Added server credentials to gRPC options")

	return opts, nil
}

// registerServices registers all provided gRPC services.
func registerServices(server *ggrpc.Server, services []GRPCServiceRegistrar, log logger.Logger) {
	for _, register := range services {
		if err := register(server); err != nil {
			log.Error().Err(err).Msg("Failed to register gRPC service")
		}
	}
}

// setupHealthCheck configures the health check service if enabled.
func setupHealthCheck(server *grpc.Server, serviceName string, log logger.Logger) {
	if err := server.RegisterHealthServer(); err != nil {
		log.Warn().Err(err).Msg("Failed to register health server")

		return
	}

	log.Info().Msg("Successfully registered health server")

	healthCheck := server.GetHealthCheck()
	if healthCheck != nil {
		healthCheck.SetServingStatus(serviceName, healthpb.HealthCheckResponse_SERVING)

		log.Info().Str("service", serviceName).Msg("Set health status to SERVING")
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

// handleShutdown manages the graceful shutdown process.
func handleShutdown(
	ctx context.Context,
	cancel context.CancelFunc,
	grpcServer *grpc.Server,
	svc Service,
	errChan chan error,
	log logger.Logger,
) error {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigChan:
		log.Info().Str("signal", sig.String()).Msg("Received signal, initiating shutdown")
	case err := <-errChan:
		log.Error().Err(err).Msg("Received error, initiating shutdown")

		return err
	case <-ctx.Done():
		log.Info().Msg("Context canceled, initiating shutdown")

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
		log.Error().Msg("Shutdown timed out")

		return fmt.Errorf("%w: %w", errShutdownTimeout, shutdownCtx.Err())
	case err := <-errChanShutdown:
		return err
	case <-time.After(defaultShutdownWait):
		return nil
	}
}
