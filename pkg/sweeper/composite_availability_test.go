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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const testHost = "192.168.1.1"

// saveAndCheckAvailability is a test helper that prunes the store, saves the given results,
// retrieves the sweep summary, and asserts the single host's availability matches wantAvailable.
func saveAndCheckAvailability(
	t *testing.T,
	store Store,
	ctx context.Context,
	results []*models.Result,
	wantAvailable bool,
	msg string,
) {
	t.Helper()

	require.NoError(t, store.PruneResults(ctx, 0))

	for _, r := range results {
		require.NoError(t, store.SaveResult(ctx, r))
	}

	summary, err := store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, summary.Hosts, 1)

	assert.Equal(t, wantAvailable, summary.Hosts[0].Available, msg)
}

// newTestStore creates an InMemoryStore configured for testing.
func newTestStore(t *testing.T) Store {
	t.Helper()

	log := logger.NewTestLogger()
	cfg := &models.Config{SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP}}
	processor := NewBaseProcessor(cfg, log)
	store := NewInMemoryStore(processor, log, WithoutPreallocation(), WithCleanupInterval(0))

	if closer, ok := store.(interface{ Close() error }); ok {
		t.Cleanup(func() { _ = closer.Close() })
	}

	return store
}

// TestCompositeAvailability_InMemoryStore tests the critical business rule:
// A device is available if ANY check (ICMP or TCP on any port) succeeds.
// This tests through the InMemoryStore which is the actual code path that
// builds the host summary sent to the Elixir platform.
func TestCompositeAvailability_InMemoryStore(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	ctx := context.Background()
	now := time.Now()

	t.Run("ICMP fails, TCP 22 fails, TCP 80 succeeds = device available", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: true, LastSeen: now},
		}, true, "Device must be available when TCP port 80 succeeds, even if ICMP and TCP 22 fail")
	})

	t.Run("all checks fail = device unavailable", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		}, false, "Device must be unavailable when all checks fail")
	})

	t.Run("ICMP succeeds, all TCP fails = device available", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: true, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		}, true, "Device must be available when ICMP succeeds, even if all TCP ports fail")
	})

	t.Run("ICMP fails, one TCP out of many succeeds = device available", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: true, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 8080, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 8443, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		}, true, "Device must be available when any single TCP port succeeds")
	})

	t.Run("TCP-only mode, some ports succeed = device available", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: true, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		}, true, "Device must be available in TCP-only mode when any port succeeds")
	})

	t.Run("TCP-only mode, all ports fail = device unavailable", func(t *testing.T) {
		saveAndCheckAvailability(t, store, ctx, []*models.Result{
			{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
			{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		}, false, "Device must be unavailable in TCP-only mode when all ports fail")
	})
}

// TestCompositeAvailability_MultipleHosts verifies that availability is
// computed independently per host.
func TestCompositeAvailability_MultipleHosts(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	ctx := context.Background()
	now := time.Now()

	require.NoError(t, store.PruneResults(ctx, 0))

	// Host A: ICMP fails, TCP 80 succeeds -> available
	// Host B: all checks fail -> unavailable
	// Host C: ICMP succeeds, no TCP -> available
	results := []*models.Result{
		// Host A
		{Target: models.Target{Host: "10.0.0.1", Mode: models.ModeICMP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: "10.0.0.1", Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: "10.0.0.1", Port: 80, Mode: models.ModeTCP}, Available: true, LastSeen: now},
		// Host B
		{Target: models.Target{Host: "10.0.0.2", Mode: models.ModeICMP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: "10.0.0.2", Port: 22, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: "10.0.0.2", Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		// Host C
		{Target: models.Target{Host: "10.0.0.3", Mode: models.ModeICMP}, Available: true, LastSeen: now},
	}

	for _, r := range results {
		require.NoError(t, store.SaveResult(ctx, r))
	}

	summary, err := store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, summary.Hosts, 3)

	hostAvailability := make(map[string]bool)
	for _, h := range summary.Hosts {
		hostAvailability[h.Host] = h.Available
	}

	assert.True(t, hostAvailability["10.0.0.1"], "Host A must be available (TCP 80 succeeds)")
	assert.False(t, hostAvailability["10.0.0.2"], "Host B must be unavailable (all checks fail)")
	assert.True(t, hostAvailability["10.0.0.3"], "Host C must be available (ICMP succeeds)")
	assert.Equal(t, 2, summary.AvailableHosts, "Two hosts should be counted as available")
}

// TestCompositeAvailability_PruneResetsState verifies that pruning clears
// stale availability and the next sweep's results are authoritative.
func TestCompositeAvailability_PruneResetsState(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	ctx := context.Background()

	// Sweep 1: device is available (ICMP succeeds)
	require.NoError(t, store.SaveResult(ctx, &models.Result{
		Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: true, LastSeen: time.Now(),
	}))

	summary, err := store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, summary.Hosts, 1)
	assert.True(t, summary.Hosts[0].Available, "Sweep 1: device should be available")

	// Prune (simulates start of new sweep)
	require.NoError(t, store.PruneResults(ctx, 0))

	// Sweep 2: device is unavailable (ICMP fails, no TCP succeeds)
	now := time.Now()
	require.NoError(t, store.SaveResult(ctx, &models.Result{
		Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: false, LastSeen: now,
	}))
	require.NoError(t, store.SaveResult(ctx, &models.Result{
		Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now,
	}))

	summary, err = store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, summary.Hosts, 1)
	assert.False(t, summary.Hosts[0].Available,
		"Sweep 2: device must be unavailable - prune should have cleared old ICMP success")
}

// TestCompositeAvailability_PortResultsConsistency verifies that the port results
// list in the host summary correctly reflects which ports were open.
func TestCompositeAvailability_PortResultsConsistency(t *testing.T) {
	t.Parallel()

	store := newTestStore(t)
	ctx := context.Background()
	now := time.Now()

	require.NoError(t, store.PruneResults(ctx, 0))

	// ICMP fails, TCP 22 succeeds, TCP 80 fails, TCP 443 succeeds
	results := []*models.Result{
		{Target: models.Target{Host: testHost, Mode: models.ModeICMP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: testHost, Port: 22, Mode: models.ModeTCP}, Available: true, LastSeen: now},
		{Target: models.Target{Host: testHost, Port: 80, Mode: models.ModeTCP}, Available: false, LastSeen: now},
		{Target: models.Target{Host: testHost, Port: 443, Mode: models.ModeTCP}, Available: true, LastSeen: now},
	}

	for _, r := range results {
		require.NoError(t, store.SaveResult(ctx, r))
	}

	summary, err := store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, summary.Hosts, 1)

	h := summary.Hosts[0]
	assert.True(t, h.Available, "Device should be available (TCP 22 and 443 succeed)")

	// Verify port results only contain open ports
	openPorts := make(map[int]bool)
	for _, p := range h.PortResults {
		openPorts[p.Port] = p.Available
	}

	assert.True(t, openPorts[22], "Port 22 should be in results as available")
	assert.True(t, openPorts[443], "Port 443 should be in results as available")
	// Port 80 should NOT be in port_results (only open ports are recorded)
	_, has80 := openPorts[80]
	assert.False(t, has80, "Port 80 should NOT be in port_results (it's closed)")

	// Verify ICMP status
	require.NotNil(t, h.ICMPStatus)
	assert.False(t, h.ICMPStatus.Available, "ICMP should show as unavailable")
}
