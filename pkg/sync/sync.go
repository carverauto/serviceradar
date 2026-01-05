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
	"net/http"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/armis"
	"github.com/carverauto/serviceradar/pkg/sync/integrations/netbox"
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
	registry map[string]IntegrationFactory,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncService(ctx, config, registry, log)
}

// NewDefault provides a production-ready constructor with default settings
func NewDefault(ctx context.Context, config *Config, log logger.Logger) (*SimpleSyncService, error) {
	return createSimpleSyncService(ctx, config, log)
}

// createSimpleSyncService creates a new SimpleSyncService instance with the provided dependencies
func createSimpleSyncService(
	ctx context.Context,
	config *Config,
	log logger.Logger,
) (*SimpleSyncService, error) {
	return NewSimpleSyncService(
		ctx,
		config,
		defaultIntegrationRegistry(),
		log,
	)
}

// defaultIntegrationRegistry creates the default integration factory registry
func defaultIntegrationRegistry() map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig, log logger.Logger) Integration {
			return NewArmisIntegration(ctx, config, log)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig, log logger.Logger) Integration {
			integ := NewNetboxIntegration(ctx, config, log)
			if val, ok := config.Credentials["expand_subnets"]; ok && val == trueString {
				integ.ExpandSubnets = true
			}

			return integ
		},
	}
}

// SRQL adapters removed; SRQL now handled externally.

// NewArmisIntegration creates a new ArmisIntegration instance.
func NewArmisIntegration(
	_ context.Context,
	config *models.SourceConfig,
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
		PageSize:      pageSize,
		HTTPClient:    httpClient,
		TokenProvider: cachedTokenProvider, // Using cached token provider
		DeviceFetcher: defaultImpl,
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
	log logger.Logger,
) *netbox.NetboxIntegration {
	// SRQL-based Querier removed; leave nil until external SRQL available

	return &netbox.NetboxIntegration{
		Config:        config,
		ExpandSubnets: false, // Default: treat as /32
		Querier:       nil,
		Logger:        log,
	}
}
