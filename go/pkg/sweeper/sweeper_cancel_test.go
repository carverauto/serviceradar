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
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// stubScanner reports every target available. With hold set it keeps the
// stream open after the last result until the scan context ends, like a scan
// still waiting on slow targets.
type stubScanner struct {
	hold      bool
	delivered chan struct{}
	once      sync.Once
}

func newStubScanner(hold bool) *stubScanner {
	return &stubScanner{hold: hold, delivered: make(chan struct{})}
}

func (s *stubScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	results := make(chan models.Result)

	go func() {
		defer close(results)

		for _, target := range targets {
			now := time.Now()

			select {
			case results <- models.Result{Target: target, Available: true, FirstSeen: now, LastSeen: now}:
			case <-ctx.Done():
				return
			}
		}

		// The sends are unbuffered, so the sweeper has received every result.
		s.once.Do(func() { close(s.delivered) })

		if s.hold {
			<-ctx.Done()
		}
	}()

	return results, nil
}

func (*stubScanner) Stop() error {
	return nil
}

// newCancelTestSweeper sweeps one TCP-connect target through scanner, so no
// packets leave the host.
func newCancelTestSweeper(t *testing.T, scanner *stubScanner) *NetworkSweeper {
	t.Helper()

	config := &models.Config{
		Networks:   []string{"192.0.2.10/32"},
		Ports:      []int{80},
		SweepModes: []models.SweepMode{models.ModeTCPConnect},
		Interval:   time.Minute,
		Timeout:    time.Second,
	}
	log := logger.NewTestLogger()
	processor := NewBaseProcessor(config, log)
	store := NewInMemoryStore(processor, log, WithoutPreallocation())

	sweeper, err := NewNetworkSweeper(config, store, processor, nil, log)
	require.NoError(t, err)

	setTCPConnectScanner(sweeper, scanner)

	return sweeper
}

func setTCPConnectScanner(sweeper *NetworkSweeper, scanner *stubScanner) {
	sweeper.mu.Lock()
	sweeper.tcpConnectScanner = scanner
	sweeper.mu.Unlock()
}

func TestNetworkSweeper_CancelRunAbortsInFlightRunWithoutPublishing(t *testing.T) {
	scanner := newStubScanner(true)
	sweeper := newCancelTestSweeper(t, scanner)
	ctx := context.Background()

	completedAt := time.Now().Add(-time.Minute)
	sweeper.mu.Lock()
	sweeper.lastSweep = completedAt
	sweeper.lastSummary = &models.SweepSummary{
		TotalHosts:     1,
		AvailableHosts: 1,
		LastSweep:      completedAt.Unix(),
		Hosts:          []models.HostResult{{Host: "192.0.2.20", Available: true}},
	}
	sweeper.mu.Unlock()

	runErr := make(chan error, 1)
	go func() { runErr <- sweeper.RunOnce(ctx) }()

	select {
	case <-scanner.delivered:
	case <-time.After(5 * time.Second):
		t.Fatal("sweep never delivered its first result")
	}

	require.True(t, sweeper.CancelRun(), "an in-flight run must report cancelled")
	require.True(t, sweeper.CancelRun(), "a repeated cancel of the same run is idempotent")

	select {
	case err := <-runErr:
		require.ErrorIs(t, err, ErrSweepCancelled)
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled run kept scanning")
	}

	raw, err := sweeper.store.GetSweepSummary(ctx)
	require.NoError(t, err)
	require.Len(t, raw.Hosts, 1)
	require.Equal(t, "192.0.2.10", raw.Hosts[0].Host, "the aborted run should have left a partial result")

	// The agent streams results only when LastSweep advances; the aborted run
	// must leave it, and the summary it serves, at the last completed sweep.
	sweeper.mu.RLock()
	lastSweep := sweeper.lastSweep
	sweeper.mu.RUnlock()
	assert.True(t, lastSweep.Equal(completedAt), "an aborted run must not publish")

	status, err := sweeper.GetStatus(ctx)
	require.NoError(t, err)
	assert.Equal(t, completedAt.Unix(), status.LastSweep)
	require.Len(t, status.Hosts, 1)
	assert.Equal(t, "192.0.2.20", status.Hosts[0].Host)
	assert.False(t, sweeper.WasCancelledSweep(), "a cancel request is not a scan timeout")

	assert.False(t, sweeper.CancelRun(), "nothing is running once the run has stopped")

	setTCPConnectScanner(sweeper, newStubScanner(false))
	require.NoError(t, sweeper.RunOnce(ctx))

	status, err = sweeper.GetStatus(ctx)
	require.NoError(t, err)
	assert.Greater(t, status.LastSweep, completedAt.Unix())
	require.Len(t, status.Hosts, 1)
	assert.Equal(t, "192.0.2.10", status.Hosts[0].Host, "the next completed sweep is served again")
}

// TestNetworkSweeper_CancelRunRacesRunCompletion lands cancels across a run's
// whole lifetime. Whichever way each race resolves, a run that reported
// cancelled must not publish, and one that did not must.
func TestNetworkSweeper_CancelRunRacesRunCompletion(t *testing.T) {
	sweeper := newCancelTestSweeper(t, newStubScanner(false))
	ctx := context.Background()

	const runs = 200

	cancelledRuns := 0

	for i := 0; i < runs; i++ {
		setTCPConnectScanner(sweeper, newStubScanner(false))

		sweeper.mu.RLock()
		before := sweeper.lastSweep
		sweeper.mu.RUnlock()

		runErr := make(chan error, 1)
		go func() { runErr <- sweeper.RunOnce(ctx) }()

		time.Sleep(time.Duration(i%10) * 10 * time.Microsecond)

		cancelled := sweeper.CancelRun()
		err := <-runErr

		sweeper.mu.RLock()
		published := !sweeper.lastSweep.Equal(before)
		pending := sweeper.partialRunPending
		sweeper.mu.RUnlock()

		if cancelled {
			cancelledRuns++

			require.ErrorIs(t, err, ErrSweepCancelled, "run %d", i)
			require.False(t, published, "run %d reported cancelled but published", i)
			require.True(t, pending, "run %d", i)

			continue
		}

		require.NoError(t, err, "run %d", i)
		require.True(t, published, "run %d was not cancelled but did not publish", i)
		require.False(t, pending, "run %d", i)
	}

	t.Logf("%d of %d runs were cancelled in flight", cancelledRuns, runs)
}
