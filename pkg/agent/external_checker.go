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
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	maxRetries = 3
)

var (
	errHealth        = fmt.Errorf("service is not healthy")
	errServiceHealth = fmt.Errorf("service is not healthy")
)

const (
	// Initial health check interval
	initialHealthCheckInterval = 10 * time.Second
	// Max health check interval when backing off
	maxHealthCheckInterval = 5 * time.Minute
	// How much to increase interval after each failure
	backoffFactor = 2.0
)

// ExternalChecker implements checker.Checker for external checker processes.
type ExternalChecker struct {
	serviceName         string
	serviceType         string
	address             string
	client              *grpc.Client
	healthCheckMu       sync.Mutex
	healthCheckInterval time.Duration
	lastHealthCheck     time.Time
	healthStatus        bool
}

// NewExternalChecker creates a new checker that connects to an external process.
func NewExternalChecker(ctx context.Context, serviceName, serviceType, address string) (*ExternalChecker, error) {
	log.Printf("Creating new external checker name=%s type=%s at %s", serviceName, serviceType, address)

	clientCfg := grpc.ClientConfig{
		Address:    address,
		MaxRetries: maxRetries,
	}

	security := models.SecurityConfig{
		Mode:       "mtls",
		CertDir:    "/etc/serviceradar/certs", // TODO: Make configurable
		ServerName: strings.Split(address, ":")[0],
		Role:       "agent",
	}

	provider, err := grpc.NewSecurityProvider(ctx, &security)

	if err != nil {
		return nil, fmt.Errorf("failed to create security provider: %w", err)
	}

	clientCfg.SecurityProvider = provider

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create gRPC client: %w", err)
	}

	checker := &ExternalChecker{
		serviceName:         serviceName,
		serviceType:         serviceType,
		address:             address,
		client:              client,
		healthCheckInterval: initialHealthCheckInterval,
		lastHealthCheck:     time.Time{},
	}

	// Initial health check
	healthy, err := client.CheckHealth(ctx, "")
	if err != nil {
		if closeErr := client.Close(); closeErr != nil {
			return nil, closeErr
		}

		return nil, fmt.Errorf("extChecker: %w, err: %w", errHealth, err)
	}

	if !healthy {
		if err := client.Close(); err != nil {
			return nil, err
		}

		return nil, errServiceHealth
	}

	log.Printf("Successfully created external checker name=%s type=%s", serviceName, serviceType)

	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context) (isAccessible bool, statusMsg string) {
	// Check if we can use cached status first
	if e.canUseCachedStatus() {
		return e.handleCachedStatus()
	}

	// Perform health check if needed
	healthy, err := e.performHealthCheck(ctx)
	if !healthy || err != nil {
		return e.handleHealthCheckFailure(err)
	}

	// Get service details
	return e.getServiceDetails(ctx)
}

func (e *ExternalChecker) canUseCachedStatus() bool {
	e.healthCheckMu.Lock()
	defer e.healthCheckMu.Unlock()

	now := time.Now()
	return !e.lastHealthCheck.IsZero() &&
		now.Sub(e.lastHealthCheck) < e.healthCheckInterval
}

func (e *ExternalChecker) handleCachedStatus() (isAccessible bool, statusMsg string) {
	e.healthCheckMu.Lock()
	defer e.healthCheckMu.Unlock()

	if !e.healthStatus {
		return false, "Service unhealthy (cached status)"
	}
	return true, "" // Will proceed to get details in original flow
}

func (e *ExternalChecker) performHealthCheck(ctx context.Context) (bool, error) {
	e.healthCheckMu.Lock()
	defer e.healthCheckMu.Unlock()

	healthy, err := e.client.CheckHealth(ctx, "")
	now := time.Now()
	e.lastHealthCheck = now
	e.healthStatus = healthy && err == nil

	if healthy && err == nil {
		e.healthCheckInterval = initialHealthCheckInterval
		return true, nil
	}

	// If we reach here, either unhealthy or error occurred
	e.healthCheckInterval = time.Duration(float64(e.healthCheckInterval) * backoffFactor)
	if e.healthCheckInterval > maxHealthCheckInterval {
		e.healthCheckInterval = maxHealthCheckInterval
	}

	return healthy, err
}

func (e *ExternalChecker) handleHealthCheckFailure(err error) (isAccessible bool, statusMsg string) {
	if err != nil {
		log.Printf("External checker %s: Health check failed: %v", e.serviceName, err)
		return false, fmt.Sprintf("Health check failed: %v", err)
	}
	log.Printf("External checker %s: Service reported unhealthy", e.serviceName)
	return false, "Service reported unhealthy"
}

func (e *ExternalChecker) getServiceDetails(ctx context.Context) (isAccessible bool, statusMsg string) {
	client := proto.NewAgentServiceClient(e.client.GetConnection())
	start := time.Now()

	status, err := client.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: e.serviceName,
		ServiceType: e.serviceType,
	})
	if err != nil {
		log.Printf("External checker %s: Failed to get details: %v", e.serviceName, err)
		return true, "Service healthy but details unavailable"
	}

	responseTime := time.Since(start).Nanoseconds()

	var details map[string]interface{}
	if err := json.Unmarshal([]byte(status.Message), &details); err != nil {
		return true, fmt.Sprintf(`{"response_time": %d, "error": "invalid details format"}`, responseTime)
	}

	return true, status.Message
}

func (e *ExternalChecker) Close() error {
	if e.client != nil {
		return e.client.Close()
	}
	return nil
}
