package cloud

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/proto"
)

type AlertFunc func(pollerID string, duration time.Duration)

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	lastSeen       map[string]time.Time
	alertThreshold time.Duration
	alertFunc      AlertFunc
	apiServer      *api.APIServer
}

func (s *Server) SetAPIServer(api *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.apiServer = api
}

func NewServer(alertThreshold time.Duration, alertFunc AlertFunc) *Server {
	return &Server{
		lastSeen:       make(map[string]time.Time),
		alertThreshold: alertThreshold,
		alertFunc:      alertFunc,
	}
}

// pkg/cloud/server.go

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.mu.Lock()
	s.lastSeen[req.PollerId] = time.Unix(req.Timestamp, 0)
	s.mu.Unlock()

	// Create node status for API
	status := &api.NodeStatus{
		NodeID:     req.PollerId,
		IsHealthy:  true, // We'll determine this based on services
		LastUpdate: time.Unix(req.Timestamp, 0),
		Services:   make([]api.ServiceStatus, 0, len(req.Services)),
	}

	// Process each service
	for _, svc := range req.Services {
		serviceStatus := api.ServiceStatus{
			Name:      svc.ServiceName,
			Available: svc.Available,
			Message:   svc.Message,
			Type:      svc.Type,
		}

		// Determine service type and details
		// In ReportStatus method in pkg/cloud/server.go:

		if svc.ServiceName == "dusk" {
			serviceStatus.Type = "blockchain"

			// Try to parse the message as JSON first
			var blockDetails interface{}
			if err := json.Unmarshal([]byte(svc.Message), &blockDetails); err == nil {
				// If it's valid JSON, use it directly
				if jsonBytes, err := json.Marshal(blockDetails); err == nil {
					serviceStatus.Details = jsonBytes
				}
			} else {
				// Create a basic status if parsing failed
				basicStatus := map[string]interface{}{
					"status": svc.Message,
				}
				if jsonBytes, err := json.Marshal(basicStatus); err == nil {
					serviceStatus.Details = jsonBytes
				}
			}

			// Log the details for debugging
			log.Printf("Processed Dusk service details: %+v", string(serviceStatus.Details))
		}

		status.Services = append(status.Services, serviceStatus)

		// Update overall health status
		if !svc.Available {
			status.IsHealthy = false
		}
	}

	// If we have an API server, update it
	if s.apiServer != nil {
		s.apiServer.UpdateNodeStatus(req.PollerId, status)
	}

	// Log service issues
	for _, status := range req.Services {
		if !status.Available {
			log.Printf("Alert: Service %s is down: %s", status.ServiceName, status.Message)
		}
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.checkPollers()
		}
	}
}

func (s *Server) checkPollers() {
	now := time.Now()
	s.mu.RLock()
	defer s.mu.RUnlock()

	for pollerID, lastSeen := range s.lastSeen {
		if duration := now.Sub(lastSeen); duration > s.alertThreshold {
			if s.alertFunc != nil {
				s.alertFunc(pollerID, duration)
			}
		}
	}
}
