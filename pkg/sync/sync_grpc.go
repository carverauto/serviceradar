package sync

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
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
	logger                                zerolog.Logger
}

// GetStatus implements the AgentService GetStatus method.
// It returns minimal health check data for the sync service,
// avoiding the overhead of marshaling all cached devices.
func (s *PollerService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.resultsMu.RLock()
	defer s.resultsMu.RUnlock()

	// The poller passes service_name, etc. We can log it for debugging.
	s.logger.Debug().Str("service_name", req.ServiceName).Str("service_type", req.ServiceType).Msg("GetStatus called by poller")

	// Return minimal health check data instead of full device list
	healthData := map[string]interface{}{
		"status":         "healthy",
		"cached_devices": len(s.resultsCache),
		"timestamp":      time.Now().Unix(),
	}

	healthJSON, err := json.Marshal(healthData)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error marshaling health data")
		return nil, status.Errorf(codes.Internal, "failed to marshal health data: %v", err)
	}

	s.logger.Debug().Int("cached_devices", len(s.resultsCache)).Msg("Returning health check")

	return &proto.StatusResponse{
		Available: true,
		AgentId:   s.config.AgentID,
		Message:   healthJSON,
	}, nil
}

// GetResults implements the AgentService GetResults method.
// It returns the cached list of discovered devices as a JSON payload,
// specifically for discovery/synchronization data collection.
func (s *PollerService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.resultsMu.RLock()
	defer s.resultsMu.RUnlock()

	// The poller passes service_name, etc. We can log it for debugging.
	s.logger.Debug().Str("service_name", req.ServiceName).Str("service_type", req.ServiceType).Msg("GetResults called by poller")

	resultsJSON, err := json.Marshal(s.resultsCache)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error marshaling sweep results")
		return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
	}

	s.logger.Debug().Int("cached_devices", len(s.resultsCache)).Msg("Returning cached devices to poller")

	return &proto.ResultsResponse{
		Available:   true,
		Data:        resultsJSON,
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
		AgentId:     s.config.AgentID,
		PollerId:    req.PollerId,
		Timestamp:   time.Now().Unix(),
	}, nil
}
