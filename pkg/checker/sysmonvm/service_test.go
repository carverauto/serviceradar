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

// Package sysmonvm pkg/checker/sysmonvm/service_test.go
package sysmonvm

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errTestCollectFailure = errors.New("collect failure")
	errTestUsageFailure   = errors.New("usage failure")
)

func TestServiceGetStatusSuccess(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()
	service := NewService(log, 5*time.Millisecond)

	service.freqCollector = func(_ context.Context) (*cpufreq.Snapshot, error) {
		return &cpufreq.Snapshot{
			Cores: []cpufreq.CoreFrequency{
				{CoreID: 0, FrequencyHz: 1_500_000_000},
				{CoreID: 1, FrequencyHz: 2_000_000_000},
			},
		}, nil
	}

	service.usageCollector = func(_ context.Context, _ time.Duration, _ bool) ([]float64, error) {
		return []float64{12.5, 87.5}, nil
	}

	service.hostIdentifier = func() string { return "test-host" }
	service.localIPResolver = func(context.Context) string { return "192.0.2.10" }

	req := &proto.StatusRequest{
		ServiceName: "sysmon-vm",
		ServiceType: "cpu-monitor",
		AgentId:     "agent-123",
		PollerId:    "poller-456",
	}

	resp, err := service.GetStatus(context.Background(), req)
	require.NoError(t, err)
	require.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, req.GetServiceName(), resp.ServiceName)
	assert.Equal(t, req.GetServiceType(), resp.ServiceType)

	var payload struct {
		Available    bool `json:"available"`
		ResponseTime int64
		Status       struct {
			Timestamp string `json:"timestamp"`
			HostID    string `json:"host_id"`
			HostIP    string `json:"host_ip"`
			CPUs      []struct {
				CoreID       int32   `json:"core_id"`
				UsagePercent float64 `json:"usage_percent"`
				FrequencyHz  float64 `json:"frequency_hz"`
			} `json:"cpus"`
		} `json:"status"`
	}

	require.NoError(t, json.Unmarshal(resp.GetMessage(), &payload))
	assert.True(t, payload.Available)
	assert.GreaterOrEqual(t, payload.ResponseTime, int64(0))
	assert.NotEmpty(t, payload.Status.Timestamp)
	assert.Equal(t, "test-host", payload.Status.HostID)
	assert.Equal(t, "192.0.2.10", payload.Status.HostIP)
	require.Len(t, payload.Status.CPUs, 2)
	assert.Equal(t, int32(0), payload.Status.CPUs[0].CoreID)
	assert.InDelta(t, 12.5, payload.Status.CPUs[0].UsagePercent, 0.0001)
	assert.InDelta(t, 1_500_000_000.0, payload.Status.CPUs[0].FrequencyHz, 0.1)
	assert.Equal(t, int32(1), payload.Status.CPUs[1].CoreID)
	assert.InDelta(t, 87.5, payload.Status.CPUs[1].UsagePercent, 0.0001)
	assert.InDelta(t, 2_000_000_000.0, payload.Status.CPUs[1].FrequencyHz, 0.1)
}

func TestServiceGetStatusCollectError(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()
	service := NewService(log, 5*time.Millisecond)

	service.freqCollector = func(context.Context) (*cpufreq.Snapshot, error) {
		return nil, errTestCollectFailure
	}

	req := &proto.StatusRequest{
		ServiceName: "sysmon-vm",
		ServiceType: "cpu-monitor",
	}

	resp, err := service.GetStatus(context.Background(), req)
	require.NoError(t, err)
	require.NotNil(t, resp)
	assert.False(t, resp.Available)

	var payload struct {
		Available bool   `json:"available"`
		Error     string `json:"error"`
	}
	require.NoError(t, json.Unmarshal(resp.GetMessage(), &payload))
	assert.False(t, payload.Available)
	assert.Contains(t, payload.Error, "failed to collect cpu frequency data")
}

func TestCollectUsageFallbacks(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()
	service := NewService(log, 5*time.Millisecond)

	t.Run("ErrorReturnsZeroes", func(t *testing.T) {
		service.usageCollector = func(context.Context, time.Duration, bool) ([]float64, error) {
			return nil, errTestUsageFailure
		}

		values := service.collectUsage(context.Background(), 3)
		require.Len(t, values, 3)
		assert.Equal(t, []float64{0, 0, 0}, values)
	})

	t.Run("PadsMissingValues", func(t *testing.T) {
		service.usageCollector = func(context.Context, time.Duration, bool) ([]float64, error) {
			return []float64{10.0, 20.0}, nil
		}

		values := service.collectUsage(context.Background(), 4)
		require.Len(t, values, 4)
		assert.InDelta(t, 10.0, values[0], 0.0001)
		assert.InDelta(t, 20.0, values[1], 0.0001)
		assert.Zero(t, values[2])
		assert.Zero(t, values[3])
	})
}
