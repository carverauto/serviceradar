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

package datasvc

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultHeartbeatInterval = 30 * time.Second
	registrationRetryDelay   = 10 * time.Second
)

// StartCoreRegistration starts the background goroutine that registers this datasvc
// instance with Core and sends periodic heartbeats.
func (s *Server) StartCoreRegistration(ctx context.Context, cfg *CoreRegistration, listenAddr string, security *models.SecurityConfig) {
	if cfg == nil || !cfg.Enabled {
		log.Printf("Core registration is disabled")
		return
	}

	if cfg.CoreEndpoint == "" {
		log.Printf("Core registration enabled but no core_endpoint configured, skipping")
		return
	}

	if cfg.InstanceID == "" {
		log.Printf("Core registration enabled but no instance_id configured, skipping")
		return
	}

	heartbeatInterval := defaultHeartbeatInterval
	if cfg.HeartbeatInterval > 0 {
		heartbeatInterval = time.Duration(cfg.HeartbeatInterval)
	}

	log.Printf("Starting Core registration: instance_id=%s, endpoint=%s, heartbeat=%s",
		cfg.InstanceID, listenAddr, heartbeatInterval)

	go s.runCoreRegistration(ctx, cfg, listenAddr, security, heartbeatInterval)
}

// runCoreRegistration runs the registration and heartbeat loop.
func (s *Server) runCoreRegistration(ctx context.Context, cfg *CoreRegistration, listenAddr string, security *models.SecurityConfig, heartbeatInterval time.Duration) {
	// Get SPIFFE ID from workload API if available
	spiffeID := s.getSPIFFEID(ctx)

	// Create gRPC connection to Core
	grpcClient, coreClient, err := s.connectToCore(ctx, cfg.CoreEndpoint, security)
	if err != nil {
		log.Printf("Failed to connect to Core at %s: %v (will retry)", cfg.CoreEndpoint, err)
		// Retry connection in background
		time.Sleep(registrationRetryDelay)
		go s.runCoreRegistration(ctx, cfg, listenAddr, security, heartbeatInterval)
		return
	}
	defer func() {
		if err := grpcClient.Close(); err != nil {
			log.Printf("Error closing Core gRPC client: %v", err)
		}
	}()

	// Initial registration
	if err := s.registerWithCore(ctx, coreClient, cfg.InstanceID, listenAddr, spiffeID); err != nil {
		log.Printf("Failed initial registration with Core: %v (will retry)", err)
		time.Sleep(registrationRetryDelay)
		go s.runCoreRegistration(ctx, cfg, listenAddr, security, heartbeatInterval)
		return
	}

	log.Printf("Successfully registered with Core: instance_id=%s", cfg.InstanceID)

	// Heartbeat loop
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("Core registration stopped: context cancelled")
			return
		case <-ticker.C:
			if err := s.registerWithCore(ctx, coreClient, cfg.InstanceID, listenAddr, spiffeID); err != nil {
				log.Printf("Heartbeat to Core failed: %v", err)
				// Don't exit, keep trying
			}
		}
	}
}

// connectToCore creates a gRPC connection to the Core service using the security configuration.
// Uses SPIFFE mTLS if configured, otherwise falls back based on security settings.
func (s *Server) connectToCore(ctx context.Context, endpoint string, security *models.SecurityConfig) (*grpc.Client, proto.PollerServiceClient, error) {
	log.Printf("Connecting to Core at %s for registration", endpoint)

	// Create security provider
	securityProvider, err := grpc.NewSecurityProvider(ctx, security, s.logger)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create security provider: %w", err)
	}

	// Create gRPC client with security
	clientCfg := grpc.ClientConfig{
		Address:          endpoint,
		SecurityProvider: securityProvider,
		MaxRetries:       3,
		Logger:           s.logger,
	}

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		// Close security provider if client creation fails
		if closeErr := securityProvider.Close(); closeErr != nil {
			log.Printf("Error closing security provider: %v", closeErr)
		}
		return nil, nil, fmt.Errorf("failed to create Core client: %w", err)
	}

	coreClient := proto.NewPollerServiceClient(client.GetConnection())

	return client, coreClient, nil
}

// registerWithCore sends a registration request to Core using the standard ReportStatus RPC.
// This reuses the existing service registration infrastructure.
func (s *Server) registerWithCore(ctx context.Context, client proto.PollerServiceClient, instanceID, endpoint, spiffeID string) error {
	// Get source IP from the endpoint
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		host = endpoint // Fallback if parsing fails
	}

	// Create service status for datasvc
	serviceStatus := &proto.ServiceStatus{
		ServiceName: instanceID,
		ServiceType: "datasvc",
		Available:   true,
		Message:     []byte(fmt.Sprintf(`{"endpoint":"%s","spiffe_id":"%s"}`, endpoint, spiffeID)),
		AgentId:     instanceID,
		PollerId:    instanceID, // DataSvc acts as its own "poller"
		KvStoreId:   endpoint,   // Store endpoint in kv_store_id for easy retrieval
	}

	req := &proto.PollerStatusRequest{
		Services:  []*proto.ServiceStatus{serviceStatus},
		PollerId:  instanceID,
		AgentId:   instanceID,
		Timestamp: time.Now().Unix(),
		Partition: "core", // DataSvc lives in core partition
		SourceIp:  host,
		KvStoreId: endpoint,
	}

	resp, err := client.ReportStatus(ctx, req)
	if err != nil {
		return fmt.Errorf("ReportStatus RPC failed: %w", err)
	}

	if !resp.Received {
		return fmt.Errorf("status not received by Core")
	}

	return nil
}

// getSPIFFEID attempts to get the SPIFFE ID from the workload API.
func (s *Server) getSPIFFEID(ctx context.Context) string {
	// Try to get SPIFFE ID from environment or workload API
	// For now, return empty - this can be enhanced later
	spiffeID := os.Getenv("SPIFFE_ID")
	if spiffeID != "" {
		return spiffeID
	}

	// TODO: Query SPIFFE workload API if socket is available
	return ""
}
