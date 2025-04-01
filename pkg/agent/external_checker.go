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
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
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
	serviceName         string
	serviceType         string
	address             string
	clientConfig        ggrpc.ClientConfig // Pre-configured with SecurityProvider
	grpcClient          *ggrpc.Client      // Managed connection
	clientMu            sync.Mutex         // Protects grpcClient
	healthCheckInterval time.Duration      // Dynamic backoff interval
	lastHealthCheck     time.Time          // Last health check timestamp
	healthStatus        bool               // Last known health status
}

var (
	errAddressRequired               = fmt.Errorf("address is required for external checker")
	errFailedToCloseSecurityProvider = errors.New("failed to close security provider")
	errFailedToCloseClient           = errors.New("failed to close client")
)

func NewExternalChecker(
	ctx context.Context,
	serviceName, serviceType, address string,
	security *models.SecurityConfig,
) (*ExternalChecker, error) {
	log.Printf("Configuring new external checker name=%s type=%s at %s", serviceName, serviceType, address)

	if address == "" {
		return nil, errAddressRequired
	}

	// Create SecurityProvider once during checker creation
	provider, err := ggrpc.NewSecurityProvider(ctx, security)
	if err != nil {
		return nil, fmt.Errorf("failed to create security provider: %w", err)
	}

	// Configure client options, but don’t connect yet
	clientCfg := ggrpc.ClientConfig{
		Address:          address,
		MaxRetries:       maxRetries,
		SecurityProvider: provider,
	}

	checker := &ExternalChecker{
		serviceName:         serviceName,
		serviceType:         serviceType,
		address:             address,
		clientConfig:        clientCfg,
		grpcClient:          nil, // Defer connection to Check
		healthCheckInterval: initialHealthInterval,
		lastHealthCheck:     time.Time{},
		healthStatus:        false, // Assume unhealthy until proven otherwise
	}

	log.Printf("Successfully configured external checker name=%s type=%s", serviceName, serviceType)

	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context) (healthy bool, details string) {
	// Use RLock initially to check cached health status
	if e.canUseCachedStatus() {
		log.Printf("ExternalChecker %s: Using cached health status: %v", e.serviceName, e.healthStatus)

		if !e.healthStatus {
			healthy = false
			details = "Service unhealthy (cached status)"

			return healthy, details
		}
	}

	// Lock for connection management and health check
	e.clientMu.Lock()
	defer e.clientMu.Unlock()

	// Ensure the client is connected
	if err := e.ensureConnected(ctx); err != nil {
		e.updateHealthStatus(false)

		log.Printf("ExternalChecker %s: Connection failed: %v", e.serviceName, err)

		healthy = false
		details = fmt.Sprintf("Failed to connect: %v", err)

		return healthy, details
	}

	// Perform health check with retry logic
	healthy, err := e.performHealthCheck(ctx)
	if err != nil || !healthy {
		e.updateHealthStatus(false)

		log.Printf("ExternalChecker %s: Health check failed (Healthy: %v, Err: %v)", e.serviceName, healthy, err)

		if err != nil {
			healthy = false
			details = fmt.Sprintf("Health check failed: %v", err)

			return healthy, details
		}

		healthy = false
		details = "Service reported unhealthy"

		return healthy, details
	}

	// Update health status on success
	e.updateHealthStatus(true)

	log.Printf("ExternalChecker %s: Health check succeeded", e.serviceName)

	// Optionally fetch detailed status
	return e.getServiceDetails(ctx)
}

func (e *ExternalChecker) canUseCachedStatus() bool {
	now := time.Now()

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
		log.Printf("ExternalChecker %s: Closing unhealthy client", e.serviceName)

		if err := e.grpcClient.Close(); err != nil {
			log.Printf("ExternalChecker %s: Error closing client: %v", e.serviceName, err)
		}

		e.grpcClient = nil
	}

	// Retry connection with backoff
	var lastErr error

	delay := initialRetryDelay

	for attempt := 0; attempt < maxRetries; attempt++ {
		log.Printf("ExternalChecker %s: Connecting to %s (attempt %d/%d)", e.serviceName, e.address, attempt+1, maxRetries)

		client, err := ggrpc.NewClient(ctx, e.clientConfig)
		if err == nil {
			e.grpcClient = client
			log.Printf("ExternalChecker %s: Connected successfully", e.serviceName)

			return nil
		}

		lastErr = err

		log.Printf("ExternalChecker %s: Connection attempt %d failed: %v", e.serviceName, attempt+1, err)

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

func (e *ExternalChecker) performHealthCheck(ctx context.Context) (bool, error) {
	healthy, err := e.grpcClient.CheckHealth(ctx, "")
	if err != nil {
		return false, fmt.Errorf("health check failed: %w", err)
	}

	return healthy, nil
}

func (e *ExternalChecker) getServiceDetails(ctx context.Context) (healthy bool, details string) {
	agentClient := proto.NewAgentServiceClient(e.grpcClient.GetConnection())
	start := time.Now()

	status, err := agentClient.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: e.serviceName,
		ServiceType: e.serviceType,
	})
	if err != nil {
		log.Printf("ExternalChecker %s: Failed to get status details: %v", e.serviceName, err)

		return false, fmt.Sprintf(`{"error": "Failed to get status: %v"}`, err)
	}

	responseTime := time.Since(start).Nanoseconds()

	// Use the Available field from the StatusResponse to determine health
	healthy = status.Available
	details = fmt.Sprintf(`{"status": %q, "response_time": %d, "available": %t}`,
		status.Message, responseTime, status.Available)

	return healthy, details
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
