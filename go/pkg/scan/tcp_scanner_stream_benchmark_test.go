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

package scan

import (
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func BenchmarkTCPSweeperScanStreamSyntheticFleet(b *testing.B) {
	for _, tc := range []struct {
		name    string
		targets int
	}{
		{name: "50k_hosts_representative_ports", targets: 50000},
		{name: "1m_candidates", targets: 1000000},
	} {
		b.Run(tc.name, func(b *testing.B) {
			const concurrency = 500

			var activeDials int64
			var maxActiveDials int64

			scanner := NewTCPSweeper(5*time.Second, concurrency, logger.NewTestLogger())
			scanner.dialContext = func(_ context.Context, _, _ string) (net.Conn, error) {
				current := atomic.AddInt64(&activeDials, 1)
				recordMaxInt64(&maxActiveDials, current)
				atomic.AddInt64(&activeDials, -1)

				return &mockConn{}, nil
			}

			hosts := representativeBenchmarkHosts()

			b.ReportAllocs()
			b.ResetTimer()

			for i := 0; i < b.N; i++ {
				start := time.Now()
				scanned := runSyntheticTCPConnectStreamBenchmark(b, scanner, hosts, tc.targets)
				elapsed := time.Since(start)

				b.ReportMetric(float64(scanned)/elapsed.Seconds(), "targets/sec")
			}

			b.ReportMetric(float64(atomic.LoadInt64(&maxActiveDials)), "max_active_dials")
		})
	}
}

func runSyntheticTCPConnectStreamBenchmark(
	b *testing.B,
	scanner *TCPSweeper,
	hosts []string,
	targetCount int,
) int {
	b.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	targets := make(chan models.Target, scanner.concurrency*defaultConcurrencyMultiplier)
	results, errs, err := scanner.ScanStream(ctx, targets, StreamOptions{
		TargetEstimate: targetCount,
	})
	if err != nil {
		b.Fatalf("ScanStream() error = %v", err)
	}

	go func() {
		defer close(targets)

		for i := 0; i < targetCount; i++ {
			targets <- models.Target{
				Host: hosts[i%len(hosts)],
				Port: representativeBannerPort(i),
				Mode: models.ModeTCPConnect,
			}
		}
	}()

	var resultCount int
	for range results {
		resultCount++
	}

	for err := range errs {
		if err != nil {
			b.Fatalf("ScanStream() async error = %v", err)
		}
	}

	if resultCount != targetCount {
		b.Fatalf("ScanStream() emitted %d results, want %d", resultCount, targetCount)
	}

	return resultCount
}

func representativeBenchmarkHosts() []string {
	return []string{
		"192.0.2.1",
		"192.0.2.2",
		"192.0.2.3",
		"192.0.2.4",
		"192.0.2.5",
		"192.0.2.6",
		"192.0.2.7",
		"192.0.2.8",
		"192.0.2.9",
		"192.0.2.10",
		"192.0.2.11",
		"192.0.2.12",
		"192.0.2.13",
		"192.0.2.14",
		"192.0.2.15",
		"192.0.2.16",
	}
}

func representativeBannerPort(i int) int {
	ports := [...]int{22, 80, 139, 445, 3389, 21, 23, 25, 53, 123}

	return ports[i%len(ports)]
}
