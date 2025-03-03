//go:build integration
// +build integration

/*-
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
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Integration tests should only run if explicitly enabled
func skipIfNotIntegration(t *testing.T) {
	if os.Getenv("INTEGRATION_TESTS") == "" {
		t.Skip("Skipping integration test - set INTEGRATION_TESTS=1 to run")
	}
}

func TestSocketPool(t *testing.T) {
	skipIfNotIntegration(t)

	t.Run("Concurrent Access", func(t *testing.T) {
		pool := newSocketPool(5, defaultMaxSocketAge, defaultMaxIdleTime)
		defer pool.close()

		var wg sync.WaitGroup
		numGoroutines := 15
		successCount := atomic.Int32{}
		poolFullCount := atomic.Int32{}
		otherErrorCount := atomic.Int32{}

		for i := 0; i < numGoroutines; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()

				conn, release, err := pool.getSocket()
				if err != nil {
					if errors.Is(err, errNoAvailableSocketsInPool) {
						poolFullCount.Add(1)
					} else {
						otherErrorCount.Add(1)
						t.Errorf("Unexpected error: %v", err)
					}
					return
				}

				if conn == nil {
					t.Error("Got nil connection with no error")
					otherErrorCount.Add(1)
					return
				}

				successCount.Add(1)
				// Simulate brief usage without sleep
				_ = conn.SetReadDeadline(time.Now().Add(1 * time.Millisecond))
				release()
			}()
		}

		wg.Wait()

		assert.Equal(t, int32(0), otherErrorCount.Load(), "Should not have any unexpected errors")
		assert.Equal(t, int32(5), successCount.Load(), "Should have exactly maxSockets successful acquisitions")
		assert.Equal(t, int32(numGoroutines-5), poolFullCount.Load(), "Should have pool-full conditions for excess goroutines")
		assert.Equal(t, numGoroutines, int(successCount.Load()+poolFullCount.Load()), "Total attempts should equal number of goroutines")
	})

	t.Run("Socket Recycling", func(t *testing.T) {
		pool := newSocketPool(1, 1*time.Millisecond, defaultMaxIdleTime)
		defer pool.close()

		// Get an initial socket to populate the pool
		conn, release, err := pool.getSocket()
		require.NoError(t, err)
		require.NotNil(t, conn)
		initialCreatedAt := pool.sockets[0].createdAt
		release()

		// Force cleanup to mark the socket as stale
		pool.cleanup()

		// Get a new socket, which should recycle or create a new one
		conn, release, err = pool.getSocket()
		require.NoError(t, err, "Should not error when requesting a new socket after cleanup")
		require.NotNil(t, conn, "Connection should not be nil")
		assert.Equal(t, 1, len(pool.sockets), "Should still have one socket")
		assert.True(t, pool.sockets[0].createdAt.After(initialCreatedAt), "New socket should have a newer creation time")
		assert.False(t, pool.sockets[0].closed.Load(), "Socket should not be closed")
		release()
	})

	t.Run("Pool Closure", func(t *testing.T) {
		pool := newSocketPool(2, defaultMaxSocketAge, defaultMaxIdleTime)
		defer pool.close()

		// Populate with two sockets
		for i := 0; i < 2; i++ {
			conn, release, err := pool.getSocket()
			require.NoError(t, err)
			require.NotNil(t, conn)
			release()
		}

		pool.close()

		for _, entry := range pool.sockets {
			assert.True(t, entry.closed.Load(), "All sockets should be closed")
		}
		assert.Nil(t, pool.cleaner, "Cleaner should be stopped")
		assert.Nil(t, pool.sockets, "Sockets slice should be nil after close")
	})
}

func TestICMPScannerIntegration(t *testing.T) {
	skipIfNotIntegration(t)

	t.Run("Local Host Ping", func(t *testing.T) {
		scanner, err := NewICMPScanner(time.Second, 1, 3)
		require.NoError(t, err)
		defer func(scanner *ICMPScanner, ctx context.Context) {
			err := scanner.Stop(ctx)
			if err != nil {
				t.Errorf("Failed to stop scanner: %v", err)
			}
		}(scanner, context.Background())

		ctx := context.Background()
		targets := []models.Target{
			{
				Host: "127.0.0.1",
				Mode: models.ModeICMP,
			},
		}

		results, err := scanner.Scan(ctx, targets)
		require.NoError(t, err)

		var result models.Result
		select {
		case result = <-results:
		case <-time.After(2 * time.Second):
			t.Fatal("Timeout waiting for scan results")
		}

		assert.True(t, result.Available)
		assert.Greater(t, result.RespTime.Nanoseconds(), int64(0))
		assert.Less(t, result.PacketLoss, float64(100))
	})

	t.Run("Multiple Target Scan", func(t *testing.T) {
		scanner, err := NewICMPScanner(5*time.Second, 2, 3)
		require.NoError(t, err)
		defer func(scanner *ICMPScanner, ctx context.Context) {
			err := scanner.Stop(ctx)
			if err != nil {
				t.Errorf("Failed to stop scanner: %v", err)
			}
		}(scanner, context.Background())

		ctx := context.Background()
		targets := []models.Target{
			{Host: "127.0.0.1", Mode: models.ModeICMP},
			{Host: "localhost", Mode: models.ModeICMP},
			// Add more targets as needed
		}

		results, err := scanner.Scan(ctx, targets)
		require.NoError(t, err)

		count := 0
		timeout := time.After(10 * time.Second)

		for {
			select {
			case result, ok := <-results:
				if !ok {
					// Channel closed, all results received
					return
				}
				count++
				assert.NotEmpty(t, result.Target.Host)
				t.Logf("Result for %s: available=%v responseTime=%v packetLoss=%v",
					result.Target.Host, result.Available, result.RespTime, result.PacketLoss)

			case <-timeout:
				t.Errorf("Timeout waiting for results. Got %d of %d expected results",
					count, len(targets))
				return
			}
		}
	})

	t.Run("Stress Test", func(t *testing.T) {
		scanner, err := NewICMPScanner(30*time.Second, 5, 2)
		require.NoError(t, err)
		defer func(scanner *ICMPScanner, ctx context.Context) {
			err := scanner.Stop(ctx)
			if err != nil {
				t.Errorf("Failed to stop scanner: %v", err)
			}
		}(scanner, context.Background())

		ctx := context.Background()

		// Create a larger number of targets
		targets := make([]models.Target, 20)
		for i := range targets {
			targets[i] = models.Target{
				Host: "127.0.0.1",
				Mode: models.ModeICMP,
			}
		}

		results, err := scanner.Scan(ctx, targets)
		require.NoError(t, err)

		count := 0
		timeout := time.After(60 * time.Second)

		for {
			select {
			case _, ok := <-results:
				if !ok {
					// Verify we got all expected results
					assert.Equal(t, len(targets), count)
					return
				}
				count++

			case <-timeout:
				t.Errorf("Stress test timeout. Got %d of %d expected results",
					count, len(targets))
				return
			}
		}
	})

	t.Run("Resource Cleanup", func(t *testing.T) {
		scanner, err := NewICMPScanner(time.Second, 1, 1)
		require.NoError(t, err)

		// Run a quick scan
		ctx := context.Background()
		results, err := scanner.Scan(ctx, []models.Target{
			{Host: "127.0.0.1", Mode: models.ModeICMP},
		})
		require.NoError(t, err)

		// Drain results
		for range results {
		}

		// Stop the scanner
		err = scanner.Stop(ctx)
		require.NoError(t, err)

		// Verify socket pool is cleaned up
		assert.Nil(t, scanner.socketPool.sockets)
	})
}

func TestSocketPoolStress(t *testing.T) {
	skipIfNotIntegration(t)

	pool := newSocketPool(10, time.Minute, time.Minute)
	defer pool.close()

	const numWorkers = 20
	const iterations = 50

	var wg sync.WaitGroup
	errCh := make(chan error, numWorkers*iterations)

	// Start workers
	for i := 0; i < numWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()

			for j := 0; j < iterations; j++ {
				_, release, err := pool.getSocket()
				if err != nil {
					errCh <- err
					continue
				}

				// Simulate some work
				time.Sleep(time.Duration(1+j%5) * time.Millisecond)

				release()
			}
		}()
	}

	// Wait for all workers to finish
	wg.Wait()
	close(errCh)

	// Check for errors
	var e []error
	for err := range errCh {
		e = append(e, err)
	}

	assert.Empty(t, e, "Expected no errors during stress test")
}
