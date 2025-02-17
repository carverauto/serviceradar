// Package snmp pkg/checker/snmp/service_test.go
package snmp

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

type mockFactories struct {
	collectorFactory  *mockCollectorFactory
	aggregatorFactory *mockAggregatorFactory
}

type mockCollectorFactory struct {
	collector *MockCollector
}

func (f *mockCollectorFactory) CreateCollector(*Target) (Collector, error) {
	return f.collector, nil
}

type mockAggregatorFactory struct {
	aggregator *MockAggregator
}

func (f *mockAggregatorFactory) CreateAggregator(time.Duration) (Aggregator, error) {
	return f.aggregator, nil
}

func TestSNMPService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	config := &Config{
		NodeAddress: "localhost:50051",
		ListenAddr:  ":50052",
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
	t.Run("GetStatus", testGetStatus(config))
}

func testNewSNMPService(config *Config) func(t *testing.T) {
	return func(t *testing.T) {
		service, err := NewSNMPService(config)
		require.NoError(t, err)
		require.NotNil(t, service)
		assert.NotNil(t, service.collectors)
		assert.NotNil(t, service.aggregators)
	}
}

func testStartStopService(ctrl *gomock.Controller, config *Config) func(t *testing.T) {
	return func(t *testing.T) {
		mockCollector := NewMockCollector(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		mocks := &mockFactories{
			collectorFactory: &mockCollectorFactory{
				collector: mockCollector,
			},
			aggregatorFactory: &mockAggregatorFactory{
				aggregator: mockAggregator,
			},
		}

		service, err := NewSNMPService(config)
		require.NoError(t, err)

		service.collectorFactory = mocks.collectorFactory
		service.aggregatorFactory = mocks.aggregatorFactory

		dataChan := make(chan DataPoint)

		mockCollector.EXPECT().Start(gomock.Any()).Return(nil)
		mockCollector.EXPECT().GetResults().Return(dataChan)
		mockCollector.EXPECT().Stop().Return(nil)

		ctx := context.Background()
		err = service.Start(ctx)
		require.NoError(t, err)

		err = service.Stop()
		require.NoError(t, err)
	}
}

func testAddTarget(ctrl *gomock.Controller, config *Config) func(t *testing.T) {
	return func(t *testing.T) {
		mockCollector := NewMockCollector(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		mocks := &mockFactories{
			collectorFactory: &mockCollectorFactory{
				collector: mockCollector,
			},
			aggregatorFactory: &mockAggregatorFactory{
				aggregator: mockAggregator,
			},
		}

		service, err := NewSNMPService(config)
		require.NoError(t, err)

		service.collectorFactory = mocks.collectorFactory
		service.aggregatorFactory = mocks.aggregatorFactory

		newTarget := &Target{
			Name:      "new-target",
			Host:      "192.168.1.2",
			Port:      161,
			Community: "public",
			Version:   Version2c,
			Interval:  Duration(30 * time.Second),
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.1.3.0",
					Name:     "sysUptime",
					DataType: TypeGauge,
				},
			},
		}

		dataChan := make(chan DataPoint)

		mockCollector.EXPECT().Start(gomock.Any()).Return(nil)
		mockCollector.EXPECT().GetResults().Return(dataChan)

		err = service.AddTarget(newTarget)
		require.NoError(t, err)

		_, exists := service.collectors[newTarget.Name]
		assert.True(t, exists)
	}
}

func testRemoveTarget(ctrl *gomock.Controller, config *Config) func(t *testing.T) {
	return func(t *testing.T) {
		mockCollector := NewMockCollector(ctrl)
		service := &SNMPService{
			collectors:  make(map[string]Collector),
			aggregators: make(map[string]Aggregator),
			config:      config,
			status:      make(map[string]TargetStatus),
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

func testGetStatus(config *Config) func(t *testing.T) {
	return func(t *testing.T) {
		ctrl := gomock.NewController(t)
		defer ctrl.Finish()

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
		service := &SNMPService{
			collectors:  map[string]Collector{"test-target": mockCollector},
			aggregators: make(map[string]Aggregator),
			config:      config,
			status:      make(map[string]TargetStatus),
		}

		// Test GetStatus
		status, err := service.GetStatus(context.Background())
		require.NoError(t, err)
		assert.NotNil(t, status)
		assert.Contains(t, status, "test-target")
		assert.True(t, status["test-target"].Available)
	}
}
