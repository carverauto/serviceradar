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

package mapper

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestNewAgentService(t *testing.T) {
	// Test with nil engine
	service := NewAgentService(nil)
	assert.NotNil(t, service)
	assert.Nil(t, service.engine)

	// Test with non-nil engine
	mockEngine := &DiscoveryEngine{}
	service = NewAgentService(mockEngine)
	assert.NotNil(t, service)
	assert.Equal(t, mockEngine, service.engine)
}

func TestGetStatusWithDifferentEngineStates(t *testing.T) {
	ctx := context.Background()
	req := &proto.StatusRequest{}

	tests := []struct {
		name           string
		setupEngine    func() *DiscoveryEngine
		expectedStatus bool
		expectedMsg    map[string]interface{}
	}{
		{
			name: "nil engine",
			setupEngine: func() *DiscoveryEngine {
				return nil
			},
			expectedStatus: false,
			expectedMsg: map[string]interface{}{
				"status":  "unavailable",
				"message": "serviceradar-mapper is not operational",
			},
		},
		{
			name: "engine not running (done is nil)",
			setupEngine: func() *DiscoveryEngine {
				return &DiscoveryEngine{
					done:       nil,
					schedulers: make(map[string]*time.Ticker),
				}
			},
			expectedStatus: false,
			expectedMsg: map[string]interface{}{
				"status":  "unavailable",
				"message": "serviceradar-mapper is not operational",
			},
		},
		{
			name: "engine not running (no schedulers)",
			setupEngine: func() *DiscoveryEngine {
				return &DiscoveryEngine{
					done:       make(chan struct{}),
					schedulers: make(map[string]*time.Ticker),
				}
			},
			expectedStatus: false,
			expectedMsg: map[string]interface{}{
				"status":  "unavailable",
				"message": "serviceradar-mapper is not operational",
			},
		},
		{
			name: "engine running",
			setupEngine: func() *DiscoveryEngine {
				return &DiscoveryEngine{
					done:       make(chan struct{}),
					schedulers: map[string]*time.Ticker{"test": {}},
				}
			},
			expectedStatus: true,
			expectedMsg: map[string]interface{}{
				"status":  "operational",
				"message": "serviceradar-mapper is operational",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewAgentService(tt.setupEngine())
			resp, err := service.GetStatus(ctx, req)

			require.NoError(t, err)
			assert.NotNil(t, resp)
			assert.Equal(t, tt.expectedStatus, resp.Available)
			assert.Equal(t, "serviceradar-mapper", resp.ServiceName)
			assert.Equal(t, "service-instance", resp.ServiceType)
			assert.Equal(t, "serviceradar-mapper-monitor", resp.AgentId)

			// Verify message content
			var message map[string]interface{}

			err = json.Unmarshal(resp.Message, &message)
			require.NoError(t, err)
			assert.Equal(t, tt.expectedMsg["status"], message["status"])
			assert.Equal(t, tt.expectedMsg["message"], message["message"])
		})
	}
}

func TestGetStatusWithMockEngine(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	ctx := context.Background()
	req := &proto.StatusRequest{}

	// We're using a real DiscoveryEngine for this test, not a mock

	// Create a real DiscoveryEngine with the necessary fields for testing
	engine := &DiscoveryEngine{
		done:       make(chan struct{}),
		schedulers: map[string]*time.Ticker{"test": {}},
	}

	// Create the service with the real engine
	service := NewAgentService(engine)

	// Test the GetStatus method
	resp, err := service.GetStatus(ctx, req)

	require.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, "serviceradar-mapper", resp.ServiceName)

	// Verify message content
	var message map[string]interface{}

	err = json.Unmarshal(resp.Message, &message)
	require.NoError(t, err)
	assert.Equal(t, "operational", message["status"])
	assert.Equal(t, "serviceradar-mapper is operational", message["message"])
}

func TestGetStatusJsonError(_ *testing.T) {
	// This test is to verify error handling when json.Marshal fails
	// However, since it's difficult to make json.Marshal fail in a normal test,
	// we'll skip implementing this test case. In a real-world scenario,
	// you might use a library like github.com/bouk/monkey to patch the json.Marshal
	// function to return an error.

	// The test would look something like this:
	/*
		ctrl := gomock.NewController(t)
		defer ctrl.Finish()

		ctx := context.Background()
		req := &proto.StatusRequest{}

		// Create a mock engine
		engine := &DiscoveryEngine{
			done: make(chan struct{}),
			schedulers: map[string]*time.Ticker{
				"test": &time.Ticker{},
			},
		}

		service := NewAgentService(engine)

		// Patch json.Marshal to return an error
		patch := monkey.Patch(json.Marshal, func(interface{}) ([]byte, error) {
			return nil, errors.New("mock marshal error")
		})
		defer patch.Unpatch()

		// Test the GetStatus method
		resp, err := service.GetStatus(ctx, req)

		assert.Error(t, err)
		assert.Nil(t, resp)
		assert.Contains(t, err.Error(), "mock marshal error")
	*/
}
