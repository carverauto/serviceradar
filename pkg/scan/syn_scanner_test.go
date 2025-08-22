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
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
)

func TestNewSYNScanner(t *testing.T) {
	// Check if running as root
	isRoot := os.Geteuid() == 0
	
	tests := []struct {
		name        string
		timeout     time.Duration
		concurrency int
		wantTimeout time.Duration
		wantConc    int
	}{
		{
			name:        "default values",
			timeout:     0,
			concurrency: 0,
			wantTimeout: 1 * time.Second,
			wantConc:    1000,
		},
		{
			name:        "custom values",
			timeout:     500 * time.Millisecond,
			concurrency: 100,
			wantTimeout: 500 * time.Millisecond,
			wantConc:    100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := logger.NewTestLogger()
			scanner, err := NewSYNScanner(tt.timeout, tt.concurrency, log)

			if !isRoot {
				// Without root privileges, should fail
				assert.Error(t, err)
				assert.Nil(t, scanner)
				t.Logf("SYN scanner correctly failed without root privileges: %v", err)
				return
			}

			// With root privileges, should succeed
			assert.NoError(t, err)
			assert.NotNil(t, scanner)
			assert.Equal(t, tt.wantTimeout, scanner.timeout)
			assert.Equal(t, tt.wantConc, scanner.concurrency)

			// Clean up
			err = scanner.Stop(context.Background())
			assert.NoError(t, err)
		})
	}
}

func TestSYNScanner_Scan_EmptyTargets(t *testing.T) {
	log := logger.NewTestLogger()
	
	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer scanner.Stop(context.Background())

	ctx := context.Background()
	targets := []models.Target{}

	results, err := scanner.Scan(ctx, targets)
	assert.NoError(t, err)
	assert.NotNil(t, results)

	// Should get no results from empty channel
	resultSlice := drainChannel(results)
	assert.Empty(t, resultSlice)
}

func TestSYNScanner_Scan_NonTCPTargets(t *testing.T) {
	log := logger.NewTestLogger()
	
	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer scanner.Stop(context.Background())

	ctx := context.Background()
	targets := []models.Target{
		{Host: "127.0.0.1", Mode: models.ModeICMP},
		{Host: "127.0.0.1", Mode: models.ModeICMP},
	}

	results, err := scanner.Scan(ctx, targets)
	assert.NoError(t, err)
	assert.NotNil(t, results)

	// Should get no results since no TCP targets
	resultSlice := drainChannel(results)
	assert.Empty(t, resultSlice)
}

func TestSYNScanner_Scan_TCPTargets(t *testing.T) {
	log := logger.NewTestLogger()
	
	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer scanner.Stop(context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	targets := []models.Target{
		{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},   // SSH - likely open
		{Host: "127.0.0.1", Port: 9999, Mode: models.ModeTCP}, // High port - likely closed
		{Host: "127.0.0.1", Mode: models.ModeICMP},            // ICMP - should be filtered out
	}

	results, err := scanner.Scan(ctx, targets)
	assert.NoError(t, err)
	assert.NotNil(t, results)

	// Should get results for 2 TCP targets only
	resultSlice := drainChannel(results)
	assert.Len(t, resultSlice, 2)

	// Verify both results are for TCP targets
	for _, result := range resultSlice {
		assert.Equal(t, models.ModeTCP, result.Target.Mode)
		assert.Equal(t, "127.0.0.1", result.Target.Host)
		assert.Contains(t, []int{22, 9999}, result.Target.Port)
	}
}

func TestSYNScanner_ConcurrentScanning(t *testing.T) {
	log := logger.NewTestLogger()
	
	// Create SYN scanner (should work with root)
	scanner, err := NewSYNScanner(100*time.Millisecond, 50, log)
	if err != nil {
		t.Skip("SYN scanner requires root privileges")
		return
	}
	defer scanner.Stop(context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Create many targets to test concurrency
	var targets []models.Target
	for port := 20; port < 50; port++ {
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	start := time.Now()
	results, err := scanner.Scan(ctx, targets)
	assert.NoError(t, err)

	resultSlice := drainChannel(results)
	duration := time.Since(start)

	// Should complete faster than sequential scanning would take
	// With 30 targets and 100ms timeout each, sequential would take 3+ seconds
	// Concurrent should be much faster
	assert.Less(t, duration, 3*time.Second)
	assert.Len(t, resultSlice, len(targets))

	t.Logf("Scanned %d targets in %v (avg: %v per target)", 
		len(targets), duration, duration/time.Duration(len(targets)))
}

func TestSYNScanner_ContextCancellation(t *testing.T) {
	log := logger.NewTestLogger()
	
	// Create SYN scanner with very short timeout for faster cancellation
	scanner, err := NewSYNScanner(100*time.Millisecond, 10, log)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer scanner.Stop(context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	targets := []models.Target{
		{Host: "192.0.2.1", Port: 80, Mode: models.ModeTCP}, // Test IP that won't respond
	}

	results, err := scanner.Scan(ctx, targets)
	assert.NoError(t, err)

	// Cancel context after a short delay to allow scan to start
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	// Should complete due to cancellation or timeout
	start := time.Now()
	resultSlice := drainChannel(results)
	duration := time.Since(start)

	assert.Less(t, duration, 1*time.Second) // Should complete quickly due to short timeouts
	// May get 0 or 1 results depending on timing
	assert.LessOrEqual(t, len(resultSlice), 1)
}

// Helper function to drain all results from a channel
func drainChannel(ch <-chan models.Result) []models.Result {
	var results []models.Result
	for result := range ch {
		results = append(results, result)
	}
	return results
}