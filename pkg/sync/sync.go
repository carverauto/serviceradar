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

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"
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
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			return NewArmisIntegration(ctx, config, kvClient, conn, serverName)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			integ := NewNetboxIntegration(ctx, config, kvClient, conn, serverName)
			if val, ok := config.Credentials["expand_subnets"]; ok && val == "true" {
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
		Address:    config.KVAddress,
		MaxRetries: 3,
		Logger:     log,
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

// armisDeviceStateAdapter adapts sync.DeviceState to armis.DeviceState
type armisDeviceStateAdapter struct {
	querier SRQLQuerier
}

func (a *armisDeviceStateAdapter) GetDeviceStatesBySource(ctx context.Context, source string) ([]armis.DeviceState, error) {
	states, err := a.querier.GetDeviceStatesBySource(ctx, source)
	if err != nil {
		return nil, err
	}

	result := make([]armis.DeviceState, len(states))
	for i, state := range states {
		result[i] = armis.DeviceState{
			DeviceID:    state.DeviceID,
			IP:          state.IP,
			IsAvailable: state.IsAvailable,
			Metadata:    state.Metadata,
		}
	}

	return result, nil
}

// netboxDeviceStateAdapter adapts sync.DeviceState to netbox.DeviceState
type netboxDeviceStateAdapter struct {
	querier SRQLQuerier
}

func (n *netboxDeviceStateAdapter) GetDeviceStatesBySource(ctx context.Context, source string) ([]netbox.DeviceState, error) {
	states, err := n.querier.GetDeviceStatesBySource(ctx, source)
	if err != nil {
		return nil, err
	}

	result := make([]netbox.DeviceState, len(states))
	for i, state := range states {
		result[i] = netbox.DeviceState{
			DeviceID:    state.DeviceID,
			IP:          state.IP,
			IsAvailable: state.IsAvailable,
			Metadata:    state.Metadata,
		}
	}

	return result, nil
}

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client
func NewArmisIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *armis.ArmisIntegration {
	// Extract page size if specified
	pageSize := 100 // default

	if val, ok := config.Credentials["page_size"]; ok {
		if size, err := strconv.Atoi(val); err == nil && size > 0 {
			pageSize = size
		}
	}

	// Create the default HTTP client
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
	}

	// Create the default implementations
	defaultImpl := &armis.DefaultArmisIntegration{
		Config:     config,
		HTTPClient: httpClient,
	}

	// Create the default KV writer
	kvWriter := &armis.DefaultKVWriter{
		KVClient:   kvClient,
		ServerName: serverName,
		AgentID:    config.AgentID,
	}

	// Simplified sweep config - just for KV writing
	defaultSweepCfg := &models.SweepConfig{
		Ports:         []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      config.SweepInterval,
		Concurrency:   100,
		Timeout:       "15s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	// Initialize SweepResultsQuerier if ServiceRadar API credentials are provided
	var sweepQuerier armis.SRQLQuerier

	serviceRadarAPIKey := config.Credentials["api_key"]
	serviceRadarEndpoint := config.Credentials["serviceradar_endpoint"]

	// If no specific ServiceRadar endpoint is provided, assume it's on the same host
	if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
		serviceRadarEndpoint = "http://localhost:8080"
	}

	if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
		baseSweepQuerier := NewSweepResultsQuery(
			serviceRadarEndpoint,
			serviceRadarAPIKey,
			httpClient,
		)
		sweepQuerier = &armisDeviceStateAdapter{querier: baseSweepQuerier}
	}

	// Initialize ArmisUpdater for status updates
	var armisUpdater armis.ArmisUpdater
	if config.Credentials["enable_status_updates"] == "true" {
		armisUpdater = armis.NewArmisUpdater(
			config,
			httpClient,
			defaultImpl, // Using defaultImpl as TokenProvider
		)
	}

	return &armis.ArmisIntegration{
		Config:        config,
		KVClient:      kvClient,
		GRPCConn:      grpcConn,
		ServerName:    serverName,
		PageSize:      pageSize,
		HTTPClient:    httpClient,
		TokenProvider: defaultImpl,
		DeviceFetcher: defaultImpl,
		KVWriter:      kvWriter,
		SweeperConfig: defaultSweepCfg,
		SweepQuerier:  sweepQuerier,
		Updater:       armisUpdater,
	}
}

// NewNetboxIntegration creates a new NetboxIntegration instance
func NewNetboxIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *netbox.NetboxIntegration {
	// Add SRQL Querier for retraction logic, if configured
	var sweepQuerier netbox.SRQLQuerier

	serviceRadarAPIKey := config.Credentials["api_key"]
	serviceRadarEndpoint := config.Credentials["serviceradar_endpoint"]

	if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
		serviceRadarEndpoint = "http://localhost:8080"
	}

	if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
		httpClient := &http.Client{Timeout: 30 * time.Second}

		baseSweepQuerier := NewSweepResultsQuery(
			serviceRadarEndpoint,
			serviceRadarAPIKey,
			httpClient,
		)

		sweepQuerier = &netboxDeviceStateAdapter{querier: baseSweepQuerier}
	}

	return &netbox.NetboxIntegration{
		Config:        config,
		KvClient:      kvClient,
		GrpcConn:      grpcConn,
		ServerName:    serverName,
		ExpandSubnets: false, // Default: treat as /32
		Querier:       sweepQuerier,
	}
}
