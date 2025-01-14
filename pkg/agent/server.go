package agent

import (
	"context"
	"fmt"
	"log"
	"sync"

	"github.com/mfreeman451/homemon/pkg/checker"
	"github.com/mfreeman451/homemon/proto"
)

type Server struct {
	proto.UnimplementedAgentServiceServer
	duskChecker checker.Checker
	mu          sync.RWMutex
}

func NewServer() *Server {
	return &Server{}
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Checking status of service: %s", req.ServiceName)

	var check checker.Checker
	switch req.ServiceName {
	case "process":
		check = &ProcessChecker{ProcessName: req.Details}

	case "port":
		check = &PortChecker{
			Host: "localhost",
			Port: int(req.Port),
		}

	case "dusk":
		s.mu.Lock()
		if s.duskChecker == nil {
			log.Printf("Creating new dusk checker")
			c, err := NewExternalChecker("dusk", "127.0.0.1:50052")
			if err != nil {
				s.mu.Unlock()
				return &proto.StatusResponse{
					Available: false,
					Message:   fmt.Sprintf("Failed to create dusk checker: %v", err),
				}, nil
			}
			s.duskChecker = c
		}
		check = s.duskChecker
		s.mu.Unlock()

	default:
		return &proto.StatusResponse{
			Available: false,
			Message:   fmt.Sprintf("Unknown service type: %s", req.ServiceName),
		}, nil
	}

	available, msg := check.Check(ctx)

	// If the checker provides additional status data, include it
	if provider, ok := check.(checker.StatusProvider); ok {
		if statusData := provider.GetStatusData(); statusData != nil {
			msg = string(statusData)
		}
	}

	return &proto.StatusResponse{
		Available: available,
		Message:   msg,
	}, nil
}

// Close handles cleanup when the server shuts down
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.duskChecker != nil {
		if closer, ok := s.duskChecker.(interface{ Close() error }); ok {
			return closer.Close()
		}
	}
	return nil
}
