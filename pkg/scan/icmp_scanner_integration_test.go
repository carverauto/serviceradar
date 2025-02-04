//go:build icmp_integration_test

// Package scan pkg/scan/icmp_scanner_integration_test.go
package scan

import (
	"context"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Integration tests should only run if explicitly enabled
func skipIfNotIntegration(t *testing.T) {
	if os.Getenv("INTEGRATION_TESTS") == "" {
		t.Skip("Skipping integration test - set INTEGRATION_TESTS=1 to run")
	}
}

func TestICMPScannerIntegration(t *testing.T) {
	skipIfNotIntegration(t)

	t.Run("Local Host Ping", func(t *testing.T) {
		scanner, err := NewICMPScanner(time.Second, 1, 3)
		require.NoError(t, err)
		defer scanner.Stop(context.Background())

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
		defer scanner.Stop(context.Background())

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
		defer scanner.Stop(context.Background())

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
	var errors []error
	for err := range errCh {
		errors = append(errors, err)
	}

	assert.Empty(t, errors, "Expected no errors during stress test")
}
