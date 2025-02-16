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

func (f *mockCollectorFactory) CreateCollector(target *Target) (Collector, error) {
	return f.collector, nil
}

type mockAggregatorFactory struct {
	aggregator *MockAggregator
}

func (f *mockAggregatorFactory) CreateAggregator(interval time.Duration) (Aggregator, error) {
	return f.aggregator, nil
}

func TestSNMPService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create test configuration
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

	t.Run("NewSNMPService", func(t *testing.T) {
		service, err := NewSNMPService(config)
		require.NoError(t, err)
		require.NotNil(t, service)
		assert.NotNil(t, service.collectors)
		assert.NotNil(t, service.aggregators)
	})

	t.Run("Start and Stop Service", func(t *testing.T) {
		// Create mocks
		mockCollector := NewMockCollector(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		// Create mock factories
		mocks := &mockFactories{
			collectorFactory: &mockCollectorFactory{
				collector: mockCollector,
			},
			aggregatorFactory: &mockAggregatorFactory{
				aggregator: mockAggregator,
			},
		}

		// Create service with mock factories
		service, err := NewSNMPService(config)
		require.NoError(t, err)

		// Replace factories with mocks
		service.collectorFactory = mocks.collectorFactory
		service.aggregatorFactory = mocks.aggregatorFactory

		// Set up mock expectations
		dataChan := make(chan DataPoint)
		mockCollector.EXPECT().Start(gomock.Any()).Return(nil)
		mockCollector.EXPECT().GetResults().Return(dataChan)
		mockCollector.EXPECT().Stop().Return(nil)

		// Test Start
		ctx := context.Background()
		err = service.Start(ctx)
		require.NoError(t, err)

		// Test Stop
		err = service.Stop()
		require.NoError(t, err)
	})

	t.Run("AddTarget", func(t *testing.T) {
		// Create mocks
		mockCollector := NewMockCollector(ctrl)
		mockAggregator := NewMockAggregator(ctrl)

		// Create mock factories
		mocks := &mockFactories{
			collectorFactory: &mockCollectorFactory{
				collector: mockCollector,
			},
			aggregatorFactory: &mockAggregatorFactory{
				aggregator: mockAggregator,
			},
		}

		// Create service with mock factories
		service, err := NewSNMPService(config)
		require.NoError(t, err)

		// Replace factories with mocks
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

		// Set up mock expectations for new target
		dataChan := make(chan DataPoint)
		mockCollector.EXPECT().Start(gomock.Any()).Return(nil)
		mockCollector.EXPECT().GetResults().Return(dataChan)

		err = service.AddTarget(newTarget)
		require.NoError(t, err)

		// Verify target was added
		_, exists := service.collectors[newTarget.Name]
		assert.True(t, exists)
	})

	t.Run("RemoveTarget", func(t *testing.T) {
		mockCollector := NewMockCollector(ctrl)
		service := &SNMPService{
			collectors:  make(map[string]Collector),
			aggregators: make(map[string]Aggregator),
			config:      config,
			status:      make(map[string]TargetStatus),
		}

		targetName := "test-target"
		service.collectors[targetName] = mockCollector

		// Set up mock expectations
		mockCollector.EXPECT().Stop().Return(nil)

		// Test removing target
		err := service.RemoveTarget(targetName)
		require.NoError(t, err)

		// Verify target was removed
		_, exists := service.collectors[targetName]
		assert.False(t, exists)
	})

	t.Run("GetStatus", func(t *testing.T) {
		service := &SNMPService{
			collectors:  make(map[string]Collector),
			aggregators: make(map[string]Aggregator),
			config:      config,
			status: map[string]TargetStatus{
				"test-target": {
					Available: true,
					LastPoll:  time.Now(),
					OIDStatus: map[string]OIDStatus{
						"sysUptime": {
							LastValue:  uint64(123456),
							LastUpdate: time.Now(),
						},
					},
				},
			},
		}

		status, err := service.GetStatus()
		require.NoError(t, err)
		assert.NotNil(t, status)
		assert.Contains(t, status, "test-target")
		assert.True(t, status["test-target"].Available)
	})
}
