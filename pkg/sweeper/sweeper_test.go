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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
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
			Stop().
			Return(nil)

		err = mockSweeper.Stop()
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
			Ports:       nil,                                     // Nil ports - should preserve existing
			SweepModes:  nil,                                     // Nil sweep modes - should preserve existing
			Interval:    0,                                       // Zero interval - should preserve existing
			Concurrency: 0,                                       // Zero concurrency - should preserve existing
			Timeout:     0,                                       // Zero timeout - should preserve existing
		}

		err := sweeper.UpdateConfig(newConfig)
		require.NoError(t, err)

		// Verify that existing values were preserved
		assert.Equal(t, 5*time.Minute, sweeper.config.Interval, "Interval should be preserved when new config has zero interval")
		assert.Equal(t, []int{22, 80, 443}, sweeper.config.Ports, "Ports should be preserved when new config has nil ports")
		assert.Equal(t,
			[]models.SweepMode{models.ModeTCP, models.ModeICMP},
			sweeper.config.SweepModes,
			"SweepModes should be preserved when new config has nil sweep_modes")
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
		assert.Equal(t,
			[]models.SweepMode{models.ModeTCP},
			sweeper.config.SweepModes,
			"SweepModes should be updated when new config has valid sweep_modes")
		assert.Equal(t, 5, sweeper.config.Concurrency, "Concurrency should be updated when new config has valid concurrency")
		assert.Equal(t, 60*time.Second, sweeper.config.Timeout, "Timeout should be updated when new config has valid timeout")
	})
}
