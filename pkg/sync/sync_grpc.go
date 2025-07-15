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
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// CachedResults holds sweep results with sequence tracking
type CachedResults struct {
	Results   []*models.SweepResult
	Sequence  string
	Timestamp time.Time
}

// PollerService manages synchronization and serves results via a standard agent gRPC interface.
type PollerService struct {
	proto.UnimplementedAgentServiceServer // Implements the AgentService interface
	pollers                               map[string]*poller.Poller
	config                                Config
	kvClient                              KVClient
	sources                               map[string]Integration
	registry                              map[string]IntegrationFactory
	grpcClient                            GRPCClient
	grpcServer                            *grpc.Server
	resultsCache                          map[string]*CachedResults
	resultsMu                             sync.RWMutex
	logger                                logger.Logger
}

// GetStatus implements the AgentService GetStatus method.
// It returns minimal health check data for the sync service,
// avoiding the overhead of marshaling all cached devices.
func (s *PollerService) GetStatus(_ context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	s.resultsMu.RLock()
	defer s.resultsMu.RUnlock()

	// The poller passes service_name, etc. We can log it for debugging.
	s.logger.Debug().Str("service_name", req.ServiceName).Str("service_type", req.ServiceType).Msg("GetStatus called by poller")

	var deviceCount int
	for _, cached := range s.resultsCache {
		if cached != nil {
			deviceCount += len(cached.Results)
		}
	}

	// Return minimal health check data instead of full device list
	healthData := map[string]interface{}{
		"status":         "healthy",
		"cached_sources": len(s.resultsCache),
		"cached_devices": deviceCount,
		"timestamp":      time.Now().Unix(),
	}

	healthJSON, err := json.Marshal(healthData)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error marshaling health data")
		return nil, status.Errorf(codes.Internal, "failed to marshal health data: %v", err)
	}

	s.logger.Debug().Int("cached_devices", deviceCount).Msg("Returning health check")

	return &proto.StatusResponse{
		Available: true,
		AgentId:   s.config.AgentID,
		Message:   healthJSON,
	}, nil
}

// GetResults implements the AgentService GetResults method.
// It returns sweep results only if they haven't been delivered to this poller yet.
func (s *PollerService) GetResults(_ context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	s.resultsMu.RLock()
	defer s.resultsMu.RUnlock()

	s.logger.Debug().
		Str("service_name", req.ServiceName).
		Str("service_type", req.ServiceType).
		Str("last_sequence", req.LastSequence).
		Msg("GetResults called by poller")

	// Generate current sequence from latest cache data
	var currentSequence string
	var allResults []*models.SweepResult
	var latestTimestamp time.Time

	for _, cached := range s.resultsCache {
		if cached != nil {
			allResults = append(allResults, cached.Results...)
			if cached.Timestamp.After(latestTimestamp) {
				latestTimestamp = cached.Timestamp
				currentSequence = cached.Sequence
			}
		}
	}

	// If no data in cache, return empty with sequence "0"
	if len(allResults) == 0 {
		currentSequence = "0"
	}

	// Check if poller already has this data
	hasNewData := req.LastSequence != currentSequence

	var resultsJSON []byte
	var err error

	if hasNewData && len(allResults) > 0 {
		resultsJSON, err = json.Marshal(allResults)
		if err != nil {
			s.logger.Error().Err(err).Msg("Error marshaling sweep results")
			return nil, status.Errorf(codes.Internal, "failed to marshal results: %v", err)
		}
	} else {
		// Return empty data if no new results
		resultsJSON = []byte("[]")
	}

	s.logger.Info().
		Int("sweep_results_returned", len(allResults)).
		Str("current_sequence", currentSequence).
		Str("last_sequence", req.LastSequence).
		Bool("has_new_data", hasNewData).
		Msg("Returned sweep results to poller")

	return &proto.ResultsResponse{
		Available:       true,
		Data:            resultsJSON,
		ServiceName:     req.ServiceName,
		ServiceType:     req.ServiceType,
		AgentId:         s.config.AgentID,
		PollerId:        req.PollerId,
		Timestamp:       time.Now().Unix(),
		CurrentSequence: currentSequence,
		HasNewData:      hasNewData,
	}, nil
}
