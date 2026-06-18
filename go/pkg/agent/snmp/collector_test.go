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

// Package snmp pkg/agent/snmp/service_test.go
package snmp

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestCollector_WithMocks(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name      string
		setupMock func(*MockCollector)
		runTest   func(*MockCollector) error
		wantErr   bool
	}{
		{
			name: "successful collection",
			setupMock: func(mc *MockCollector) {
				dataChan := make(chan DataPoint, 1)
				mc.EXPECT().Start(gomock.Any()).Return(nil)
				mc.EXPECT().GetResults().Return(dataChan).AnyTimes()
				mc.EXPECT().Stop().Return(nil)
			},
			runTest: func(mc *MockCollector) error {
				ctx := context.Background()
				if err := mc.Start(ctx); err != nil {
					return err
				}
				_ = mc.GetResults() // Ensure GetResults is called
				return mc.Stop()
			},
			wantErr: false,
		},
		{
			name: "start failure",
			setupMock: func(mc *MockCollector) {
				mc.EXPECT().Start(gomock.Any()).Return(assert.AnError)
				mc.EXPECT().GetResults().Return(make(<-chan DataPoint)).AnyTimes()
			},
			runTest: func(mc *MockCollector) error {
				ctx := context.Background()
				if err := mc.Start(ctx); err != nil {
					_ = mc.GetResults() // Ensure GetResults is called even in error case
					return err
				}
				return nil
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockCollector := NewMockCollector(ctrl)
			tt.setupMock(mockCollector)

			err := tt.runTest(mockCollector)

			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestCollectorProcessResult_PreservesRawCounterSemantics(t *testing.T) {
	collector := &SNMPCollector{
		target: &Target{
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.31.1.1.1.6.7",
					Name:     "ifHCInOctets::ifindex:7",
					DataType: TypeCounter,
					Scale:    1,
					Delta:    true,
				},
			},
		},
		dataChan: make(chan DataPoint, 1),
		done:     make(chan struct{}),
		status: TargetStatus{
			OIDStatus: make(map[string]OIDStatus),
		},
	}

	err := collector.processResult(
		context.Background(),
		".1.3.6.1.2.1.31.1.1.1.6.7",
		CounterValue{Value: 9_007_199_254_740_993, Width: 64},
	)
	require.NoError(t, err)

	point := <-collector.dataChan
	require.Equal(t, "ifHCInOctets::ifindex:7", point.OIDName)
	require.Equal(t, uint64(9_007_199_254_740_993), point.Value)
	require.Equal(t, uint64(9_007_199_254_740_993), point.RawValue)
	require.Equal(t, TypeCounter, point.DataType)
	require.False(t, point.Delta)
	require.Equal(t, counterKindSum, point.Kind)
	require.Equal(t, counterTemporalityCumulative, point.Temporality)
	require.True(t, point.IsMonotonic)
	require.Equal(t, 64, point.CounterWidth)
}

func TestCalculateDelta_ResetDefault(t *testing.T) {
	delta, ok := calculateDelta(uint64(1000), uint64(1600), 0)
	require.True(t, ok)
	require.InDelta(t, 600.0, delta, 1e-9)

	_, ok = calculateDelta(uint64(1600), uint64(100), 64)
	require.False(t, ok)

	_, ok = calculateDelta(uint64(1600), uint64(100), 0)
	require.False(t, ok)

	delta, ok = calculateDelta(maxCounter32-99, uint64(100), 32)
	require.True(t, ok)
	require.InDelta(t, 200.0, delta, 1e-9)
}

func TestCollectorProcessResult_NonCounterDeltaStillRates(t *testing.T) {
	collector := &SNMPCollector{
		target: &Target{
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.4.1.1.1.0",
					Name:     "customGaugeDelta",
					DataType: TypeGauge,
					Delta:    true,
				},
			},
		},
		dataChan: make(chan DataPoint, 1),
		done:     make(chan struct{}),
		status: TargetStatus{
			OIDStatus: map[string]OIDStatus{
				"customGaugeDelta": {
					LastValue:  uint64(100),
					LastUpdate: time.Now().Add(-10 * time.Second),
				},
			},
		},
	}

	err := collector.processResult(context.Background(), ".1.3.6.1.4.1.1.1.0", uint64(200))
	require.NoError(t, err)

	point := <-collector.dataChan
	require.Equal(t, TypeFloat, point.DataType)
	require.False(t, point.Delta)
	require.InDelta(t, 10.0, point.Value, 0.1)
}

// A Gauge32 arrives on the wire as a bare uint64 (not a CounterValue). Even when
// an OID is misconfigured DataType:counter, it must NOT be classified or
// rate-normalized as a counter — the SNMP wire type, not operator config,
// decides. Regression guard for the gauge-as-counter footgun.
func TestCollectorProcessResult_GaugeWireMislabeledAsCounter_DowngradedToGauge(t *testing.T) {
	collector := &SNMPCollector{
		target: &Target{
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.2.2.1.5.7",
					Name:     "ifSpeed::ifindex:7",
					DataType: TypeCounter, // operator misconfiguration on a Gauge32 OID
					Scale:    1,
				},
			},
		},
		dataChan: make(chan DataPoint, 1),
		done:     make(chan struct{}),
		status: TargetStatus{
			OIDStatus: make(map[string]OIDStatus),
		},
		logger: logger.NewTestLogger(),
	}

	// Gauge32 wire value: a bare uint64, not a CounterValue.
	err := collector.processResult(context.Background(), ".1.3.6.1.2.1.2.2.1.5.7", uint64(1_000_000_000))
	require.NoError(t, err)

	point := <-collector.dataChan
	require.Equal(t, TypeGauge, point.DataType, "mislabeled gauge must be downgraded to gauge")
	require.NotEqual(t, counterKindSum, point.Kind, "must not be classified as a counter (SUM)")
	require.False(t, point.IsMonotonic, "a gauge is not monotonic")
	require.False(t, point.Delta)
	require.Equal(t, 0, point.CounterWidth, "no counter width for a gauge")
}

// A real Counter32 (CounterValue{Width:32}) on a DataType:counter OID is still
// classified as a counter — the gate only downgrades non-counter wire types.
func TestCollectorProcessResult_RealCounter32StaysCounter(t *testing.T) {
	collector := &SNMPCollector{
		target: &Target{
			OIDs: []OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.2.2.1.10.7",
					Name:     "ifInOctets::ifindex:7",
					DataType: TypeCounter,
					Scale:    1,
				},
			},
		},
		dataChan: make(chan DataPoint, 1),
		done:     make(chan struct{}),
		status: TargetStatus{
			OIDStatus: make(map[string]OIDStatus),
		},
		logger: logger.NewTestLogger(),
	}

	err := collector.processResult(
		context.Background(),
		".1.3.6.1.2.1.2.2.1.10.7",
		CounterValue{Value: 12345, Width: 32},
	)
	require.NoError(t, err)

	point := <-collector.dataChan
	require.Equal(t, TypeCounter, point.DataType)
	require.Equal(t, counterKindSum, point.Kind)
	require.True(t, point.IsMonotonic)
	require.Equal(t, 32, point.CounterWidth)
}
