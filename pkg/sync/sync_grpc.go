package sync

import (
	"context"
	"encoding/json"
	"log"
	"sync"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// PollerService manages synchronization and serves results via a standard agent gRPC interface.
type PollerService struct {
	proto.UnimplementedAgentServiceServer // Implements the AgentService interface
	poller                                *poller.Poller
	config                                Config
	kvClient                              KVClient
	sources                               map[string]Integration
	registry                              map[string]IntegrationFactory
	grpcClient                            GRPCClient
	grpcServer                            *grpc.Server
	resultsCache                          []*models.SweepResult
	resultsMu                             sync.RWMutex
}

// GetStatus implements the AgentService GetStatus method.
// It returns the cached list of discovered devices as a JSON payload,
// allowing the poller to treat this service as a standard agent.
func (s *PollerService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.resultsMu.RLock()
	defer s.resultsMu.RUnlock()

	// The poller passes service_name, etc. We can log it for debugging.
	log.Printf("GetStatus called by poller for service '%s' (type: '%s')", req.ServiceName, req.ServiceType)

	resultsJSON, err := json.Marshal(s.resultsCache)
	if err != nil {
		log.Printf("Error marshaling sweep results: %v", err)
		return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
	}

	log.Printf("Returning %d cached devices to the poller.", len(s.resultsCache))

	return &proto.StatusResponse{
		Available: true,
		AgentId:   s.config.AgentID,
		Message:   resultsJSON,
	}, nil
}
