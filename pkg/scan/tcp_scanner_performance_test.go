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

package scan

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTCPScanner_HighConcurrency(t *testing.T) {
	log := logger.NewTestLogger()

	tests := []struct {
		name        string
		concurrency int
		targetCount int
		timeout     time.Duration
	}{
		{
			name:        "high concurrency small batch",
			concurrency: 500,
			targetCount: 50,
			timeout:     2 * time.Second,
		},
		{
			name:        "high concurrency medium batch",
			concurrency: 500,
			targetCount: 200,
			timeout:     2 * time.Second,
		},
		{
			name:        "very high concurrency",
			concurrency: 1000,
			targetCount: 100,
			timeout:     1 * time.Second,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scanner := NewTCPSweeper(tt.timeout, tt.concurrency, log)

			// Create targets scanning localhost on various ports
			var targets []models.Target
			for i := 0; i < tt.targetCount; i++ {
				port := 10000 + i // Use high ports that are likely closed
				targets = append(targets, models.Target{
					Host: "127.0.0.1",
					Port: port,
					Mode: models.ModeTCP,
				})
			}

			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			start := time.Now()
			results, err := scanner.Scan(ctx, targets)
			require.NoError(t, err)

			// Drain all results
			var resultCount int
			for range results {
				resultCount++
			}

			duration := time.Since(start)

			assert.Equal(t, tt.targetCount, resultCount)

			// With high concurrency, should complete much faster than sequential
			maxSequentialTime := time.Duration(tt.targetCount) * tt.timeout
			assert.Less(t, duration, maxSequentialTime/10) // Should be at least 10x faster

			t.Logf("Scanned %d targets with %d workers in %v (throughput: %.1f targets/sec)",
				tt.targetCount, tt.concurrency, duration,
				float64(tt.targetCount)/duration.Seconds())
		})
	}
}

func TestTCPScanner_OptimizedDefaults(t *testing.T) {
	log := logger.NewTestLogger()

	// Test that new defaults are applied
	scanner := NewTCPSweeper(0, 0, log)

	// Should use optimized defaults
	assert.Equal(t, 500, scanner.concurrency)
	assert.Equal(t, 5*time.Second, scanner.timeout)
}

func TestTCPScanner_FastTimeout(t *testing.T) {
	log := logger.NewTestLogger()

	// Test with very fast timeout for closed ports
	scanner := NewTCPSweeper(100*time.Millisecond, 50, log)

	// Scan ports that should be closed/filtered
	var targets []models.Target
	for port := 12345; port < 12355; port++ {
		targets = append(targets, models.Target{
			Host: "127.0.0.1", // Localhost
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	start := time.Now()
	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	var resultCount int
	var successCount int

	for result := range results {
		resultCount++
		if result.Available {
			successCount++
		}
	}

	duration := time.Since(start)

	assert.Equal(t, len(targets), resultCount)

	// Most ports should be closed/filtered, so few successes expected
	assert.LessOrEqual(t, successCount, resultCount/2)

	// Should complete quickly due to fast timeouts
	assert.Less(t, duration, 2*time.Second)

	t.Logf("Fast timeout scan: %d targets in %v, %d successful",
		resultCount, duration, successCount)
}

func TestTCPScanner_MixedPorts(t *testing.T) {
	log := logger.NewTestLogger()
	scanner := NewTCPSweeper(1*time.Second, 100, log)

	// Mix of likely open and closed ports
	targets := []models.Target{
		{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},    // SSH - likely open
		{Host: "127.0.0.1", Port: 80, Mode: models.ModeTCP},    // HTTP - may be open
		{Host: "127.0.0.1", Port: 443, Mode: models.ModeTCP},   // HTTPS - may be open
		{Host: "127.0.0.1", Port: 12345, Mode: models.ModeTCP}, // Random - likely closed
		{Host: "127.0.0.1", Port: 54321, Mode: models.ModeTCP}, // Random - likely closed
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	var openPorts []int
	var closedPorts []int
	var resultCount int

	for result := range results {
		resultCount++
		if result.Available {
			openPorts = append(openPorts, result.Target.Port)
		} else {
			closedPorts = append(closedPorts, result.Target.Port)
		}

		// Verify result has proper timing
		assert.GreaterOrEqual(t, result.RespTime, time.Duration(0))
		assert.Equal(t, "127.0.0.1", result.Target.Host)
		assert.Equal(t, models.ModeTCP, result.Target.Mode)
	}

	assert.Equal(t, len(targets), resultCount)
	t.Logf("Open ports: %v, Closed ports: %v", openPorts, closedPorts)
}

// Benchmark high-concurrency TCP scanning
func BenchmarkTCPScanner_HighConcurrency(b *testing.B) {
	log := logger.NewTestLogger()
	scanner := NewTCPSweeper(500*time.Millisecond, 500, log)

	// Create a realistic number of targets
	var targets []models.Target
	for i := 0; i < 1000; i++ {
		port := 10000 + i
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)

		results, err := scanner.Scan(ctx, targets)
		require.NoError(b, err)

		// Drain results
		for result := range results {
			_ = result // Consume all results
		}

		cancel()
	}
}

// Benchmark comparing old vs new concurrency
func BenchmarkTCPScanner_ConcurrencyComparison(b *testing.B) {
	log := logger.NewTestLogger()

	tests := []struct {
		name        string
		concurrency int
	}{
		{"old_concurrency", 20},
		{"new_concurrency", 500},
	}

	// Fixed set of targets
	var targets []models.Target

	for i := 0; i < 100; i++ {
		port := 15000 + i
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	for _, tt := range tests {
		b.Run(tt.name, func(b *testing.B) {
			scanner := NewTCPSweeper(500*time.Millisecond, tt.concurrency, log)

			b.ResetTimer()

			for i := 0; i < b.N; i++ {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)

				results, err := scanner.Scan(ctx, targets)
				require.NoError(b, err)

				// Drain results
				for result := range results {
					_ = result // Consume all results
				}

				cancel()
			}
		})
	}
}
