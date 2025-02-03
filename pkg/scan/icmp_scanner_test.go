package scan

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
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

func TestSocketPool(t *testing.T) {
	t.Run("Concurrent Access", func(t *testing.T) {
		pool := newSocketPool(5, time.Minute, time.Minute)
		defer pool.close()

		var wg sync.WaitGroup
		numGoroutines := 10

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

				// Just verify the connection exists
				successCount.Add(1)

				// Simulate some work without touching the connection
				time.Sleep(10 * time.Millisecond)

				// Release the socket back to the pool
				release()
			}()
		}

		wg.Wait()

		// Verify results
		assert.Equal(t, int32(0), otherErrorCount.Load(), "Should not have any unexpected errors")
		assert.True(t, successCount.Load() > 0, "Should have some successful socket acquisitions")
		assert.True(t, poolFullCount.Load() > 0, "Should have some pool-full conditions")
		assert.Equal(t, int32(numGoroutines), successCount.Load()+poolFullCount.Load(),
			"Total attempts should equal number of goroutines")
	})
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
		require.Equal(t, 1500, len(buf))

		// Return buffer
		pool.put(buf)

		// Get another buffer (should reuse the one we put back)
		buf2 := pool.get()
		require.NotNil(t, buf2)
		require.Equal(t, 1500, len(buf2))
	})
}

func TestICMPScannerGracefulShutdown(t *testing.T) {
	scanner, err := NewICMPScanner(time.Second, 5, 3)
	require.NoError(t, err)

	// Create cancel context for the test
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start scan in background
	resultsCh, err := scanner.Scan(ctx, []models.Target{
		{Host: "127.0.0.1", Mode: models.ModeICMP},
	})
	require.NoError(t, err)

	// Wait a bit to ensure scanning has started
	time.Sleep(100 * time.Millisecond)

	// Create a channel to track completion of result processing
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range resultsCh {
			// Drain results until channel is closed
		}
	}()

	// Cancel the context
	cancel()

	// Stop the scanner
	err = scanner.Stop(context.Background())
	require.NoError(t, err)

	// Wait for result processing to complete with timeout
	select {
	case <-done:
		// Success - results channel was closed and goroutine finished // UPDATED ASSERTION
	case <-time.After(2 * time.Second):
		t.Fatal("Timeout waiting for results channel to close")
	}
}

// Helper function to validate atomic operations are working correctly
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
