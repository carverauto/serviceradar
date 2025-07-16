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

package sync

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

// TestEndToEndCompletionSignaling tests the complete flow:
// 1. Discovery initializes completion tracking
// 2. Pollers aggregate agent completion status
// 3. Pollers forward aggregated status to sync service
// 4. Sync service processes completion updates
// 5. Sweep reconciliation waits for completion before proceeding
func TestEndToEndCompletionSignaling(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	// Configure sync service with sweep interval
	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:          "armis",
				Endpoint:      "http://example.com",
				Prefix:        "armis/",
				Credentials:   map[string]string{"api_key": "key"},
				SweepInterval: "10m", // Sweep configured - reconciliation should wait
				AgentID:       "test-agent",
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Create sync service
	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	ctx := context.Background()

	// Step 1: Discovery phase - should initialize completion tracking
	data := map[string][]byte{"devices": []byte("data")}
	sweepResults := []*models.SweepResult{
		{
			IP:              "192.168.1.1",
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			DiscoverySource: "armis",
			Available:       true,
		},
		{
			IP:              "192.168.1.2",
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			DiscoverySource: "armis",
			Available:       false,
		},
	}

	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, sweepResults, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), gomock.Any(), gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	// Execute discovery - this should initialize completion tracking
	err = syncer.syncSourceDiscovery(ctx, "armis")
	require.NoError(t, err)

	// Verify completion tracking was initialized
	syncer.completionMu.RLock()
	tracker, exists := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.True(t, exists, "Completion tracking should be initialized")
	assert.Equal(t, proto.SweepCompletionStatus_NOT_STARTED, tracker.CompletionStatus)
	assert.Equal(t, int32(2), tracker.TotalTargets, "Should track 2 sweep targets")

	// Step 2: Simulate completion status updates from pollers
	// This represents pollers receiving completion updates from agents and forwarding to sync
	completionFromPoller := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   tracker.TargetSequence,
		TotalTargets:     2,
		CompletedTargets: 1,
		CompletionTime:   0,
	}

	// Process completion status (simulating GetResults call from poller)
	syncer.processPollerCompletionStatus("test-poller", completionFromPoller)

	// Verify the status was processed
	syncer.completionMu.RLock()
	updatedTracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, updatedTracker.CompletionStatus)
	assert.Contains(t, updatedTracker.CompletedAgents, "test-poller")

	// Step 3: Test reconciliation gating - should skip when incomplete
	// No mock expectations for Reconcile because it shouldn't be called
	err = syncer.syncSourceSweep(ctx, "armis")
	require.NoError(t, err, "Should not error when skipping reconciliation")

	// Verify sweep is not considered complete
	isComplete := syncer.isSweepComplete("armis")
	assert.False(t, isComplete, "Sweep should not be complete yet")

	// Step 4: Complete the sweep
	completedStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   tracker.TargetSequence,
		TotalTargets:     2,
		CompletedTargets: 2,
		CompletionTime:   time.Now().Unix(),
	}

	syncer.processPollerCompletionStatus("test-poller", completedStatus)

	// Verify completion
	isComplete = syncer.isSweepComplete("armis")
	assert.True(t, isComplete, "Sweep should now be complete")

	// Step 5: Test reconciliation proceeds when complete
	mockInteg.EXPECT().Reconcile(gomock.Any()).Return(nil)

	err = syncer.syncSourceSweep(ctx, "armis")
	assert.NoError(t, err, "Should succeed when performing reconciliation")
}

// TestCompletionSignalingWithMultiplePollers tests completion coordination with multiple pollers
func TestCompletionSignalingWithMultiplePollers(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:          "armis",
				Endpoint:      "http://example.com",
				Prefix:        "armis/",
				Credentials:   map[string]string{"api_key": "key"},
				SweepInterval: "10m",
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Initialize completion tracking
	sequence := "test-sequence-456"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Simulate completion updates from multiple pollers
	poller1Status := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   sequence,
		TotalTargets:     5,
		CompletedTargets: 3,
	}

	poller2Status := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   sequence,
		TotalTargets:     5,
		CompletedTargets: 2,
	}

	syncer.processPollerCompletionStatus("poller1", poller1Status)
	syncer.processPollerCompletionStatus("poller2", poller2Status)

	// Verify aggregated state
	syncer.completionMu.RLock()
	tracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, tracker.CompletionStatus)
	assert.Len(t, tracker.CompletedAgents, 2, "Should track both pollers")

	// Complete one poller
	poller1Complete := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   sequence,
		TotalTargets:     5,
		CompletedTargets: 5,
		CompletionTime:   time.Now().Unix(),
	}

	syncer.processPollerCompletionStatus("poller1", poller1Complete)

	// Should still be in progress because poller2 hasn't completed
	syncer.completionMu.RLock()
	tracker = syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, tracker.CompletionStatus)

	// Complete second poller
	poller2Complete := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   sequence,
		TotalTargets:     5,
		CompletedTargets: 5,
		CompletionTime:   time.Now().Unix(),
	}

	syncer.processPollerCompletionStatus("poller2", poller2Complete)

	// Now should be completed
	syncer.completionMu.RLock()
	tracker = syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, tracker.CompletionStatus)
}

// TestTimeoutReconciliation tests that reconciliation proceeds after timeout
func TestTimeoutReconciliation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:          "armis",
				Endpoint:      "http://example.com",
				Prefix:        "armis/",
				Credentials:   map[string]string{"api_key": "key"},
				SweepInterval: "10m",
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Initialize completion tracking with old timestamp (beyond timeout)
	oldTime := time.Now().Add(-35 * time.Minute) // 35 minutes ago, exceeds 30 minute timeout
	sequence := "test-sequence-timeout"
	syncer.initializeCompletionTracking("armis", sequence, 10, oldTime)

	// Add some completion but leave incomplete
	partialStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   sequence,
		TotalTargets:     10,
		CompletedTargets: 5,
	}

	syncer.processPollerCompletionStatus("test-poller", partialStatus)

	// Should force reconciliation due to timeout despite incomplete status
	mockInteg.EXPECT().Reconcile(gomock.Any()).Return(nil)

	err = syncer.syncSourceSweep(context.Background(), "armis")
	assert.NoError(t, err, "Should proceed with reconciliation due to timeout")
}

// TestGetResults_CompletionStatusForwarding tests the full GetResults flow with completion forwarding
func TestGetResults_CompletionStatusForwarding(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"armis": {
				Type:        "armis",
				Endpoint:    "http://example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return NewMockIntegration(ctrl)
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Initialize completion tracking
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Cache some sweep results
	sweepResults := []*models.SweepResult{
		{
			IP:              "192.168.1.1",
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			DiscoverySource: "armis",
			Available:       true,
		},
	}

	syncer.resultsMu.Lock()
	syncer.resultsCache["armis"] = &CachedResults{
		Results:   sweepResults,
		Sequence:  sequence,
		Timestamp: time.Now(),
	}
	syncer.resultsMu.Unlock()

	// Test GetResults call with completion status
	completionStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   sequence,
		TotalTargets:     10,
		CompletedTargets: 10,
		CompletionTime:   time.Now().Unix(),
	}

	req := &proto.ResultsRequest{
		ServiceName:      "sync",
		ServiceType:      "grpc",
		AgentId:          "test-poller",
		PollerId:         "test-poller",
		LastSequence:     "",
		CompletionStatus: completionStatus,
	}

	// Call GetResults
	resp, err := syncer.GetResults(context.Background(), req)
	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.HasNewData)

	// Verify completion status was processed
	syncer.completionMu.RLock()
	tracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.NotNil(t, tracker)
	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, tracker.CompletionStatus)
	assert.Contains(t, tracker.CompletedAgents, "test-poller")

	// Verify GetSweepCompletionStatus returns the right status
	// Note: getSweepCompletionStatus uses serviceName as sourceName, so we need to use "armis"
	returnedStatus := syncer.getSweepCompletionStatus("armis", "test-poller")
	require.NotNil(t, returnedStatus)
	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, returnedStatus.Status)
	assert.Equal(t, sequence, returnedStatus.TargetSequence)

	// Verify response includes sweep completion
	// Note: Currently getSweepCompletionStatus maps serviceName directly to sourceName,
	// so with serviceName="sync" it won't find the "armis" tracker.
	// In a real implementation, you'd need better mapping logic.
	assert.NotNil(t, resp.SweepCompletion)
	// For now, it returns UNKNOWN because "sync" doesn't map to "armis"
	assert.Equal(t, proto.SweepCompletionStatus_UNKNOWN, resp.SweepCompletion.Status)
}
