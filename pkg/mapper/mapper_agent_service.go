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

// Package mapper pkg/mapper/mapper_agent_service.go
package mapper

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

// AgentService implements the proto.AgentServiceServer for the mapper's own health.
type AgentService struct {
	proto.UnimplementedAgentServiceServer
	engine *DiscoveryEngine
}

// NewAgentService creates a new AgentService.
func NewAgentService(engine *DiscoveryEngine) *AgentService {
	return &AgentService{
		engine: engine,
	}
}

// GetStatus implements the monitoring.AgentServiceServer interface.
func (s *AgentService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Mapper's monitoring.AgentService/GetStatus called with request: %+v", req)

	isAvailable := false

	message := map[string]interface{}{
		"status":  "unavailable",
		"message": "serviceradar-mapper is not operational",
	}

	if s.engine != nil {
		// Check if engine is initialized and running
		s.engine.mu.RLock()
		isRunning := s.engine.done != nil && len(s.engine.schedulers) > 0 // Check for active schedulers
		s.engine.mu.RUnlock()

		if isRunning {
			isAvailable = true
			message["status"] = "operational"
			message["message"] = "serviceradar-mapper is operational"
		}
	}

	messageBytes, err := json.Marshal(message)
	if err != nil {
		log.Printf("Failed to marshal status message: %v", err)
		return nil, err
	}

	serviceName := "serviceradar-mapper"

	return &proto.StatusResponse{
		Available:   isAvailable,
		Message:     messageBytes,
		ServiceName: serviceName,
		ServiceType: "service-instance",
		AgentId:     "serviceradar-mapper-monitor",
	}, nil
}

// GetResults implements the AgentService GetResults method.
// Mapper service doesn't support GetResults, so return a "not supported" response.
func (s *AgentService) GetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	log.Printf("GetResults called for mapper service '%s' (type: '%s') - not supported", req.ServiceName, req.ServiceType)
	
	return &proto.ResultsResponse{
		Available:   false,
		Data:        []byte(`{"error": "GetResults not supported by mapper service"}`),
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     "serviceradar-mapper-monitor",
		PollerId:    req.PollerId,
		Timestamp:   time.Now().Unix(),
	}, nil
}
