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

package sweeper

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// reconfiguringScanner reports every target available and, on its first scan,
// runs onFirstScan while the sweep that called it is still generating targets.
type reconfiguringScanner struct {
	once        sync.Once
	onFirstScan func()
}

func (s *reconfiguringScanner) Scan(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
	s.once.Do(s.onFirstScan)

	results := make(chan models.Result)
	batch := append([]models.Target(nil), targets...)

	go func() {
		defer close(results)

		for _, target := range batch {
			now := time.Now()
			select {
			case results <- models.Result{Target: target, Available: true, FirstSeen: now, LastSeen: now}:
			case <-ctx.Done():
				return
			}
		}
	}()

	return results, nil
}

func (*reconfiguringScanner) Stop() error { return nil }

func newPlannedRunSweeper(t *testing.T, config *models.Config) *NetworkSweeper {
	t.Helper()

	log := logger.NewTestLogger()
	processor := NewBaseProcessor(config, log)
	store := NewInMemoryStore(processor, log, WithoutPreallocation())

	sweeper, err := NewNetworkSweeper(config, store, processor, nil, log)
	require.NoError(t, err)

	return sweeper
}

// A planned execution probes exactly its spec. The sweep here is large enough
// to take the batched path, which generates targets while earlier batches are
// already scanning; an UpdateConfig that lands then must not change the modes,
// ports or networks of the rest of the run.
func TestRunPlannedWithObserverIgnoresConfigUpdateDuringRun(t *testing.T) {
	config := &models.Config{
		Networks:   []string{"192.0.2.0/24"},
		Ports:      []int{80},
		SweepModes: []models.SweepMode{models.ModeTCPConnect},
		Interval:   time.Minute,
		Timeout:    time.Second,
	}
	sweeper := newPlannedRunSweeper(t, config)

	updated := make(chan error, 1)
	scanner := &reconfiguringScanner{onFirstScan: func() {
		updated <- sweeper.UpdateConfig(&models.Config{
			Networks:   []string{"198.51.100.0/24"},
			Ports:      []int{8443},
			SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCPConnect},
		})
	}}
	sweeper.mu.Lock()
	sweeper.icmpScanner = scanner
	sweeper.tcpScanner = scanner
	sweeper.tcpConnectScanner = scanner
	sweeper.mu.Unlock()

	// 2^17 addresses: more than one target batch.
	plan := netip.MustParsePrefix("198.18.0.0/15")
	spec := RunSpec{Networks: []string{plan.String()}, Modes: []models.SweepMode{models.ModeICMP}}

	var mu sync.Mutex
	observed := make(map[models.SweepMode]int)
	var outside []string
	observer := func(_ context.Context, result *models.Result) error {
		mu.Lock()
		defer mu.Unlock()
		observed[result.Target.Mode]++
		if addr, err := netip.ParseAddr(result.Target.Host); err != nil || !plan.Contains(addr) {
			outside = append(outside, result.Target.Host)
		}
		return nil
	}

	require.NoError(t, sweeper.RunPlannedWithObserver(context.Background(), "exec-planned", spec, observer))
	require.NoError(t, <-updated, "the config update must land during the run")

	require.Equal(t, map[models.SweepMode]int{models.ModeICMP: 1 << 17}, observed)
	require.Empty(t, outside)
	require.Equal(t, []int{8443}, sweeper.GetConfig().Ports, "the update applies after the run")
}

// The plan, not the config, decides which scanners a planned run needs: a
// TCP-connect plan runs on a sweeper configured for ICMP only.
func TestRunPlannedWithObserverRunsModesTheConfigLacks(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	port := listener.Addr().(*net.TCPAddr).Port

	sweeper := newPlannedRunSweeper(t, &models.Config{
		Networks:   []string{"192.0.2.0/24"},
		SweepModes: []models.SweepMode{models.ModeICMP},
		Interval:   time.Minute,
		Timeout:    time.Second,
	})

	var results []models.Result
	var mu sync.Mutex
	err = sweeper.RunPlannedWithObserver(context.Background(), "exec-connect",
		RunSpec{Networks: []string{"127.0.0.1/32"}, Modes: []models.SweepMode{models.ModeTCPConnect}, Ports: []int{port}},
		func(_ context.Context, result *models.Result) error {
			mu.Lock()
			defer mu.Unlock()
			results = append(results, *result)
			return nil
		})
	require.NoError(t, err)

	require.Len(t, results, 1)
	require.Equal(t, models.ModeTCPConnect, results[0].Target.Mode)
	require.Equal(t, port, results[0].Target.Port)
	require.True(t, results[0].Available)
}

func TestRunPlannedWithObserverRefusesAnEmptySpecOrNoObserver(t *testing.T) {
	sweeper := newPlannedRunSweeper(t, &models.Config{Interval: time.Minute})
	observer := func(context.Context, *models.Result) error { return nil }

	require.ErrorIs(t, sweeper.RunPlannedWithObserver(context.Background(), "e", RunSpec{Modes: []models.SweepMode{models.ModeICMP}}, observer), errEmptyRunSpec)
	require.ErrorIs(t, sweeper.RunPlannedWithObserver(context.Background(), "e", RunSpec{Networks: []string{"192.0.2.0/32"}}, observer), errEmptyRunSpec)
	require.ErrorIs(t, sweeper.RunPlannedWithObserver(context.Background(), "e",
		RunSpec{Networks: []string{"192.0.2.0/32"}, Modes: []models.SweepMode{models.ModeICMP}}, nil), errPlannedRunObserver)
}
