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

// Package integrations pkg/sync/integrations/integrations.go
package integrations

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client.
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
	}

	defaultSweepCfg := &models.SweepConfig{
		Ports:         []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "10m",
		Concurrency:   100,
		Timeout:       "15s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	// Initialize SweepResultsQuerier if ServiceRadar API credentials are provided
	var sweepQuerier armis.SweepResultsQuerier

	serviceRadarAPIKey := config.Credentials["api_key"]
	serviceRadarEndpoint := config.Credentials["serviceradar_endpoint"]

	// If no specific ServiceRadar endpoint is provided, assume it's on the same host
	if serviceRadarEndpoint == "" && serviceRadarAPIKey != "" {
		// Extract host from Armis endpoint if possible, otherwise use localhost
		serviceRadarEndpoint = "http://localhost:8080"
	}

	if serviceRadarAPIKey != "" && serviceRadarEndpoint != "" {
		sweepQuerier = armis.NewSweepResultsQuery(
			serviceRadarEndpoint,
			serviceRadarAPIKey,
			httpClient,
		)
	}

	// Initialize ArmisUpdater (placeholder - needs actual implementation based on Armis API)
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

// NewNetboxIntegration creates a new NetboxIntegration instance.
func NewNetboxIntegration(
	_ context.Context,
	config *models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *netbox.NetboxIntegration {
	return &netbox.NetboxIntegration{
		Config:        config,
		KvClient:      kvClient,
		GrpcConn:      grpcConn,
		ServerName:    serverName,
		ExpandSubnets: false, // Default: treat as /32 //TODO: make this configurable
	}
}
