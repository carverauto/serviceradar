/*
 * Copyright 2026 Carver Automation Corporation.
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

package agent

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSysmonService_DrainMetrics(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping: requires real CPU sampling")
	}
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Use a very fast sample interval
	cfg := sysmon.DefaultConfig()
	cfg.Enabled = true // Ensure it is enabled
	cfg.SampleInterval = "10ms"

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: &cfg,
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Wait for background collection
	time.Sleep(200 * time.Millisecond)

	// Ensure we have at least one collection
	// In CI/fast environments, the background ticker might be slow to start
	if svc.GetLatestSample() == nil {
		_, err := svc.GetStatus(ctx)
		require.NoError(t, err)
	}

	// Drain
	samples := svc.DrainMetrics()
	assert.NotEmpty(t, samples, "Should have collected at least one sample")

	// Verify sample content
	for _, s := range samples {
		assert.NotEmpty(t, s.Timestamp)
		assert.Equal(t, "test-agent", s.AgentID)
	}

	// Drain again should be empty (or near empty if race condition with collection)
	samples2 := svc.DrainMetrics()
	// It's possible 1 sample collected between calls, but should be much less than first batch
	assert.Less(t, len(samples2), len(samples), "Second drain should have fewer samples")
}
