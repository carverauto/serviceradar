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
		newConfig := models.Config{
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
		config := models.Config{
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
