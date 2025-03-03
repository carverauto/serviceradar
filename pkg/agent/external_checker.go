/*-
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

// Package agent pkg/agent/external_checker.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	grpcpkg "github.com/carverauto/serviceradar/pkg/grpc"
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

// ExternalChecker implements checker.Checker for external checker processes.
type ExternalChecker struct {
	serviceName string // Name of the service (e.g., "dusk")
	serviceType string // Type of service (e.g., "grpc")
	address     string
	client      *grpcpkg.ClientConn
}

// NewExternalChecker creates a new checker that connects to an external process.
func NewExternalChecker(ctx context.Context, serviceName, serviceType, address string) (*ExternalChecker, error) {
	log.Printf("Creating new external checker name=%s type=%s at %s", serviceName, serviceType, address)

	// Create connection config
	connConfig := &grpcpkg.ConnectionConfig{
		Address: address,
		Security: models.SecurityConfig{
			Mode:       "mtls",
			CertDir:    "/etc/serviceradar/certs",      // TODO: Make configurable
			ServerName: strings.Split(address, ":")[0], // Use hostname part
			Role:       "agent",
		},
	}

	// Create client using our gRPC package
	client, err := grpcpkg.NewClient(
		ctx,
		connConfig,
		grpcpkg.WithMaxRetries(maxRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create gRPC client: %w", err)
	}

	checker := &ExternalChecker{
		serviceName: serviceName,
		serviceType: serviceType,
		address:     address,
		client:      client,
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
	// First check basic health
	healthy, err := e.client.CheckHealth(ctx, "")
	if err != nil {
		log.Printf("External checker %s: Health check failed: %v", e.serviceName, err)
		return false, fmt.Sprintf("Health check failed: %v", err)
	}

	if !healthy {
		log.Printf("External checker %s: Service reported unhealthy", e.serviceName)
		return false, "Service reported unhealthy"
	}

	// Then get block details through AgentService
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

	// Parse status.Message into response structure
	var details map[string]interface{}
	if err := json.Unmarshal([]byte(status.Message), &details); err != nil {
		return true, fmt.Sprintf(`{"response_time": %d, "error": "invalid details format"}`, responseTime)
	}

	// Pass the details directly in the status message
	return true, status.Message
}

// Close cleans up the checker's resources.
func (e *ExternalChecker) Close() error {
	if e.client != nil {
		return e.client.Close()
	}

	return nil
}
