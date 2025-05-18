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
	"log"

	monitoringpb "github.com/carverauto/serviceradar/proto"
)

// MapperAgentService implements the monitoring.AgentServiceServer for the mapper's own health.
type MapperAgentService struct {
	monitoringpb.UnimplementedAgentServiceServer
	engine *SNMPDiscoveryEngine
}

// NewMapperAgentService creates a new MapperAgentService.
func NewMapperAgentService(engine *SNMPDiscoveryEngine) *MapperAgentService {
	return &MapperAgentService{
		engine: engine,
	}
}

// GetStatus implements the monitoring.AgentServiceServer interface.
func (s *MapperAgentService) GetStatus(_ context.Context, req *monitoringpb.StatusRequest) (*monitoringpb.StatusResponse, error) {
	log.Printf("Mapper's monitoring.AgentService/GetStatus called with request: %+v", req)

	var isAvailable bool

	var message string

	if s.engine != nil {
		// A simple check: if the engine's 'done' channel is closed, it's stopping or stopped.
		// This is a simplistic check. A more robust health check might involve
		// checking active workers, error rates, etc.
		select {
		case <-s.engine.done:
			isAvailable = false
			message = "serviceradar-mapper is stopping or stopped"
		default:
			isAvailable = true
			message = "serviceradar-mapper is operational"
		}
	} else {
		isAvailable = false
		message = "serviceradar-mapper engine not initialized"
	}

	serviceName := "serviceradar-mapper"

	return &monitoringpb.StatusResponse{
		Available:   isAvailable,
		Message:     message,
		ServiceName: serviceName,
		ServiceType: "service-instance",            // Type of entity being reported on
		AgentId:     "serviceradar-mapper-monitor", // ID for the mapper itself acting for its status
	}, nil
}
