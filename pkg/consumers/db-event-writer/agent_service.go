package dbeventwriter

import (
	"context"
	"encoding/json"
	"log"

	"github.com/carverauto/serviceradar/proto"
)

// AgentService implements monitoring.AgentService for the db-event-writer.
type AgentService struct {
	proto.UnimplementedAgentServiceServer
	svc *Service
}

// NewAgentService creates a new AgentService.
func NewAgentService(svc *Service) *AgentService {
	return &AgentService{svc: svc}
}

// GetStatus responds with the operational status of the service.
func (s *AgentService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("db-event-writer monitoring.AgentService/GetStatus called with request: %+v", req)

	available := s.svc != nil && s.svc.nc != nil && s.svc.db != nil

	msg := map[string]interface{}{
		"status":  "unavailable",
		"message": "db-event-writer is not operational",
	}

	if available {
		msg["status"] = "operational"
		msg["message"] = "db-event-writer is operational"
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal status message: %v", err)
		return nil, err
	}

	return &proto.StatusResponse{
		Available:   available,
		Message:     data,
		ServiceName: "db-event-writer",
		ServiceType: "service-instance",
		AgentId:     "db-event-writer-monitor",
	}, nil
}
