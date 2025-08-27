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

// Package snmp pkg/checker/snmp/service_test.go
package snmp

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/logger"
)

func TestSNMPService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &SNMPConfig{
		NodeAddress: "localhost:50051",
		ListenAddr:  ":50052",
		Partition:   "test-partition",
		Targets: []Target{
			{
				Name:      "test-target",
				Host:      "192.168.1.1",
				Port:      161,
				Community: "public",
				Version:   Version2c,
				Interval:  Duration(30 * time.Second),
				Retries:   2,
				OIDs: []OIDConfig{
					{
						OID:      ".1.3.6.1.2.1.1.3.0",
						Name:     "sysUptime",
						DataType: TypeGauge,
					},
				},
			},
		},
	}

	t.Run("NewSNMPService", testNewSNMPService(config))
	t.Run("Start and Stop Service", testStartStopService(ctrl, config))
	t.Run("AddTarget", testAddTarget(ctrl, config))
	t.Run("RemoveTarget", testRemoveTarget(ctrl, config))
	t.Run("GetStatus", testGetStatus(ctrl, config))
}

func testNewSNMPService(config *SNMPConfig) func(t *testing.T) {
	return func(t *testing.T) {
		testLogger := logger.NewTestLogger()
		service, err := NewSNMPService(config, testLogger)
		require.NoError(t, err)
		require.NotNil(t, service)
		assert.NotNil(t, service.collectors)
		assert.NotNil(t, service.aggregators)
	}
}

func testStartStopService(ctrl *gomock.Controller, config *SNMPConfig) func(t *testing.T) {
	return func(t *testing.T) {
		// Create mock collector factory and mock collector
		mockCollectorFactory := NewMockCollectorFactory(ctrl)
		mockCollector := NewMockCollector(ctrl)

		// Create mock aggregator factory and mock aggregator
		mockAggregatorFactory := NewMockAggregatorFactory(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		// Create service with mocks
		testLogger := logger.NewTestLogger()
		service, err := NewSNMPService(config, testLogger)
		require.NoError(t, err)

		service.collectorFactory = mockCollectorFactory
		service.aggregatorFactory = mockAggregatorFactory

		dataChan := make(chan DataPoint)

		// Set up expectations
		mockCollectorFactory.EXPECT().
			CreateCollector(gomock.Any(), gomock.Any()).
			Return(mockCollector, nil)

		mockAggregatorFactory.EXPECT().
			CreateAggregator(gomock.Any(), defaultMaxPoints).
			Return(mockAggregator, nil)

		mockCollector.EXPECT().Start(gomock.Any()).Return(nil)
		mockCollector.EXPECT().GetResults().Return(dataChan)
		mockCollector.EXPECT().Stop().Return(nil)

		// Test start
		ctx := context.Background()
		err = service.Start(ctx)
		require.NoError(t, err)

		// Give time for the processResults goroutine to call GetResults()
		time.Sleep(10 * time.Millisecond)

		// Test stop
		err = service.Stop()
		require.NoError(t, err)
	}
}

func testAddTarget(ctrl *gomock.Controller, config *SNMPConfig) func(t *testing.T) {
	return func(t *testing.T) {
		// Create mock factories
		mockCollectorFactory := NewMockCollectorFactory(ctrl)
		mockAggregatorFactory := NewMockAggregatorFactory(ctrl)

		// Create mock collector and aggregator
		mockCollector := NewMockCollector(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		// Create service with mocks
		testLogger := logger.NewTestLogger()
		service, err := NewSNMPService(config, testLogger)
		require.NoError(t, err)

		service.collectorFactory = mockCollectorFactory
		service.aggregatorFactory = mockAggregatorFactory

		newTarget := &Target{
			Name:      "new-target",
			Host:      "192.168.1.2",
			Port:      161,
			Community: "public",
			Version:   Version2c,
			Interval:  Duration(30 * time.Second),
			MaxPoints: defaultMaxPoints,
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.1.3.0",
					Name:     "sysUptime",
					DataType: TypeGauge,
				},
			},
		}

		dataChan := make(chan DataPoint)
		// Channel to signal when GetResults is called
		getResultsCalled := make(chan struct{})

		// Set up expectations
		mockCollectorFactory.EXPECT().
			CreateCollector(newTarget, gomock.Any()).
			Return(mockCollector, nil)

		mockAggregatorFactory.EXPECT().
			CreateAggregator(time.Duration(newTarget.Interval), newTarget.MaxPoints).
			Return(mockAggregator, nil)

		mockCollector.EXPECT().
			Start(gomock.Any()).
			Return(nil)

		mockCollector.EXPECT().
			GetResults().
			DoAndReturn(func() <-chan DataPoint {
				close(getResultsCalled) // Signal that GetResults was called
				return dataChan
			})

		// Test adding target
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
		defer cancel()

		err = service.AddTarget(ctx, newTarget)
		require.NoError(t, err)

		// Wait for GetResults to be called
		select {
		case <-getResultsCalled:
			// GetResults was called, proceed
		case <-ctx.Done():
			t.Fatal("Timeout waiting for GetResults to be called")
		}

		_, exists := service.collectors[newTarget.Name]
		assert.True(t, exists)
	}
}

func testRemoveTarget(ctrl *gomock.Controller, config *SNMPConfig) func(t *testing.T) {
	return func(t *testing.T) {
		mockCollector := NewMockCollector(ctrl)
		testLogger := logger.NewTestLogger()
		service := &SNMPService{
			collectors:  make(map[string]Collector),
			aggregators: make(map[string]Aggregator),
			config:      config,
			status:      make(map[string]TargetStatus),
			logger:      testLogger,
		}

		targetName := "test-target"
		service.collectors[targetName] = mockCollector

		mockCollector.EXPECT().Stop().Return(nil)

		err := service.RemoveTarget(targetName)
		require.NoError(t, err)

		_, exists := service.collectors[targetName]
		assert.False(t, exists)
	}
}

func testGetStatus(ctrl *gomock.Controller, config *SNMPConfig) func(t *testing.T) {
	return func(t *testing.T) {
		// Create mock collector
		mockCollector := NewMockCollector(ctrl)
		mockCollector.EXPECT().GetStatus().Return(TargetStatus{
			Available: true,
			LastPoll:  time.Now(),
			OIDStatus: map[string]OIDStatus{
				"sysUptime": {
					LastValue:  uint64(123456),
					LastUpdate: time.Now(),
				},
			},
		}).AnyTimes()

		// Create service with mock collector
		testLogger := logger.NewTestLogger()
		service := &SNMPService{
			collectors:  map[string]Collector{"test-target": mockCollector},
			aggregators: make(map[string]Aggregator),
			config:      config,
			status:      make(map[string]TargetStatus),
			logger:      testLogger,
		}

		// Test GetStatus
		status, err := service.GetStatus(context.Background())
		require.NoError(t, err)
		assert.NotNil(t, status)
		assert.Contains(t, status, "test-target")
		assert.True(t, status["test-target"].Available)
	}
}
