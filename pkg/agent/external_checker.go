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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	maxRetries            = 3
	initialRetryDelay     = 1 * time.Second
	maxRetryDelay         = 30 * time.Second
	initialHealthInterval = 10 * time.Second
	maxHealthInterval     = 5 * time.Minute
	backoffFactor         = 2.0
)

type ExternalChecker struct {
	serviceName          string
	serviceType          string
	address              string
	grpcServiceCheckName string             // NEW FIELD: Actual gRPC service name for health checks (e.g., "monitoring.AgentService")
	clientConfig         ggrpc.ClientConfig // Pre-configured with SecurityProvider
	grpcClient           *ggrpc.Client      // Managed connection
	clientMu             sync.Mutex         // Protects grpcClient
	healthCheckInterval  time.Duration      // Dynamic backoff interval
	lastHealthCheck      time.Time          // Last health check timestamp
	healthStatus         bool               // Last known health status
	logger               logger.Logger
}

var (
	errAddressRequired                = errors.New("address is required for external checker")
	errFailedToCloseSecurityProvider  = errors.New("failed to close security provider")
	errFailedToCloseClient            = errors.New("failed to close client")
	errInvalidAddressUnexpected       = errors.New("invalid address format: expected host:port")
	errInvalidAddressEmpty            = errors.New("invalid address format: host cannot be empty")
	errInvalidPortInAddress           = errors.New("invalid port in address: port must be an integer between 1 and 65535")
	errFailedToCreateSecurityProvider = errors.New("failed to create security provider")
)

func NewExternalChecker(
	ctx context.Context,
	serviceName, serviceType, address, grpcServiceCheckName string,
	security *models.SecurityConfig,
	log logger.Logger,
) (*ExternalChecker, error) {
	log.Info().
		Str("name", serviceName).
		Str("type", serviceType).
		Str("address", address).
		Str("grpcServiceName", grpcServiceCheckName).
		Msg("Configuring new external checker")

	if address == "" {
		return nil, errAddressRequired
	}

	// Validate address format using net.SplitHostPort
	host, portStr, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errInvalidAddressUnexpected, err)
	}

	// Ensure host is non-empty
	if host == "" {
		return nil, fmt.Errorf("%w: %w", errInvalidAddressEmpty, err)
	}

	// Validate port as an integer between 1 and 65535
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("%w: %w", errInvalidPortInAddress, err)
	}

	// Clone security config so we can tailor the ServerName per target without
	// mutating the agent's primary security configuration.
	var securityForService *models.SecurityConfig
	if security != nil {
		cfgCopy := *security
		cfgCopy.TLS = security.TLS

		if host != "" && cfgCopy.ServerName != host {
			log.Info().
				Str("original", cfgCopy.ServerName).
				Str("override", host).
				Str("service", serviceName).
				Msg("Adjusting TLS server_name for external checker")

			cfgCopy.ServerName = host
		}

		securityForService = &cfgCopy
	}

	// Create SecurityProvider once during checker creation using the cloned config
	provider, err := ggrpc.NewSecurityProvider(ctx, securityForService, log)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToCreateSecurityProvider, err)
	}

	clientCfg := ggrpc.ClientConfig{
		Address:          address,
		MaxRetries:       maxRetries,
		SecurityProvider: provider,
		Logger:           log,
	}

	checker := &ExternalChecker{
		serviceName:          serviceName,
		serviceType:          serviceType,
		address:              address,
		grpcServiceCheckName: grpcServiceCheckName,
		clientConfig:         clientCfg,
		grpcClient:           nil,
		healthCheckInterval:  initialHealthInterval,
		lastHealthCheck:      time.Time{},
		healthStatus:         false,
		logger:               log,
	}

	log.Info().
		Str("name", serviceName).
		Str("type", serviceType).
		Str("grpcServiceName", grpcServiceCheckName).
		Msg("Successfully configured external checker")

	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context, req *proto.StatusRequest) (healthy bool, details json.RawMessage) {
	if e.canUseCachedStatus() {
		e.logger.Debug().Str("service", e.serviceName).Bool("status", e.healthStatus).Msg("Using cached health status")

		if !e.healthStatus {
			return false, jsonError("Service unhealthy (cached status)")
		}
	}

	e.clientMu.Lock()
	defer e.clientMu.Unlock()

	if err := e.ensureConnected(ctx); err != nil {
		e.updateHealthStatus(false)
		e.logger.Error().Err(err).Str("service", e.serviceName).Msg("Connection failed")

		return false, jsonError(fmt.Sprintf("Failed to connect: %v", err))
	}

	healthy, err := e.performHealthCheck(ctx, req.ServiceName)
	if err != nil || !healthy {
		e.updateHealthStatus(false)

		e.logger.Error().Err(err).Str("service", e.serviceName).Bool("healthy", healthy).Msg("Health check failed")

		if err != nil {
			return false, jsonError(fmt.Sprintf("Health check failed: %v", err))
		}

		return false, jsonError("Service reported unhealthy")
	}

	e.updateHealthStatus(true)

	e.logger.Debug().Str("service", e.serviceName).Msg("Health check succeeded")

	return e.getServiceDetails(ctx, req)
}

func (e *ExternalChecker) getServiceDetails(ctx context.Context, _ *proto.StatusRequest) (healthy bool, details json.RawMessage) {
	agentClient := proto.NewAgentServiceClient(e.grpcClient.GetConnection())

	status, err := agentClient.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: e.serviceName,
		ServiceType: e.serviceType,
	})
	if err != nil {
		e.logger.Error().Err(err).Str("service", e.serviceName).Msg("Failed to get status details")

		return false, jsonError(fmt.Sprintf("Failed to get status: %v", err))
	}

	return status.Available, status.Message
}

func (e *ExternalChecker) canUseCachedStatus() bool {
	now := time.Now()

	if !e.healthStatus {
		// For unhealthy status, use a shorter cache duration to retry sooner
		return !e.lastHealthCheck.IsZero() && now.Sub(e.lastHealthCheck) < (e.healthCheckInterval/2)
	}

	return !e.lastHealthCheck.IsZero() && now.Sub(e.lastHealthCheck) < e.healthCheckInterval
}

func (e *ExternalChecker) ensureConnected(ctx context.Context) error {
	if e.grpcClient != nil {
		// Check if the existing connection is usable (simplified; could use health check)
		healthy, err := e.grpcClient.CheckHealth(ctx, "")
		if healthy && err == nil {
			return nil
		}

		// Close the unhealthy client
		e.logger.Debug().Str("service", e.serviceName).Msg("Closing unhealthy client")

		if err := e.grpcClient.Close(); err != nil {
			e.logger.Error().Err(err).Str("service", e.serviceName).Msg("Error closing client")
		}

		e.grpcClient = nil
	}

	// Retry connection with backoff
	var lastErr error

	delay := initialRetryDelay

	for attempt := 0; attempt < maxRetries; attempt++ {
		e.logger.Info().
			Str("service", e.serviceName).
			Str("address", e.address).
			Int("attempt", attempt+1).
			Int("maxRetries", maxRetries).
			Msg("Connecting to service")

		client, err := ggrpc.NewClient(ctx, e.clientConfig)
		if err == nil {
			e.grpcClient = client
			e.logger.Info().Str("service", e.serviceName).Msg("Connected successfully")

			return nil
		}

		lastErr = err

		e.logger.Warn().Err(err).Str("service", e.serviceName).Int("attempt", attempt+1).Msg("Connection attempt failed")

		if attempt < maxRetries-1 {
			select {
			case <-time.After(delay):
				delay = min(delay*time.Duration(backoffFactor), maxRetryDelay)
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}

	return fmt.Errorf("failed to connect after %d attempts: %w", maxRetries, lastErr)
}

const (
	defaultMonitoringServiceName = "monitoring.AgentService"
)

func (e *ExternalChecker) performHealthCheck(ctx context.Context, _ string) (bool, error) {
	// If grpcServiceCheckName is "monitoring.AgentService", use custom health check
	if e.grpcServiceCheckName == defaultMonitoringServiceName {
		agentClient := proto.NewAgentServiceClient(e.grpcClient.GetConnection())

		resp, err := agentClient.GetStatus(ctx, &proto.StatusRequest{
			ServiceName: e.serviceName,
			ServiceType: e.serviceType,
		})
		if err != nil {
			return false, fmt.Errorf("custom health check failed: %w", err)
		}

		return resp.Available, nil
	}

	// Otherwise use standard gRPC health check
	healthy, err := e.grpcClient.CheckHealth(ctx, e.grpcServiceCheckName)
	if err != nil {
		return false, fmt.Errorf("health check failed: %w", err)
	}

	return healthy, nil
}

func (e *ExternalChecker) updateHealthStatus(healthy bool) {
	e.healthStatus = healthy
	e.lastHealthCheck = time.Now()

	if healthy {
		e.healthCheckInterval = initialHealthInterval
	} else {
		e.healthCheckInterval = min(time.Duration(float64(e.healthCheckInterval)*backoffFactor), maxHealthInterval)
	}
}

func (e *ExternalChecker) Close() error {
	e.clientMu.Lock()
	defer e.clientMu.Unlock()

	var errs []error

	if e.grpcClient != nil {
		if err := e.grpcClient.Close(); err != nil {
			errs = append(errs, fmt.Errorf("failed to close client: %w", err))
		}

		e.grpcClient = nil
	}

	if e.clientConfig.SecurityProvider != nil {
		if err := e.clientConfig.SecurityProvider.Close(); err != nil {
			errs = append(errs, fmt.Errorf("%w - %w", errFailedToCloseSecurityProvider, err))
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", errFailedToCloseClient, errs)
	}

	return nil
}
