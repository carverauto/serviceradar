package snmp

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

type Poller struct {
	Config Config
	mu     sync.RWMutex
}

type PollerService struct {
	proto.UnimplementedPollerServiceServer
	checker *Poller
}

func NewSNMPPollerService(checker *Poller) *PollerService {
	return &PollerService{checker: checker}
}

type HealthServer struct {
	grpc_health_v1.UnimplementedHealthServer
	checker *Poller
}

// GetStatus implements the AgentService GetStatus method.
func (s *PollerService) GetStatus(ctx context.Context, _ *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	// Cast config.Duration -> time.Duration
	timeout := time.Duration(s.checker.Config.Timeout)

	_, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	log.Printf("SNMP GetStatus called")

	return &proto.StatusResponse{
		Available: true,
		Message:   "Unimplemented",
	}, nil
}

// Check implements the HealthServer Check method.
func (s *HealthServer) Check(ctx context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	log.Printf("SNMP HealthServer Check called")

	// TODO: implement this by calling SNMPGet methods and stuffing
	// data into metadata and returning it through the gRPC response

	return &grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	}, nil
}

// Watch implements the HealthServer Watch method.
func (s *HealthServer) Watch(_ *grpc_health_v1.HealthCheckRequest, _ grpc_health_v1.Health_WatchServer) error {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	log.Printf("SNMP HealthServer Watch called")

	return status.Error(codes.Unimplemented, "Watch is not implemented")
}

// GetStatusData implements the AgentService GetStatusData method.
func (s *Poller) GetStatusData() json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// TODO: implement this
	return nil
}
