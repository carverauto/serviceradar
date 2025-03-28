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
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/proto"
)

const (
	maxRetries                 = 3
	initialHealthCheckInterval = 10 * time.Second
	maxHealthCheckInterval     = 5 * time.Minute
	backoffFactor              = 2.0
)

var (
	errHealth        = fmt.Errorf("service is not healthy")
	errServiceHealth = fmt.Errorf("service is not healthy")
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

// NewExternalChecker creates a new checker that connects to an external process using a shared gRPC client.
func NewExternalChecker(ctx context.Context, serviceName, details string) (checker.Checker, error) {
	s, ok := ctx.Value("server").(*Server)
	if !ok {
		return nil, fmt.Errorf("server context not provided for external checker")
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	address := details // Use details as the address (e.g., "192.168.2.23:50052")
	if address == "" {
		return nil, fmt.Errorf("no address provided for external checker %s", serviceName)
	}

	conn, exists := s.connections[address]
	if !exists {
		return nil, fmt.Errorf("no gRPC connection available for external checker at %s", address)
	}

	log.Printf("Creating new external checker name=%s type=grpc at %s using shared client", serviceName, address)

	checker := &ExternalChecker{
		serviceName:         serviceName,
		serviceType:         "grpc", // Hardcoded since this is the gRPC checker
		address:             address,
		client:              conn.client,
		healthCheckInterval: initialHealthCheckInterval,
		lastHealthCheck:     time.Time{},
	}

	// Initial health check
	healthy, err := checker.client.CheckHealth(ctx, "")
	if err != nil || !healthy {
		if err != nil {
			return nil, fmt.Errorf("extChecker: %w, err: %v", errHealth, err)
		}
		return nil, errServiceHealth
	}

	log.Printf("Successfully created external checker name=%s type=grpc", serviceName)
	return checker, nil
}

func (e *ExternalChecker) Check(ctx context.Context) (bool, string) {
	if e.canUseCachedStatus() {
		return e.handleCachedStatus()
	}

	healthy, err := e.performHealthCheck(ctx)
	if !healthy || err != nil {
		return e.handleHealthCheckFailure(err)
	}

	return e.getServiceDetails(ctx)
}

func (e *ExternalChecker) canUseCachedStatus() bool {
	e.healthCheckMu.Lock()
	defer e.healthCheckMu.Unlock()

	now := time.Now()
	return !e.lastHealthCheck.IsZero() && now.Sub(e.lastHealthCheck) < e.healthCheckInterval
}

func (e *ExternalChecker) handleCachedStatus() (bool, string) {
	e.healthCheckMu.Lock()
	defer e.healthCheckMu.Unlock()

	if !e.healthStatus {
		return false, "Service unhealthy (cached status)"
	}
	return true, "" // Proceed to get details
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

	e.healthCheckInterval = time.Duration(float64(e.healthCheckInterval) * backoffFactor)
	if e.healthCheckInterval > maxHealthCheckInterval {
		e.healthCheckInterval = maxHealthCheckInterval
	}

	return healthy, err
}

func (e *ExternalChecker) handleHealthCheckFailure(err error) (bool, string) {
	if err != nil {
		log.Printf("External checker %s: Health check failed: %v", e.serviceName, err)
		return false, fmt.Sprintf("Health check failed: %v", err)
	}

	log.Printf("External checker %s: Service reported unhealthy", e.serviceName)
	return false, "Service reported unhealthy"
}

func (e *ExternalChecker) getServiceDetails(ctx context.Context) (bool, string) {
	client := proto.NewAgentServiceClient(e.client.GetConnection())
	start := time.Now()

	status, err := client.GetStatus(ctx, &proto.StatusRequest{
		ServiceName: e.serviceName,
		ServiceType: e.serviceType,
		Details:     e.address,
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
	// No need to close the client here since it’s shared and managed by Server
	return nil
}
