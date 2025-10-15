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

package sync

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"google.golang.org/grpc"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"

	// String constants
	trueString = "true"
)

// New creates a new simplified sync service with explicit dependencies
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncService(ctx, config, kvClient, registry, grpcClient, log)
}

// NewDefault provides a production-ready constructor with default settings
func NewDefault(ctx context.Context, config *Config, log logger.Logger) (*SimpleSyncService, error) {
	return NewWithGRPC(ctx, config, log)
}

// NewWithGRPC sets up the gRPC client for production use with default integrations
func NewWithGRPC(ctx context.Context, config *Config, log logger.Logger) (*SimpleSyncService, error) {
	// Setup gRPC client for KV Store, if configured
	kvClient, grpcClient, err := setupGRPCClient(ctx, config, log)
	if err != nil {
		return nil, err
	}

	// Create simplified sync service
	service, err := createSimpleSyncService(ctx, config, kvClient, grpcClient, log)
	if err != nil {
		if grpcClient != nil {
			_ = grpcClient.Close()
		}

		return nil, err
	}

	return service, nil
}

// createSimpleSyncService creates a new SimpleSyncService instance with the provided dependencies
func createSimpleSyncService(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	grpcClient GRPCClient,
	log logger.Logger,
) (*SimpleSyncService, error) {
	serverName := getServerName(config)

	return NewSimpleSyncService(
		ctx,
		config,
		kvClient,
		defaultIntegrationRegistry(kvClient, grpcClient, serverName),
		grpcClient,
		log,
	)
}

// defaultIntegrationRegistry creates the default integration factory registry
func defaultIntegrationRegistry(
	kvClient proto.KVServiceClient,
	grpcClient GRPCClient,
	serverName string,
) map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig, log logger.Logger) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			return NewArmisIntegration(ctx, config, kvClient, conn, serverName, log)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig, log logger.Logger) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			integ := NewNetboxIntegration(ctx, config, kvClient, conn, serverName, log)
			if val, ok := config.Credentials["expand_subnets"]; ok && val == trueString {
				integ.ExpandSubnets = true
			}

			return integ
		},
	}
}

// setupGRPCClient creates a gRPC client for the KV service
func setupGRPCClient(ctx context.Context, config *Config, log logger.Logger) (proto.KVServiceClient, GRPCClient, error) {
	if config.KVAddress == "" {
		return nil, nil, nil
	}

	clientCfg := ggrpc.ClientConfig{
		Address:          config.KVAddress,
		MaxRetries:       3,
		Logger:           log,
		DisableTelemetry: true,
	}

	if config.Security != nil {
		provider, errSec := ggrpc.NewSecurityProvider(ctx, config.Security, log)
		if errSec != nil {
			return nil, nil, fmt.Errorf("failed to create security provider: %w", errSec)
		}

		clientCfg.SecurityProvider = provider
	}

	c, errCli := ggrpc.NewClient(ctx, clientCfg)
	if errCli != nil {
		if clientCfg.SecurityProvider != nil {
			_ = clientCfg.SecurityProvider.Close()
		}

		return nil, nil, fmt.Errorf("failed to create KV gRPC client: %w", errCli)
	}

	grpcClient := GRPCClient(c)
	kvClient := proto.NewKVServiceClient(c.GetConnection())

	return kvClient, grpcClient, nil
}

// getServerName extracts the server name from config
func getServerName(config *Config) string {
	if config.Security != nil {
		return config.Security.ServerName
	}

	return ""
}

// SRQL adapters removed; SRQL now handled externally.

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client
func NewArmisIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
	log logger.Logger,
) *armis.ArmisIntegration {
	// Extract page size if specified
	pageSize := 100 // default

	if val, ok := config.Credentials["page_size"]; ok {
		if size, err := strconv.Atoi(val); err == nil && size > 0 {
			pageSize = size
		}
	}

	// Create the default HTTP client with circuit breaker and metrics
	baseHTTPClient := &http.Client{
		Timeout: 30 * time.Second,
	}

	// Wrap with metrics collection
	metricsClient := NewMetricsHTTPClient(baseHTTPClient, "armis", NewInMemoryMetrics(log))

	// Wrap with circuit breaker
	circuitBreakerConfig := DefaultCircuitBreakerConfig()
	httpClient := NewCircuitBreakerHTTPClient(metricsClient, "armis-api", circuitBreakerConfig, log)

	// Create the default implementations
	defaultImpl := &armis.DefaultArmisIntegration{
		Config:     config,
		HTTPClient: httpClient,
		Logger:     log,
	}

	// Create the default KV writer
	kvWriter := &armis.DefaultKVWriter{
		KVClient:   kvClient,
		ServerName: serverName,
		AgentID:    config.AgentID,
		Logger:     log,
	}

	// No default sweep config - the agent's file config is authoritative
	// The sync service should only provide network updates

	// SRQL-based SweepResultsQuerier removed; leave nil until external SRQL available

	// Wrap the token provider with caching to avoid 401 errors
	cachedTokenProvider := armis.NewCachedTokenProvider(defaultImpl)

	// Initialize ArmisUpdater for status updates
	var armisUpdater armis.ArmisUpdater

	if config.Credentials["enable_status_updates"] == trueString {
		// Create separate HTTP client for updater with its own circuit breaker
		updaterBaseClient := &http.Client{Timeout: 30 * time.Second}
		updaterMetricsClient := NewMetricsHTTPClient(updaterBaseClient, "armis-updater", NewInMemoryMetrics(log))
		updaterCircuitClient := NewCircuitBreakerHTTPClient(updaterMetricsClient, "armis-updater-api", circuitBreakerConfig, log)

		armisUpdater = armis.NewArmisUpdater(
			config,
			updaterCircuitClient,
			cachedTokenProvider, // Using cached token provider
			log,
		)
	}

	return &armis.ArmisIntegration{
		Config:        config,
		KVClient:      kvClient,
		GRPCConn:      grpcConn,
		ServerName:    serverName,
		PageSize:      pageSize,
		HTTPClient:    httpClient,
		TokenProvider: cachedTokenProvider, // Using cached token provider
		DeviceFetcher: defaultImpl,
		KVWriter:      kvWriter,
		SweeperConfig: nil, // No default config - agent's file config is authoritative
		SweepQuerier:  nil,
		Updater:       armisUpdater,
		Logger:        log,
	}
}

// NewNetboxIntegration creates a new NetboxIntegration instance
func NewNetboxIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
	log logger.Logger,
) *netbox.NetboxIntegration {
	// SRQL-based Querier removed; leave nil until external SRQL available

	return &netbox.NetboxIntegration{
		Config:        config,
		KvClient:      kvClient,
		GrpcConn:      grpcConn,
		ServerName:    serverName,
		ExpandSubnets: false, // Default: treat as /32
		Querier:       nil,
		Logger:        log,
	}
}
