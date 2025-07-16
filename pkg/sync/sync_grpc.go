package sync

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
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

// SweepCompletionTracker tracks sweep completion status for a source.
type SweepCompletionTracker struct {
	TargetSequence   string                                  // Sequence ID of current targets
	ExpectedAgents   map[string]bool                         // Agents that should report completion
	CompletedAgents  map[string]*proto.SweepCompletionStatus // Agents that have completed
	StartTime        time.Time                               // When sweep targets were distributed
	LastUpdateTime   time.Time                               // Last time we received a completion update
	TotalTargets     int32                                   // Total number of targets distributed
	CompletionStatus proto.SweepCompletionStatus_Status      // Overall completion status
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

	// Sweep completion tracking
	completionTracker map[string]*SweepCompletionTracker // Track completion by source
	completionMu      sync.RWMutex

	logger logger.Logger
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

	// Process incoming completion status from poller
	if req.CompletionStatus != nil {
		s.processPollerCompletionStatus(req.PollerId, req.CompletionStatus)
	}

	// Create a stable sequence based on the sequences of all cached sources
	var currentSequence string

	var allResults []*models.SweepResult

	// Create a stable sequence based on the sequences of all cached sources.
	sourceSequences := make([]string, 0, len(s.resultsCache))

	for sourceName, cached := range s.resultsCache {
		if cached != nil && cached.Sequence != "" {
			// Combine source name with sequence to avoid collisions
			sourceSequences = append(sourceSequences, fmt.Sprintf("%s:%s", sourceName, cached.Sequence))
			allResults = append(allResults, cached.Results...)
		}
	}

	// Sort the sequences to ensure the final combined sequence is deterministic
	sort.Strings(sourceSequences)
	currentSequence = strings.Join(sourceSequences, ";")

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

	// Get sweep completion status for this request
	sweepCompletion := s.getSweepCompletionStatus(req.ServiceName, req.PollerId)

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
		SweepCompletion: sweepCompletion,
	}, nil
}

// getSweepCompletionStatus returns the current sweep completion status for a specific agent and source.
func (s *PollerService) getSweepCompletionStatus(serviceName, agentID string) *proto.SweepCompletionStatus {
	s.completionMu.RLock()
	defer s.completionMu.RUnlock()

	// For sync service, serviceName typically represents the source
	// In a more complex setup, you might need different mapping logic
	sourceName := serviceName

	tracker, exists := s.completionTracker[sourceName]
	if !exists {
		// No tracking data available
		return &proto.SweepCompletionStatus{
			Status: proto.SweepCompletionStatus_UNKNOWN,
		}
	}

	// If this agent isn't being tracked yet, add it to expected agents
	if _, exists := tracker.ExpectedAgents[agentID]; !exists {
		// Dynamically add agent to tracking
		s.completionMu.RUnlock()
		s.completionMu.Lock()

		// Re-check after lock upgrade
		if updatedTracker, exists := s.completionTracker[sourceName]; exists {
			updatedTracker.ExpectedAgents[agentID] = true

			s.logger.Debug().
				Str("source", sourceName).
				Str("agent_id", agentID).
				Msg("Added agent to completion tracking")
		}

		s.completionMu.Unlock()
		s.completionMu.RLock()
	}

	// Return current completion status for this agent
	if agentStatus, exists := tracker.CompletedAgents[agentID]; exists {
		return agentStatus
	}

	// Agent hasn't completed yet, return in-progress status
	return &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_NOT_STARTED,
		TargetSequence:   tracker.TargetSequence,
		TotalTargets:     tracker.TotalTargets,
		CompletedTargets: 0,
	}
}

// processPollerCompletionStatus handles completion status updates from pollers.
func (s *PollerService) processPollerCompletionStatus(pollerID string, status *proto.SweepCompletionStatus) {
	if status == nil {
		return
	}

	s.completionMu.Lock()
	defer s.completionMu.Unlock()

	s.logger.Debug().
		Str("poller_id", pollerID).
		Str("status", status.Status.String()).
		Str("target_sequence", status.TargetSequence).
		Int32("completed_targets", status.CompletedTargets).
		Int32("total_targets", status.TotalTargets).
		Msg("Received completion status from poller")

	// Find the appropriate source tracker based on target sequence
	// In a more sophisticated setup, you might need to map poller ID to source
	for sourceName, tracker := range s.completionTracker {
		if tracker.TargetSequence != status.TargetSequence {
			continue
		}
		// Update the tracker with aggregated completion from this poller
		tracker.CompletedAgents[pollerID] = status
		tracker.LastUpdateTime = time.Now()

		// Check if all expected agents (pollers) have completed
		allCompleted := true

		var totalCompleted int32

		var totalTargets int32

		for _, agentStatus := range tracker.CompletedAgents {
			if agentStatus.Status != proto.SweepCompletionStatus_COMPLETED {
				allCompleted = false
			}

			totalCompleted += agentStatus.CompletedTargets
			totalTargets += agentStatus.TotalTargets
		}

		// Update overall completion status
		if allCompleted && len(tracker.CompletedAgents) > 0 {
			tracker.CompletionStatus = proto.SweepCompletionStatus_COMPLETED
		} else if totalCompleted > 0 {
			tracker.CompletionStatus = proto.SweepCompletionStatus_IN_PROGRESS
		}

		s.logger.Info().
			Str("source", sourceName).
			Str("poller_id", pollerID).
			Str("overall_status", tracker.CompletionStatus.String()).
			Bool("all_completed", allCompleted).
			Int32("total_completed", totalCompleted).
			Int32("total_targets", totalTargets).
			Int("completed_pollers", len(tracker.CompletedAgents)).
			Msg("Updated sweep completion tracking")

		break
	}
}
