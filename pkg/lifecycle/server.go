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
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	ggrpc "google.golang.org/grpc" // Alias to avoid naming conflict
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
// Changed to take *ggrpc.Server directly since that's what services need.
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

	// Setup and start gRPC server
	grpcServer, err := setupGRPCServer(ctx, opts)
	if err != nil {
		return fmt.Errorf("failed to setup gRPC server: %w", err)
	}

	// Create error channel for service errors
	errChan := make(chan error, 1)

	// Start the service
	go func() {
		if err := opts.Service.Start(ctx); err != nil {
			errChan <- fmt.Errorf("service start failed: %w", err)
		}
	}()

	// Start gRPC server
	go func() {
		log.Printf("Starting gRPC server on %s", opts.ListenAddr)
		if err := grpcServer.Start(); err != nil {
			errChan <- fmt.Errorf("gRPC server failed: %w", err)
		}
	}()

	// Handle shutdown
	return handleShutdown(ctx, cancel, grpcServer, opts.Service, errChan)
}

func setupGRPCServer(ctx context.Context, opts *ServerOptions) (*grpc.Server, error) {
	// Debug logging for security configuration
	if opts.Security != nil {
		log.Printf("Security configuration: Mode=%s, CertDir=%s, Role=%s",
			opts.Security.Mode,
			opts.Security.CertDir,
			opts.Security.Role)
	} else {
		log.Printf("WARNING: No security configuration provided")
	}

	// Create security provider if configured
	var securityProvider grpc.SecurityProvider
	if opts.Security != nil {
		var err error

		// Deep copy security config to ensure it's not modified elsewhere
		secConfig := &models.SecurityConfig{
			Mode:           opts.Security.Mode,
			CertDir:        opts.Security.CertDir,
			Role:           opts.Security.Role,
			ServerName:     opts.Security.ServerName,
			WorkloadSocket: opts.Security.WorkloadSocket,
			TrustDomain:    opts.Security.TrustDomain,
		}

		// Validate that the mode is properly set
		if secConfig.Mode == "" {
			log.Printf("WARNING: Security mode is empty, defaulting to 'none'")
			secConfig.Mode = "none"
		} else {
			log.Printf("Using security mode: %s", secConfig.Mode)

			// Normalize mode to lowercase for consistent comparison
			modeStr := strings.ToLower(string(secConfig.Mode))
			secConfig.Mode = models.SecurityMode(modeStr)
		}

		securityProvider, err = grpc.NewSecurityProvider(ctx, secConfig)
		if err != nil {
			log.Printf("ERROR creating security provider: %v", err)
			return nil, fmt.Errorf("failed to create security provider: %w", err)
		}
		log.Printf("Successfully created security provider")
	} else {
		log.Printf("No security configuration provided, using no security")
		securityProvider = &grpc.NoSecurityProvider{}
	}

	// Configure server options
	serverOpts := []grpc.ServerOption{
		grpc.WithMaxRecvSize(MaxRecvSize),
		grpc.WithMaxSendSize(MaxSendSize),
	}

	// Add security if provided
	if securityProvider != nil {
		serverCreds, err := securityProvider.GetServerCredentials(ctx)
		if err != nil {
			log.Printf("ERROR getting server credentials: %v", err)
			_ = securityProvider.Close() // Cleanup on failure
			return nil, fmt.Errorf("failed to get server credentials: %w", err)
		}
		serverOpts = append(serverOpts, grpc.WithServerOptions(serverCreds))
		log.Printf("Added server credentials to gRPC options")
	}

	// Create the server with the new API
	grpcServer := grpc.NewServer(opts.ListenAddr, serverOpts...)
	log.Printf("Created gRPC server with address: %s", opts.ListenAddr)

	// Register all provided services
	underlyingServer := grpcServer.GetGRPCServer()
	for _, register := range opts.RegisterGRPCServices {
		if err := register(underlyingServer); err != nil {
			log.Printf("Failed to register gRPC service: %v", err)
		}
	}

	// Setup health check if enabled - register through the server's RegisterHealthServer method
	if opts.EnableHealthCheck {
		if err := grpcServer.RegisterHealthServer(); err != nil {
			log.Printf("Warning: Failed to register health server: %v", err)
		} else {
			log.Printf("Successfully registered health server")
		}

		// Set serving status for the service
		if healthCheck := grpcServer.GetHealthCheck(); healthCheck != nil {
			healthCheck.SetServingStatus(opts.ServiceName, healthpb.HealthCheckResponse_SERVING)
			log.Printf("Set health status to SERVING for service: %s", opts.ServiceName)
		}
	}

	return grpcServer, nil
}

func handleShutdown(
	ctx context.Context,
	cancel context.CancelFunc,
	grpcServer *grpc.Server,
	svc Service,
	errChan chan error,
) error {
	// Setup signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Wait for shutdown signal or error
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

	// Create timeout context for shutdown
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), ShutdownTimeout)
	defer shutdownCancel()

	// Cancel main context
	cancel()

	// Stop gRPC server and service
	errChanShutdown := make(chan error, 2)
	go func() {
		// Stop doesn't return an error anymore, just call it
		grpcServer.Stop(shutdownCtx)
	}()
	go func() {
		if err := svc.Stop(shutdownCtx); err != nil {
			errChanShutdown <- fmt.Errorf("service stop failed: %w", err)
		}
	}()

	// Wait for shutdown to complete or timeout
	select {
	case <-shutdownCtx.Done():
		log.Printf("Shutdown timed out")
		return fmt.Errorf("shutdown timed out after %v", ShutdownTimeout)
	case err := <-errChanShutdown:
		return err
	case <-time.After(100 * time.Millisecond): // Give a bit of time for any potential errors
		// If no errors after the wait, consider shutdown successful
		return nil
	}
}
