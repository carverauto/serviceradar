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
		// Check if the engine is operational by verifying active workers or job channel status
		select {
		case job, ok := <-s.engine.jobChan:
			if ok {
				// Put the job back to avoid consuming it
				select {
				case s.engine.jobChan <- job:
				default:
					log.Printf("Failed to restore job to channel")
				}

				isAvailable = true

				message["status"] = "operational"
				message["message"] = "serviceradar-mapper is operational"
			}
		default:
			// Check if there are active jobs
			s.engine.mu.RLock()
			hasActiveJobs := len(s.engine.activeJobs) > 0
			s.engine.mu.RUnlock()

			if hasActiveJobs {
				isAvailable = true

				message["status"] = "operational"
				message["message"] = "serviceradar-mapper is operational with active jobs"
			}
		}
	}

	// Marshal message to JSON bytes
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
