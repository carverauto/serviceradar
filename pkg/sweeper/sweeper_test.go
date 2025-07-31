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

package sweeper

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestMockSweeper(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockSweeper := NewMockSweeper(ctrl)
	ctx := context.Background()

	t.Run("Start and Stop", func(t *testing.T) {
		// Test Start
		mockSweeper.EXPECT().
			Start(gomock.Any()).
			Return(nil)

		err := mockSweeper.Start(ctx)
		require.NoError(t, err)

		// Test Stop
		mockSweeper.EXPECT().
			Stop(ctx).
			Return(nil)

		err = mockSweeper.Stop(ctx)
		assert.NoError(t, err)
	})

	t.Run("GetConfig", func(t *testing.T) {
		expectedConfig := models.Config{
			Networks:   []string{"192.168.1.0/24"},
			Ports:      []int{80, 443},
			SweepModes: []models.SweepMode{models.ModeTCP},
			Interval:   time.Second * 30,
		}

		mockSweeper.EXPECT().
			GetConfig().
			Return(expectedConfig)

		config := mockSweeper.GetConfig()
		assert.Equal(t, expectedConfig, config)
	})

	t.Run("GetResults", func(t *testing.T) {
		filter := &models.ResultFilter{
			Host: "192.168.1.1",
			Port: 80,
		}

		expectedResults := []models.Result{
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Port: 80,
				},
				Available: true,
			},
		}

		mockSweeper.EXPECT().
			GetResults(gomock.Any(), filter).
			Return(expectedResults, nil)

		results, err := mockSweeper.GetResults(ctx, filter)
		require.NoError(t, err)
		assert.Equal(t, expectedResults, results)
	})

	t.Run("UpdateConfig", func(t *testing.T) {
		newConfig := &models.Config{
			Networks: []string{"10.0.0.0/24"},
			Ports:    []int{8080},
		}

		mockSweeper.EXPECT().
			UpdateConfig(newConfig).
			Return(nil)

		err := mockSweeper.UpdateConfig(newConfig)
		require.NoError(t, err)
	})
}

func TestNetworkSweeper_UpdateConfig_IntervalPreservation(t *testing.T) {
	// Create a NetworkSweeper with an initial config that has a valid interval
	initialConfig := &models.Config{
		Networks:    []string{"192.168.1.0/24"},
		Ports:       []int{22, 80, 443},
		SweepModes:  []models.SweepMode{models.ModeTCP, models.ModeICMP},
		Interval:    5 * time.Minute,
		Concurrency: 10,
		Timeout:     30 * time.Second,
	}

	sweeper := &NetworkSweeper{
		config: initialConfig,
		logger: logger.NewTestLogger(),
	}

	t.Run("UpdateConfig preserves fields when new config has zero/nil values", func(t *testing.T) {
		// Create a new config with minimal values (like from sync service)
		newConfig := &models.Config{
			Networks:    []string{"10.0.0.0/8", "172.16.0.0/12"}, // Only networks provided
			Ports:       nil,                                       // Nil ports - should preserve existing
			SweepModes:  nil,                                       // Nil sweep modes - should preserve existing
			Interval:    0,                                         // Zero interval - should preserve existing
			Concurrency: 0,                                         // Zero concurrency - should preserve existing
			Timeout:     0,                                         // Zero timeout - should preserve existing
		}

		err := sweeper.UpdateConfig(newConfig)
		require.NoError(t, err)

		// Verify that existing values were preserved
		assert.Equal(t, 5*time.Minute, sweeper.config.Interval, "Interval should be preserved when new config has zero interval")
		assert.Equal(t, []int{22, 80, 443}, sweeper.config.Ports, "Ports should be preserved when new config has nil ports")
		assert.Equal(t, []models.SweepMode{models.ModeTCP, models.ModeICMP}, sweeper.config.SweepModes, "SweepModes should be preserved when new config has nil sweep_modes")
		assert.Equal(t, 10, sweeper.config.Concurrency, "Concurrency should be preserved when new config has zero concurrency")
		assert.Equal(t, 30*time.Second, sweeper.config.Timeout, "Timeout should be preserved when new config has zero timeout")

		// Verify networks were updated (this is what sync service sends)
		assert.Equal(t, []string{"10.0.0.0/8", "172.16.0.0/12"}, sweeper.config.Networks, "Networks should be updated from new config")
	})

	t.Run("UpdateConfig updates fields when new config has valid values", func(t *testing.T) {
		// Create a new config with valid non-zero values
		newConfig := &models.Config{
			Networks:    []string{"192.168.0.0/16"},
			Ports:       []int{443, 8443},
			SweepModes:  []models.SweepMode{models.ModeTCP},
			Interval:    10 * time.Minute, // Valid new interval
			Concurrency: 5,
			Timeout:     60 * time.Second,
		}

		err := sweeper.UpdateConfig(newConfig)
		require.NoError(t, err)

		// Verify that all fields were updated to the new values
		assert.Equal(t, 10*time.Minute, sweeper.config.Interval, "Interval should be updated when new config has valid interval")
		assert.Equal(t, []string{"192.168.0.0/16"}, sweeper.config.Networks, "Networks should be updated")
		assert.Equal(t, []int{443, 8443}, sweeper.config.Ports, "Ports should be updated when new config has valid ports")
		assert.Equal(t, []models.SweepMode{models.ModeTCP}, sweeper.config.SweepModes, "SweepModes should be updated when new config has valid sweep_modes")
		assert.Equal(t, 5, sweeper.config.Concurrency, "Concurrency should be updated when new config has valid concurrency")
		assert.Equal(t, 60*time.Second, sweeper.config.Timeout, "Timeout should be updated when new config has valid timeout")
	})
}

func TestNetworkSweeper_WatchConfigWithInitialSignal(t *testing.T) {
	// Create a mock KV store
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	
	mockKVStore := NewMockKVStore(ctrl)
	
	t.Run("WatchConfig with initial KV config", func(t *testing.T) {
		// Create fresh config for this test
		initialConfig := &models.Config{
			Networks: []string{"192.168.1.0/24"},
			Ports:    []int{22, 80},
			Interval: 5 * time.Minute,
		}
		
		sweeper := &NetworkSweeper{
			config:    initialConfig,
			logger:    logger.NewTestLogger(),
			kvStore:   mockKVStore,
			configKey: "test-config-key",
			watchDone: make(chan struct{}),
		}
		
		// Mock KV config with new networks
		kvConfigJSON := `{"networks":["10.0.0.0/8","172.16.0.0/12"],"ports":null,"interval":""}`
		
		// Create a channel that will send the config update
		watchCh := make(chan []byte, 1)
		watchCh <- []byte(kvConfigJSON)
		close(watchCh)
		
		mockKVStore.EXPECT().
			Watch(gomock.Any(), "test-config-key").
			Return((<-chan []byte)(watchCh), nil)
		
		configReady := make(chan struct{})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		
		go sweeper.watchConfigWithInitialSignal(ctx, configReady)
		
		// Wait for the config ready signal
		select {
		case <-configReady:
			// Config was received and processed
		case <-ctx.Done():
			t.Fatal("Timeout waiting for config ready signal")
		}
		
		// Verify that networks were updated but other fields preserved
		assert.Equal(t, []string{"10.0.0.0/8", "172.16.0.0/12"}, sweeper.config.Networks, "Networks should be updated from KV")
		assert.Equal(t, []int{22, 80}, sweeper.config.Ports, "Ports should be preserved from file config")
		assert.Equal(t, 5*time.Minute, sweeper.config.Interval, "Interval should be preserved from file config")
	})
	
	t.Run("WatchConfig with no KV store", func(t *testing.T) {
		// Create fresh config for this test
		initialConfig := &models.Config{
			Networks: []string{"192.168.1.0/24"},
			Ports:    []int{22, 80},
			Interval: 5 * time.Minute,
		}
		
		sweeper := &NetworkSweeper{
			config:    initialConfig,
			logger:    logger.NewTestLogger(),
			kvStore:   nil, // No KV store
			configKey: "test-config-key",
			watchDone: make(chan struct{}),
		}
		
		configReady := make(chan struct{})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		
		go sweeper.watchConfigWithInitialSignal(ctx, configReady)
		
		// Should signal immediately since there's no KV store
		select {
		case <-configReady:
			// Config ready signal received immediately
		case <-ctx.Done():
			t.Fatal("Timeout waiting for config ready signal")
		}
		
		// Verify that original config is unchanged
		assert.Equal(t, []string{"192.168.1.0/24"}, sweeper.config.Networks, "Networks should remain unchanged")
		assert.Equal(t, []int{22, 80}, sweeper.config.Ports, "Ports should remain unchanged")
		assert.Equal(t, 5*time.Minute, sweeper.config.Interval, "Interval should remain unchanged")
	})
	
	t.Run("WatchConfig with KV error", func(t *testing.T) {
		// Create fresh config for this test
		initialConfig := &models.Config{
			Networks: []string{"192.168.1.0/24"},
			Ports:    []int{22, 80},
			Interval: 5 * time.Minute,
		}
		
		sweeper := &NetworkSweeper{
			config:    initialConfig,
			logger:    logger.NewTestLogger(),
			kvStore:   mockKVStore,
			configKey: "test-config-key",
			watchDone: make(chan struct{}),
		}
		
		mockKVStore.EXPECT().
			Watch(gomock.Any(), "test-config-key").
			Return(nil, errors.New("KV connection failed"))
		
		configReady := make(chan struct{})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		
		go sweeper.watchConfigWithInitialSignal(ctx, configReady)
		
		// Should signal immediately on error
		select {
		case <-configReady:
			// Config ready signal received on error
		case <-ctx.Done():
			t.Fatal("Timeout waiting for config ready signal")
		}
		
		// Verify that original config is unchanged when there's an error
		assert.Equal(t, []string{"192.168.1.0/24"}, sweeper.config.Networks, "Networks should remain unchanged on error")
		assert.Equal(t, []int{22, 80}, sweeper.config.Ports, "Ports should remain unchanged on error")
		assert.Equal(t, 5*time.Minute, sweeper.config.Interval, "Interval should remain unchanged on error")
	})
}

func TestMockResultProcessor(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockProcessor := NewMockResultProcessor(ctrl)
	ctx := context.Background()

	t.Run("Process Result", func(t *testing.T) {
		result := &models.Result{
			Target: models.Target{
				Host: "192.168.1.1",
				Port: 80,
			},
			Available: true,
		}

		mockProcessor.EXPECT().
			Process(result).
			Return(nil)

		err := mockProcessor.Process(result)
		assert.NoError(t, err)
	})

	t.Run("Get Summary", func(t *testing.T) {
		expectedSummary := &models.SweepSummary{
			TotalHosts:     10,
			AvailableHosts: 5,
			LastSweep:      time.Now().Unix(),
		}

		mockProcessor.EXPECT().
			GetSummary(gomock.Any()).
			Return(expectedSummary, nil)

		summary, err := mockProcessor.GetSummary(ctx)
		require.NoError(t, err)
		assert.Equal(t, expectedSummary, summary)
	})
}

func TestMockStore(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockStore := NewMockStore(ctrl)
	ctx := context.Background()

	t.Run("SaveResult", func(t *testing.T) {
		result := &models.Result{
			Target: models.Target{
				Host: "192.168.1.1",
				Port: 80,
			},
			Available: true,
		}

		mockStore.EXPECT().
			SaveResult(gomock.Any(), result).
			Return(nil)

		err := mockStore.SaveResult(ctx, result)
		assert.NoError(t, err)
	})

	t.Run("GetResults", func(t *testing.T) {
		filter := &models.ResultFilter{
			Host:      "192.168.1.1",
			Port:      80,
			StartTime: time.Now().Add(-time.Hour),
			EndTime:   time.Now(),
		}

		expectedResults := []models.Result{
			{
				Target: models.Target{
					Host: "192.168.1.1",
					Port: 80,
				},
				Available: true,
			},
		}

		mockStore.EXPECT().
			GetResults(gomock.Any(), filter).
			Return(expectedResults, nil)

		results, err := mockStore.GetResults(ctx, filter)
		require.NoError(t, err)
		assert.Equal(t, expectedResults, results)
	})

	t.Run("PruneResults", func(t *testing.T) {
		retention := 24 * time.Hour

		mockStore.EXPECT().
			PruneResults(gomock.Any(), retention).
			Return(nil)

		err := mockStore.PruneResults(ctx, retention)
		assert.NoError(t, err)
	})

	t.Run("GetSweepSummary", func(t *testing.T) {
		expectedSummary := &models.SweepSummary{
			TotalHosts:     100,
			AvailableHosts: 75,
			LastSweep:      time.Now().Unix(),
		}

		mockStore.EXPECT().
			GetSweepSummary(gomock.Any()).
			Return(expectedSummary, nil)

		summary, err := mockStore.GetSweepSummary(ctx)
		require.NoError(t, err)
		assert.Equal(t, expectedSummary, summary)
	})
}

func TestMockReporter(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockReporter := NewMockReporter(ctrl)
	ctx := context.Background()

	t.Run("Report", func(t *testing.T) {
		summary := &models.SweepSummary{
			TotalHosts:     50,
			AvailableHosts: 30,
			LastSweep:      time.Now().Unix(),
		}

		mockReporter.EXPECT().
			Report(gomock.Any(), summary).
			Return(nil)

		err := mockReporter.Report(ctx, summary)
		assert.NoError(t, err)
	})
}

func TestMockSweepService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockService := NewMockSweepService(ctrl)
	ctx := context.Background()

	t.Run("Start and Stop", func(t *testing.T) {
		mockService.EXPECT().
			Start(gomock.Any()).
			Return(nil)

		err := mockService.Start(ctx)
		require.NoError(t, err)

		mockService.EXPECT().
			Stop().
			Return(nil)

		err = mockService.Stop()
		assert.NoError(t, err)
	})

	t.Run("GetStatus", func(t *testing.T) {
		expectedStatus := &models.SweepSummary{
			TotalHosts:     200,
			AvailableHosts: 150,
			LastSweep:      time.Now().Unix(),
		}

		mockService.EXPECT().
			GetStatus(gomock.Any()).
			Return(expectedStatus, nil)

		status, err := mockService.GetStatus(ctx)
		require.NoError(t, err)
		assert.Equal(t, expectedStatus, status)
	})

	t.Run("UpdateConfig", func(t *testing.T) {
		config := &models.Config{
			Networks:   []string{"172.16.0.0/16"},
			Ports:      []int{22, 80, 443},
			SweepModes: []models.SweepMode{models.ModeTCP, models.ModeICMP},
		}

		mockService.EXPECT().
			UpdateConfig(config).
			Return(nil)

		err := mockService.UpdateConfig(config)
		assert.NoError(t, err)
	})
}

// Helper function to verify gomock matchers.
func TestGomockMatchers(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	t.Run("Context Matcher", func(t *testing.T) {
		mockStore := NewMockStore(ctrl)
		ctx := context.Background()

		// Test that any context matches
		mockStore.EXPECT().
			GetResults(gomock.Any(), gomock.Any()).
			Return(nil, nil)

		_, err := mockStore.GetResults(ctx, &models.ResultFilter{})
		require.NoError(t, err)
	})

	t.Run("Filter Matcher", func(t *testing.T) {
		mockStore := NewMockStore(ctrl)
		filter := &models.ResultFilter{
			Host: "192.168.1.1",
			Port: 80,
		}

		// Test exact filter matching
		mockStore.EXPECT().
			GetResults(gomock.Any(), filter).
			Return(nil, nil)

		_, err := mockStore.GetResults(context.Background(), filter)
		require.NoError(t, err)
	})
}
