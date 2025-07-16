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

func TestInitializeCompletionTracking(t *testing.T) {
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
				AgentID:     "test-agent",
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
	now := time.Now()
	sequence := "test-sequence-123"
	totalTargets := int32(10)

	syncer.initializeCompletionTracking("armis", sequence, totalTargets, now)

	// Verify tracking was set up correctly
	syncer.completionMu.RLock()
	tracker, exists := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.True(t, exists, "Completion tracker should be initialized")
	assert.Equal(t, sequence, tracker.TargetSequence)
	assert.Equal(t, totalTargets, tracker.TotalTargets)
	assert.Equal(t, proto.SweepCompletionStatus_NOT_STARTED, tracker.CompletionStatus)
	assert.True(t, tracker.ExpectedAgents["test-agent"], "Should expect configured agent")
	assert.Empty(t, tracker.CompletedAgents, "Should start with no completed agents")
}

func TestProcessPollerCompletionStatus(t *testing.T) {
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

	// Set up initial completion tracking
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Simulate completion status from poller
	completionStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   sequence,
		TotalTargets:     10,
		CompletedTargets: 5,
		CompletionTime:   0,
	}

	// Process the completion status
	syncer.processPollerCompletionStatus("test-poller", completionStatus)

	// Verify the status was recorded
	syncer.completionMu.RLock()
	tracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.NotNil(t, tracker)
	assert.Contains(t, tracker.CompletedAgents, "test-poller")
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, tracker.CompletionStatus)

	storedStatus := tracker.CompletedAgents["test-poller"]
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, storedStatus.Status)
	assert.Equal(t, int32(5), storedStatus.CompletedTargets)
	assert.Equal(t, int32(10), storedStatus.TotalTargets)
}

func TestProcessPollerCompletionStatus_AllCompleted(t *testing.T) {
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

	// Set up initial completion tracking
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Simulate completion status showing all targets completed
	completionStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		TargetSequence:   sequence,
		TotalTargets:     10,
		CompletedTargets: 10,
		CompletionTime:   time.Now().Unix(),
	}

	// Process the completion status
	syncer.processPollerCompletionStatus("test-poller", completionStatus)

	// Verify the overall status is now COMPLETED
	syncer.completionMu.RLock()
	tracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.NotNil(t, tracker)
	assert.Equal(t, proto.SweepCompletionStatus_COMPLETED, tracker.CompletionStatus)
}

func TestIsSweepComplete_NotStarted(t *testing.T) {
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

	// No completion tracking initialized - should return false
	isComplete := syncer.isSweepComplete("armis")
	assert.False(t, isComplete, "Should return false when no completion tracking exists")
}

func TestIsSweepComplete_Completed(t *testing.T) {
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

	// Set up completion tracking with COMPLETED status
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Manually set completion status
	syncer.completionMu.Lock()
	syncer.completionTracker["armis"].CompletionStatus = proto.SweepCompletionStatus_COMPLETED
	syncer.completionTracker["armis"].CompletedAgents["test-agent"] = &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		CompletedTargets: 10,
		TotalTargets:     10,
	}
	syncer.completionMu.Unlock()

	isComplete := syncer.isSweepComplete("armis")
	assert.True(t, isComplete, "Should return true when sweep is completed")
}

func TestIsSweepComplete_StaleData(t *testing.T) {
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

	// Set up completion tracking with old timestamp
	sequence := "test-sequence-123"
	staleTime := time.Now().Add(-15 * time.Minute) // 15 minutes ago
	syncer.initializeCompletionTracking("armis", sequence, 10, staleTime)

	// Set completion status but with stale timestamp
	syncer.completionMu.Lock()
	syncer.completionTracker["armis"].CompletionStatus = proto.SweepCompletionStatus_COMPLETED
	syncer.completionTracker["armis"].LastUpdateTime = staleTime
	syncer.completionTracker["armis"].CompletedAgents["test-agent"] = &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		CompletedTargets: 10,
		TotalTargets:     10,
	}
	syncer.completionMu.Unlock()

	isComplete := syncer.isSweepComplete("armis")
	assert.False(t, isComplete, "Should return false when completion data is stale")
}

func TestShouldForceReconciliation_Timeout(t *testing.T) {
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

	// Set up completion tracking with very old start time (exceeding 30 minute timeout)
	sequence := "test-sequence-123"
	oldTime := time.Now().Add(-35 * time.Minute) // 35 minutes ago
	syncer.initializeCompletionTracking("armis", sequence, 10, oldTime)

	shouldForce := syncer.shouldForceReconciliation("armis")
	assert.True(t, shouldForce, "Should force reconciliation when sweep timeout exceeded")
}

func TestShouldForceReconciliation_StaleUpdates(t *testing.T) {
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

	// Set up completion tracking with some progress but stale updates
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Add some completed agents but with stale last update time
	syncer.completionMu.Lock()
	syncer.completionTracker["armis"].LastUpdateTime = time.Now().Add(-20 * time.Minute) // 20 minutes ago
	syncer.completionTracker["armis"].CompletedAgents["test-agent"] = &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		CompletedTargets: 5,
		TotalTargets:     10,
	}
	syncer.completionMu.Unlock()

	shouldForce := syncer.shouldForceReconciliation("armis")
	assert.True(t, shouldForce, "Should force reconciliation when updates are stale but progress exists")
}

func TestSyncSourceSweep_CompletionGating(t *testing.T) {
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
				SweepInterval: "10m", // Sweep configured
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

	// Set up completion tracking but not completed yet
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// syncSourceSweep should skip reconciliation when sweep is not complete
	// No mock expectations for Reconcile because it shouldn't be called
	err = syncer.syncSourceSweep(context.Background(), "armis")
	assert.NoError(t, err, "Should not error when skipping reconciliation")
}

func TestSyncSourceSweep_ReconciliationWhenComplete(t *testing.T) {
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
				SweepInterval: "10m", // Sweep configured
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

	// Set up completion tracking as completed
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	syncer.completionMu.Lock()
	syncer.completionTracker["armis"].CompletionStatus = proto.SweepCompletionStatus_COMPLETED
	syncer.completionTracker["armis"].CompletedAgents["test-agent"] = &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_COMPLETED,
		CompletedTargets: 10,
		TotalTargets:     10,
	}
	syncer.completionMu.Unlock()

	// Expect Reconcile to be called since sweep is complete
	mockInteg.EXPECT().Reconcile(gomock.Any()).Return(nil)

	err = syncer.syncSourceSweep(context.Background(), "armis")
	assert.NoError(t, err, "Should succeed when performing reconciliation")
}

func TestSyncSourceSweep_NoSweepConfigured(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)
	mockClock := poller.NewMockClock(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "https://netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "token"},
				// No SweepInterval configured
			},
		},
		KVAddress:    "localhost:50051",
		ListenAddr:   ":50053",
		PollInterval: models.Duration(1 * time.Second),
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	syncer, err := New(context.Background(), c, mockKV, registry, nil, mockClock, testLogger())
	require.NoError(t, err)

	// Expect Reconcile to be called immediately since no sweep is configured
	mockInteg.EXPECT().Reconcile(gomock.Any()).Return(nil)

	err = syncer.syncSourceSweep(context.Background(), "netbox")
	assert.NoError(t, err, "Should proceed with reconciliation when no sweep configured")
}

func TestGetResults_ProcessesCompletionStatus(t *testing.T) {
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

	// Set up initial completion tracking
	sequence := "test-sequence-123"
	syncer.initializeCompletionTracking("armis", sequence, 10, time.Now())

	// Create a request with completion status
	completionStatus := &proto.SweepCompletionStatus{
		Status:           proto.SweepCompletionStatus_IN_PROGRESS,
		TargetSequence:   sequence,
		TotalTargets:     10,
		CompletedTargets: 7,
	}

	req := &proto.ResultsRequest{
		ServiceName:      "sync",
		ServiceType:      "grpc",
		AgentId:          "test-poller",
		PollerId:         "test-poller",
		LastSequence:     "",
		CompletionStatus: completionStatus,
	}

	// Call GetResults - this should process the completion status
	resp, err := syncer.GetResults(context.Background(), req)
	require.NoError(t, err)
	assert.NotNil(t, resp)

	// Verify the completion status was processed
	syncer.completionMu.RLock()
	tracker := syncer.completionTracker["armis"]
	syncer.completionMu.RUnlock()

	require.NotNil(t, tracker)
	assert.Contains(t, tracker.CompletedAgents, "test-poller")

	storedStatus := tracker.CompletedAgents["test-poller"]
	assert.Equal(t, proto.SweepCompletionStatus_IN_PROGRESS, storedStatus.Status)
	assert.Equal(t, int32(7), storedStatus.CompletedTargets)
	assert.Equal(t, int32(10), storedStatus.TotalTargets)
}
