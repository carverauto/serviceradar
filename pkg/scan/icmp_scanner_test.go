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
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestICMPChecksum(t *testing.T) {
	tests := []struct {
		name     string
		data     []byte
		expected uint16
	}{
		{
			name:     "Empty data",
			data:     []byte{},
			expected: 0xFFFF,
		},
		{
			name:     "Simple ICMP header",
			data:     []byte{8, 0, 0, 0, 0, 1, 0, 1},
			expected: 0xF7FD,
		},
		{
			name:     "Odd length data",
			data:     []byte{8, 0, 0, 0, 0, 1, 0, 1, 0},
			expected: 0xF7FD, // Corrected expected value
		},
	}

	scanner := &ICMPScanner{}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := scanner.calculateChecksum(tt.data)
			if result != tt.expected {
				t.Errorf("calculateChecksum() = %#x, want %#x", result, tt.expected)
			}
		})
	}
}

func TestICMPScanner(t *testing.T) {
	t.Run("Scanner Creation", func(t *testing.T) {
		scanner, err := NewICMPScanner(time.Second, 5, 3)
		require.NoError(t, err)
		require.NotNil(t, scanner)
		require.NotNil(t, scanner.socketPool)
		require.NotNil(t, scanner.bufferPool)
	})

	t.Run("Invalid Parameters", func(t *testing.T) {
		testCases := []struct {
			name        string
			timeout     time.Duration
			concurrency int
			count       int
		}{
			{"Zero timeout", 0, 5, 3},
			{"Zero concurrency", time.Second, 0, 3},
			{"Zero count", time.Second, 5, 0},
			{"Negative timeout", -time.Second, 5, 3},
			{"Negative concurrency", time.Second, -5, 3},
			{"Negative count", time.Second, 5, -3},
		}

		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				scanner, err := NewICMPScanner(tc.timeout, tc.concurrency, tc.count)
				require.Error(t, err)
				require.Nil(t, scanner)
			})
		}
	})

	t.Run("Buffer Pool", func(t *testing.T) {
		pool := newBufferPool(1500)

		// Get buffer
		buf := pool.get()
		require.NotNil(t, buf)
		require.Len(t, buf, 1500)

		// Return buffer
		pool.put(buf)

		// Get another buffer (should reuse the one we put back)
		buf2 := pool.get()
		require.NotNil(t, buf2)
		require.Len(t, buf2, 1500)
	})
}

func TestICMPScannerGracefulShutdown(t *testing.T) {
	t.Parallel()

	scanner, err := NewICMPScanner(100*time.Millisecond, 5, 3)
	require.NoError(t, err)

	// Create a parent context with timeout
	parentCtx, parentCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer parentCancel()

	// Create scan context as child of parent
	ctx, cancel := context.WithTimeout(parentCtx, 500*time.Millisecond)
	defer cancel()

	// Start scan
	resultsCh, err := scanner.Scan(ctx, []models.Target{
		{Host: "127.0.0.1", Mode: models.ModeICMP},
	})
	require.NoError(t, err)

	// Track results in background
	var results []models.Result

	resultsDone := make(chan struct{})

	go func() {
		defer close(resultsDone)

		for result := range resultsCh {
			t.Logf("Received result: %+v", result)
			results = append(results, result)
		}

		t.Log("Results channel closed")
	}()

	// Wait a short time for some results
	select {
	case <-time.After(100 * time.Millisecond):
		// Continue with shutdown
	case <-parentCtx.Done():
		t.Fatal("Parent context timed out")
	}

	// Create stop context
	stopCtx, stopCancel := context.WithTimeout(parentCtx, 500*time.Millisecond)
	defer stopCancel()

	// Cancel scan context to trigger shutdown
	cancel()

	// Stop the scanner
	err = scanner.Stop(stopCtx)
	require.NoError(t, err, "Stop should not return error")

	// Wait for results channel to close
	select {
	case <-resultsDone:
		t.Log("Results channel closed successfully")
	case <-parentCtx.Done():
		t.Fatal("Parent context timed out waiting for results")
	}

	// Verify we got at least one result
	if len(results) > 0 {
		require.Equal(t, "127.0.0.1", results[0].Target.Host)
	}
}

func TestAtomicOperations(t *testing.T) {
	t.Run("Socket Use Counter", func(t *testing.T) {
		entry := &socketEntry{}

		var wg sync.WaitGroup

		// Simulate concurrent increments
		for i := 0; i < 100; i++ {
			wg.Add(1)

			go func() {
				defer wg.Done()
				entry.inUse.Add(1)
			}()
		}

		// Simulate concurrent decrements
		for i := 0; i < 100; i++ {
			wg.Add(1)

			go func() {
				defer wg.Done()
				entry.inUse.Add(-1)
			}()
		}

		wg.Wait()

		// Final count should be 0
		assert.Equal(t, int32(0), entry.inUse.Load())
	})
}
