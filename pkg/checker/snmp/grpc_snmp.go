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

// Package snmp pkg/checker/snmp/snmp.go
package snmp

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

type Poller struct {
	Config SNMPConfig
	mu     sync.RWMutex
}

type PollerService struct {
	proto.UnimplementedAgentServiceServer
	checker *Poller
	service *SNMPService
	logger  logger.Logger
}

func NewSNMPPollerService(checker *Poller, service *SNMPService, log logger.Logger) *PollerService {
	return &PollerService{checker: checker, service: service, logger: log}
}

type HealthServer struct {
	grpc_health_v1.UnimplementedHealthServer
	checker *Poller
	logger  logger.Logger
}

// GetStatus implements the AgentService GetStatus method.
func (s *PollerService) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	// Cast config.Duration -> time.Duration
	timeout := time.Duration(s.checker.Config.Timeout)

	// Apply timeout to context
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	s.logger.Debug().Msg("SNMP GetStatus called")

	// Get status from the SNMP service
	statusMap, err := s.service.GetStatus(ctx)
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   jsonError(fmt.Sprintf("Failed to get status from SNMP service: %v", err)),
			AgentId:   req.AgentId,
		}, nil
	}

	// Marshal the status map to JSON
	statusJSON, err := json.Marshal(statusMap)
	if err != nil {
		return &proto.StatusResponse{
			Available: false,
			Message:   jsonError(fmt.Sprintf("Failed to marshal status to JSON: %v", err)),
			AgentId:   req.AgentId,
		}, nil
	}

	// Determine overall availability based on target statuses
	available := true

	for _, targetStatus := range statusMap {
		if !targetStatus.Available {
			available = false
			break
		}
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     statusJSON, // Use []byte directly
		ServiceName: "snmp",
		ServiceType: "snmp",
		AgentId:     req.AgentId,
	}, nil
}

// Check implements the HealthServer Check method.
func (s *HealthServer) Check(ctx context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	s.logger.Debug().Msg("SNMP HealthServer Check called")

	_, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()

	return &grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	}, nil
}

// Watch implements the HealthServer Watch method.
func (s *HealthServer) Watch(_ *grpc_health_v1.HealthCheckRequest, _ grpc_health_v1.Health_WatchServer) error {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	s.logger.Debug().Msg("SNMP HealthServer Watch called")

	return status.Error(codes.Unimplemented, "Watch is not implemented")
}
