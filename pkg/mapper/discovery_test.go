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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewDiscoveryEngine(t *testing.T) {
	tests := []struct {
		name        string
		config      *Config
		expectError bool
	}{
		{
			name:        "nil config",
			config:      nil,
			expectError: true,
		},
		{
			name: "invalid workers",
			config: &Config{
				Workers:       0,
				MaxActiveJobs: 1,
			},
			expectError: true,
		},
		{
			name: "invalid max active jobs",
			config: &Config{
				Workers:       1,
				MaxActiveJobs: 0,
			},
			expectError: true,
		},
		{
			name: "valid config",
			config: &Config{
				Workers:         2,
				MaxActiveJobs:   5,
				Timeout:         30 * time.Second,
				ResultRetention: 24 * time.Hour,
			},
			expectError: false,
		},
		{
			name: "default timeout",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
			},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockPublisher := new(MockPublisher)
			engine, err := NewDiscoveryEngine(tt.config, mockPublisher)

			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, engine)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, engine)

				// Verify default values are set when needed
				if tt.config != nil && tt.config.Timeout <= 0 {
					assert.Equal(t, defaultTimeout, tt.config.Timeout)
				}

				if tt.config != nil && tt.config.ResultRetention <= 0 {
					assert.Equal(t, defaultResultRetention, tt.config.ResultRetention)
				}
			}
		})
	}
}

func TestStartDiscovery(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with empty seeds
	ctx := context.Background()
	params := &DiscoveryParams{
		Seeds: []string{},
		Type:  DiscoveryTypeBasic,
	}
	_, err = engine.StartDiscovery(ctx, params)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no seeds provided")

	// Test with valid params
	params.Seeds = []string{"192.168.1.1"}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Verify job was created and enqueued
	discoveryEngine := engine.(*DiscoveryEngine)
	assert.Contains(t, discoveryEngine.activeJobs, discoveryID)
}

func TestGetDiscoveryStatus(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	status, err := engine.GetDiscoveryStatus(ctx, "non-existent-id")
	require.Error(t, err)
	assert.Nil(t, status)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Get status of the job
	status, err = engine.GetDiscoveryStatus(ctx, discoveryID)
	require.NoError(t, err)
	assert.NotNil(t, status)
	assert.Equal(t, DiscoveryStatusPending, status.Status)
}

func TestGetDiscoveryResults(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	results, err := engine.GetDiscoveryResults(ctx, "non-existent-id", false)
	require.Error(t, err)
	assert.Nil(t, results)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}

	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Move job to completed jobs for testing
	discoveryEngine := engine.(*DiscoveryEngine)
	job := discoveryEngine.activeJobs[discoveryID]
	job.Status.Status = DiscoveryStatusCompleted
	discoveryEngine.completedJobs[discoveryID] = job.Results
	delete(discoveryEngine.activeJobs, discoveryID)

	// Get results of the job
	results, err = engine.GetDiscoveryResults(ctx, discoveryID, false)
	require.NoError(t, err)
	assert.NotNil(t, results)
	assert.Equal(t, DiscoveryStatusCompleted, results.Status.Status)
}

func TestCancelDiscovery(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	err = engine.CancelDiscovery(ctx, "non-existent-id")
	require.Error(t, err)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Cancel the job
	err = engine.CancelDiscovery(ctx, discoveryID)
	require.NoError(t, err)

	// Verify job was canceled
	discoveryEngine := engine.(*DiscoveryEngine)
	_, exists := discoveryEngine.activeJobs[discoveryID]
	assert.False(t, exists)

	// Verify job status was updated
	results, err := engine.GetDiscoveryResults(ctx, discoveryID, false)
	require.NoError(t, err)
	assert.Equal(t, DiscoverStatusCanceled, results.Status.Status)
}

func TestValidateConfig(t *testing.T) {
	tests := []struct {
		name        string
		config      *Config
		expectError bool
	}{
		{
			name:        "nil config",
			config:      nil,
			expectError: true,
		},
		{
			name: "invalid workers",
			config: &Config{
				Workers:       0,
				MaxActiveJobs: 1,
			},
			expectError: true,
		},
		{
			name: "invalid max active jobs",
			config: &Config{
				Workers:       1,
				MaxActiveJobs: 0,
			},
			expectError: true,
		},
		{
			name: "valid config",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
				Timeout:       30 * time.Second,
			},
			expectError: false,
		},
		{
			name: "invalid scheduled job",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
				ScheduledJobs: []*ScheduledJob{
					{
						Name:    "",
						Enabled: true,
					},
				},
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateConfig(tt.config)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestValidateScheduledJob(t *testing.T) {
	tests := []struct {
		name        string
		job         *ScheduledJob
		expectError bool
	}{
		{
			name: "missing name",
			job: &ScheduledJob{
				Name:    "",
				Enabled: true,
			},
			expectError: true,
		},
		{
			name: "disabled job",
			job: &ScheduledJob{
				Name:    "test",
				Enabled: false,
			},
			expectError: false,
		},
		{
			name: "invalid interval",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "invalid",
			},
			expectError: true,
		},
		{
			name: "no seeds",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{},
			},
			expectError: true,
		},
		{
			name: "invalid type",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{"192.168.1.1"},
				Type:     "invalid",
			},
			expectError: true,
		},
		{
			name: "valid job",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{"192.168.1.1"},
				Type:     "basic",
			},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateScheduledJob(tt.job)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestInitializeDevice(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Test initializing a device
	target := "192.168.1.1"
	device := discoveryEngine.initializeDevice(target)

	assert.NotNil(t, device)
	assert.Equal(t, target, device.IP)
	assert.Empty(t, device.DeviceID)  // DeviceID should be empty initially
	assert.Empty(t, device.Hostname)  // Hostname should be empty initially
	assert.NotNil(t, device.Metadata) // Metadata should be initialized
}

func TestDetermineConcurrency(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Create a job with no concurrency specified
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Concurrency: 0,
		},
	}

	// Test with small target list
	concurrency := discoveryEngine.determineConcurrency(job, 5)
	assert.Equal(t, 5, concurrency) // Should match target count

	// Test with large target list
	concurrency = discoveryEngine.determineConcurrency(job, 100)
	assert.Equal(t, discoveryEngine.workers, concurrency) // Should match worker count

	// Test with specified concurrency
	job.Params.Concurrency = 10
	concurrency = discoveryEngine.determineConcurrency(job, 100)
	assert.Equal(t, 10, concurrency) // Should match specified concurrency
}

func TestEnsureDeviceID(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Test with empty DeviceID
	device := &DiscoveredDevice{
		IP: "192.168.1.1",
	}
	discoveryEngine.ensureDeviceID(device)
	assert.NotEmpty(t, device.DeviceID)

	// Test with existing DeviceID
	device = &DiscoveredDevice{
		IP:       "192.168.1.1",
		DeviceID: "existing-id",
	}
	discoveryEngine.ensureDeviceID(device)
	assert.Equal(t, "existing-id", device.DeviceID) // DeviceID should not change
}

func TestHandleEmptyTargetList(t *testing.T) {
	mockPublisher := new(MockPublisher)
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Create a job
	job := &DiscoveryJob{
		Status: &DiscoveryStatus{
			Status: DiscoveryStatusPending,
		},
	}

	// Handle empty target list
	discoveryEngine.handleEmptyTargetList(job)

	// Verify job status was updated
	assert.Equal(t, DiscoveryStatusFailed, job.Status.Status)
	assert.Contains(t, job.Status.Error, "No valid targets")
}

func TestGenerateDiscoveryID(t *testing.T) {
	// Test that generated IDs are unique
	id1 := generateDiscoveryID()
	id2 := generateDiscoveryID()

	assert.NotEmpty(t, id1)
	assert.NotEmpty(t, id2)
	assert.NotEqual(t, id1, id2)
}
