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
	isAvailable := false

	message := map[string]interface{}{
		"status":  "unavailable",
		"message": "serviceradar-mapper is not operational",
	}

	if s.engine != nil {
		if s.engine.logger != nil {
			s.engine.logger.Debug().Interface("request", req).Msg("Mapper's monitoring.AgentService/GetStatus called")
		}

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
		if s.engine != nil && s.engine.logger != nil {
			s.engine.logger.Error().Err(err).Msg("Failed to marshal status message")
		}

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

// GetConfig returns the mapper service configuration as JSON for admin/config ingestion.
func (s *AgentService) GetConfig(_ context.Context, req *proto.ConfigRequest) (*proto.ConfigResponse, error) {
    var cfgBytes []byte
    var err error
    if s.engine != nil && s.engine.config != nil {
        cfgBytes, err = json.Marshal(s.engine.config)
        if err != nil {
            return nil, err
        }
    } else {
        cfgBytes = []byte("{}")
    }

    return &proto.ConfigResponse{
        Config:      cfgBytes,
        ServiceName: req.ServiceName,
        ServiceType: req.ServiceType,
        AgentId:     req.AgentId,
        PollerId:    req.PollerId,
        KvStoreId:   "",
        Timestamp:   time.Now().Unix(),
    }, nil
}

// StreamConfig streams the mapper configuration (single chunk).
func (s *AgentService) StreamConfig(req *proto.ConfigRequest, stream proto.AgentService_StreamConfigServer) error {
    var cfgBytes []byte
    var err error
    if s.engine != nil && s.engine.config != nil {
        cfgBytes, err = json.Marshal(s.engine.config)
        if err != nil {
            return err
        }
    } else {
        cfgBytes = []byte("{}")
    }
    return stream.Send(&proto.ConfigChunk{
        Data:        cfgBytes,
        IsFinal:     true,
        ChunkIndex:  0,
        TotalChunks: 1,
        KvStoreId:   "",
        Timestamp:   time.Now().Unix(),
    })
}

// GetResults implements the AgentService GetResults method.
// Mapper service doesn't support GetResults, so return a "not supported" response.
func (s *AgentService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.engine.logger.Debug().Interface("request", req).Msg("Mapper's monitoring.AgentService/GetResults called")

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
