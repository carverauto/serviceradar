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
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TestRunDiscoveryErrorAggregation validates that runDiscovery properly aggregates errors
func TestRunDiscoveryErrorAggregation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name          string
		setupMocks    func(*MockKVClient, *MockIntegration, *MockIntegration)
		expectedError string
		errorCount    int
	}{
		{
			name: "single source fetch error",
			setupMocks: func(kvClient *MockKVClient, int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Fetch(gomock.Any()).Return(nil, nil, errors.New("fetch failed"))
				int2.EXPECT().Fetch(gomock.Any()).Return(
					map[string][]byte{"key2": []byte("data2")},
					[]*models.DeviceUpdate{{IP: "192.168.1.2"}},
					nil,
				)
				kvClient.EXPECT().PutMany(gomock.Any(), gomock.Any()).Return(nil, nil)
			},
			expectedError: "discovery completed with 1 errors",
			errorCount:    1,
		},
		{
			name: "multiple source fetch errors",
			setupMocks: func(_ *MockKVClient, int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Fetch(gomock.Any()).Return(nil, nil, errors.New("fetch1 failed"))
				int2.EXPECT().Fetch(gomock.Any()).Return(nil, nil, errors.New("fetch2 failed"))
			},
			expectedError: "discovery completed with 2 errors",
			errorCount:    2,
		},
		{
			name: "fetch success but KV write error",
			setupMocks: func(kvClient *MockKVClient, int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Fetch(gomock.Any()).Return(
					map[string][]byte{"key1": []byte("data1")},
					[]*models.DeviceUpdate{{IP: "192.168.1.1"}},
					nil,
				)
				int2.EXPECT().Fetch(gomock.Any()).Return(
					map[string][]byte{"key2": []byte("data2")},
					[]*models.DeviceUpdate{{IP: "192.168.1.2"}},
					nil,
				)
				kvClient.EXPECT().PutMany(gomock.Any(), gomock.Any()).Return(nil, errors.New("kv write failed"))
				kvClient.EXPECT().PutMany(gomock.Any(), gomock.Any()).Return(nil, nil)
			},
			expectedError: "discovery completed with 1 errors",
			errorCount:    1,
		},
		{
			name: "no errors",
			setupMocks: func(kvClient *MockKVClient, int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Fetch(gomock.Any()).Return(
					map[string][]byte{"key1": []byte("data1")},
					[]*models.DeviceUpdate{{IP: "192.168.1.1"}},
					nil,
				)
				int2.EXPECT().Fetch(gomock.Any()).Return(
					map[string][]byte{"key2": []byte("data2")},
					[]*models.DeviceUpdate{{IP: "192.168.1.2"}},
					nil,
				)
				kvClient.EXPECT().PutMany(gomock.Any(), gomock.Any()).Return(nil, nil).Times(2)
			},
			expectedError: "",
			errorCount:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockKVClient := NewMockKVClient(ctrl)

			mockGRPCClient := NewMockGRPCClient(ctrl)
			mockGRPCClient.EXPECT().Close().Return(nil)

			mockInt1 := NewMockIntegration(ctrl)
			mockInt2 := NewMockIntegration(ctrl)

			s, err := NewSimpleSyncService(
				context.Background(),
				&Config{
					AgentID:           "test-agent",
					PollerID:          "test-poller",
					DiscoveryInterval: models.Duration(time.Minute),
					UpdateInterval:    models.Duration(time.Minute),
					ListenAddr:        ":50051",
					Sources: map[string]*models.SourceConfig{
						"source1": {
							Type:     "test1",
							Endpoint: "http://test1",
							AgentID:  "test-agent",
						},
						"source2": {
							Type:     "test2",
							Endpoint: "http://test2",
							AgentID:  "test-agent",
						},
					},
				},
				mockKVClient,
				map[string]IntegrationFactory{
					"test1": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
						return mockInt1
					},
					"test2": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
						return mockInt2
					},
				},
				mockGRPCClient,
				logger.NewTestLogger(),
			)
			require.NoError(t, err)

			defer s.Stop(context.Background())

			// Setup mocks
			tt.setupMocks(mockKVClient, mockInt1, mockInt2)

			// Run discovery
			err = s.runDiscovery(context.Background())

			if tt.errorCount > 0 {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tt.expectedError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

// TestRunArmisUpdatesErrorAggregation validates that runArmisUpdates properly aggregates errors
func TestRunArmisUpdatesErrorAggregation(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name          string
		setupMocks    func(*MockIntegration, *MockIntegration)
		expectedError string
		errorCount    int
	}{
		{
			name: "single reconcile error",
			setupMocks: func(int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Reconcile(gomock.Any()).Return(errors.New("reconcile1 failed"))
				int2.EXPECT().Reconcile(gomock.Any()).Return(nil)
			},
			expectedError: "armis updates completed with 1 errors",
			errorCount:    1,
		},
		{
			name: "multiple reconcile errors",
			setupMocks: func(int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Reconcile(gomock.Any()).Return(errors.New("reconcile1 failed"))
				int2.EXPECT().Reconcile(gomock.Any()).Return(errors.New("reconcile2 failed"))
			},
			expectedError: "armis updates completed with 2 errors",
			errorCount:    2,
		},
		{
			name: "all reconciles succeed",
			setupMocks: func(int1 *MockIntegration, int2 *MockIntegration) {
				int1.EXPECT().Reconcile(gomock.Any()).Return(nil)
				int2.EXPECT().Reconcile(gomock.Any()).Return(nil)
			},
			expectedError: "",
			errorCount:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockKVClient := NewMockKVClient(ctrl)

			mockGRPCClient := NewMockGRPCClient(ctrl)
			mockGRPCClient.EXPECT().Close().Return(nil)

			mockInt1 := NewMockIntegration(ctrl)
			mockInt2 := NewMockIntegration(ctrl)

			s, err := NewSimpleSyncService(
				context.Background(),
				&Config{
					AgentID:           "test-agent",
					PollerID:          "test-poller",
					DiscoveryInterval: models.Duration(time.Minute),
					UpdateInterval:    models.Duration(time.Minute),
					ListenAddr:        ":50051",
					Sources: map[string]*models.SourceConfig{
						"source1": {
							Type:     "test1",
							Endpoint: "http://test1",
							AgentID:  "test-agent",
						},
						"source2": {
							Type:     "test2",
							Endpoint: "http://test2",
							AgentID:  "test-agent",
						},
					},
				},
				mockKVClient,
				map[string]IntegrationFactory{
					"test1": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
						return mockInt1
					},
					"test2": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
						return mockInt2
					},
				},
				mockGRPCClient,
				logger.NewTestLogger(),
			)

			require.NoError(t, err)

			defer s.Stop(context.Background())

			// Sweep timing logic removed - updates proceed immediately

			// Setup mocks
			tt.setupMocks(mockInt1, mockInt2)

			// Run armis updates
			err = s.runArmisUpdates(context.Background())

			if tt.errorCount > 0 {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tt.expectedError)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

// TestSafelyRunTask validates panic recovery and error handling in safelyRunTask
func TestSafelyRunTask(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name          string
		task          func(context.Context) error
		expectedError string
		isPanic       bool
	}{
		{
			name: "successful task",
			task: func(_ context.Context) error {
				return nil
			},
			expectedError: "",
			isPanic:       false,
		},
		{
			name: "task returns error",
			task: func(_ context.Context) error {
				return errors.New("task failed")
			},
			expectedError: "test task error: task failed",
			isPanic:       false,
		},
		{
			name: "task panics",
			task: func(_ context.Context) error {
				panic("test panic")
			},
			expectedError: "panic in test task: test panic",
			isPanic:       true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockKVClient := NewMockKVClient(ctrl)
			mockGRPCClient := NewMockGRPCClient(ctrl)
			mockGRPCClient.EXPECT().Close().Return(nil)

			s, err := NewSimpleSyncService(
				context.Background(),
				&Config{
					AgentID:           "test-agent",
					PollerID:          "test-poller",
					DiscoveryInterval: models.Duration(time.Minute),
					UpdateInterval:    models.Duration(time.Minute),
					ListenAddr:        ":50051",
					Sources: map[string]*models.SourceConfig{
						"dummy": {
							Type:     "dummy",
							Endpoint: "http://dummy",
							AgentID:  "test-agent",
						},
					},
				},
				mockKVClient,
				map[string]IntegrationFactory{
					"dummy": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
						return &dummyIntegration{}
					},
				},
				mockGRPCClient,
				logger.NewTestLogger(),
			)

			require.NoError(t, err)

			defer s.Stop(context.Background())

			// Add one to wait group as safelyRunTask expects it
			s.wg.Add(1)

			// Run the task
			done := make(chan bool)

			go func() {
				s.safelyRunTask(context.Background(), "test task", tt.task)

				done <- true
			}()

			// Wait for task to complete with generous timeout
			select {
			case <-done:
				// Task completed
			case <-time.After(500 * time.Millisecond):
				t.Fatal("Task did not complete in time")
			}

			// Check if error was sent to channel
			if tt.expectedError != "" {
				select {
				case err := <-s.errorChan:
					assert.Contains(t, err.Error(), tt.expectedError)
				case <-time.After(500 * time.Millisecond):
					t.Fatal("Expected error not received")
				}
			} else {
				// No error expected
				select {
				case err := <-s.errorChan:
					t.Fatalf("Unexpected error received: %v", err)
				default:
				}
			}
		})
	}
}

// TestErrorChannelOverflow validates behavior when error channel is full
func TestErrorChannelOverflow(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKVClient := NewMockKVClient(ctrl)
	mockGRPCClient := NewMockGRPCClient(ctrl)
	mockGRPCClient.EXPECT().Close().Return(nil)

	s, err := NewSimpleSyncService(
		context.Background(),
		&Config{
			AgentID:           "test-agent",
			PollerID:          "test-poller",
			DiscoveryInterval: models.Duration(time.Minute),
			UpdateInterval:    models.Duration(time.Minute),
			ListenAddr:        ":50051",
			Sources: map[string]*models.SourceConfig{
				"dummy": {
					Type:     "dummy",
					Endpoint: "http://dummy",
					AgentID:  "test-agent",
				},
			},
		},
		mockKVClient,
		map[string]IntegrationFactory{
			"dummy": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
				return &dummyIntegration{}
			},
		},
		mockGRPCClient,
		logger.NewTestLogger(),
	)

	require.NoError(t, err)

	defer s.Stop(context.Background())

	// Fill the error channel
	for i := 0; i < cap(s.errorChan); i++ {
		s.sendError(fmt.Errorf("error %d", i))
	}

	// Try to send one more error - should not block
	done := make(chan bool)

	go func() {
		s.sendError(errors.New("overflow error"))

		done <- true
	}()

	select {
	case <-done:
		// Good, sendError didn't block
	case <-time.After(500 * time.Millisecond):
		t.Fatal("sendError blocked when channel was full")
	}
}

// TestGracefulShutdown validates that Stop waits for all goroutines
func TestGracefulShutdown(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKVClient := NewMockKVClient(ctrl)
	mockGRPCClient := NewMockGRPCClient(ctrl)
	mockIntegration := NewMockIntegration(ctrl)

	var taskStarted atomic.Bool

	var taskCompleted atomic.Bool

	s, err := NewSimpleSyncService(
		context.Background(),
		&Config{
			AgentID:           "test-agent",
			PollerID:          "test-poller",
			DiscoveryInterval: models.Duration(time.Hour), // Won't trigger
			UpdateInterval:    models.Duration(time.Hour),
			ListenAddr:        ":50051",
			Sources: map[string]*models.SourceConfig{
				"test-source": {
					Type:     "test",
					Endpoint: "http://test",
					AgentID:  "test-agent",
				},
			},
		},
		mockKVClient,
		map[string]IntegrationFactory{
			"test": func(_ context.Context, _ *models.SourceConfig, _ logger.Logger) Integration {
				return mockIntegration
			},
		},
		mockGRPCClient,
		logger.NewTestLogger(),
	)

	require.NoError(t, err)

	// Setup synchronization channel
	taskStartedChan := make(chan struct{})

	// Setup mock to simulate slow operation that respects context cancellation
	mockIntegration.EXPECT().Fetch(gomock.Any()).DoAndReturn(func(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, error) {
		taskStarted.Store(true)
		close(taskStartedChan) // Signal that task has started

		// Use context-aware sleep to allow cancellation
		select {
		case <-time.After(50 * time.Millisecond):
			// Normal completion after 50ms (shorter for tests)
			taskCompleted.Store(true)
			return nil, nil, nil
		case <-ctx.Done():
			// Context was canceled, exit early
			return nil, nil, ctx.Err()
		}
	})

	// Expect Close to be called during Stop
	mockGRPCClient.EXPECT().Close().Return(nil)

	// Launch a task - context parameter is ignored now as launchTask uses service's internal context
	s.launchTask(context.Background(), "test", s.runDiscovery)

	// Wait for task to start with timeout
	select {
	case <-taskStartedChan:
		// Task started successfully
	case <-time.After(500 * time.Millisecond):
		t.Fatal("Task did not start in time")
	}

	assert.True(t, taskStarted.Load(), "Task should have started")

	// Stop the service with a timeout to prevent test hanging
	stopDone := make(chan error, 1)

	go func() {
		stopDone <- s.Stop(context.Background())
	}()

	select {
	case stopErr := <-stopDone:
		require.NoError(t, stopErr)
	case <-time.After(5 * time.Second):
		t.Fatal("Stop() did not complete within 5 seconds - likely WaitGroup deadlock")
	}

	// Task should have started and the stop should have returned successfully
	// Note: taskCompleted may be false if context was canceled before sleep finished
	assert.True(t, taskStarted.Load(), "Task should have started")
}

// dummyIntegration is a test integration that does nothing
type dummyIntegration struct{}

func (*dummyIntegration) Fetch(_ context.Context) (map[string][]byte, []*models.DeviceUpdate, error) {
	return nil, nil, nil
}

func (*dummyIntegration) Reconcile(_ context.Context) error {
	return nil
}
