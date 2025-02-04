package scan

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
)

func TestTCPScanner_HighConcurrency(t *testing.T) {
	t.Parallel()

	numTargets := 100
	targets := make([]models.Target, numTargets)

	for i := 0; i < numTargets; i++ {
		targets[i] = models.Target{
			Host: "localhost",
			Port: 12345,
			Mode: models.ModeTCP,
		}
	}

	scanner := NewTCPScanner(100*time.Millisecond, 10, 10, time.Second, time.Second)
	defer scanner.Stop(context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	resultsChan, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	var results []models.Result
	resultsDone := make(chan struct{})

	go func() {
		defer close(resultsDone)
		for result := range resultsChan {
			results = append(results, result)
		}
	}()

	// Wait for results with timeout
	select {
	case <-resultsDone:
		require.Len(t, results, numTargets, "Expected results for all targets")
	case <-time.After(3 * time.Second):
		t.Fatal("Timeout waiting for results")
	}
}

func TestTCPScanner_Scan(t *testing.T) {
	t.Run("scan localhost", func(t *testing.T) {
		// Create scanner with shorter timeouts
		scanner := NewTCPScanner(100*time.Millisecond, 1, 1, time.Second, time.Second)

		// Create context with timeout
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()

		// Ensure scanner cleanup
		defer func() {
			stopCtx, stopCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer stopCancel()
			if err := scanner.Stop(stopCtx); err != nil {
				t.Logf("Warning: error stopping scanner: %v", err)
			}
		}()

		targets := []models.Target{
			{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},
		}

		// Start scan
		results, err := scanner.Scan(ctx, targets)
		require.NoError(t, err)
		require.NotNil(t, results)

		// Collect results with timeout
		var gotResults []models.Result
		resultsDone := make(chan struct{})

		go func() {
			defer close(resultsDone)
			for result := range results {
				gotResults = append(gotResults, result)
			}
		}()

		// Wait for results or timeout
		select {
		case <-resultsDone:
			require.Len(t, gotResults, len(targets))
			for _, result := range gotResults {
				require.Equal(t, "127.0.0.1", result.Target.Host)
				require.Equal(t, 22, result.Target.Port)
				require.NotZero(t, result.RespTime)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("Timeout waiting for results")
		}
	})
}

func TestTCPScanner_Scan_ContextCancellation(t *testing.T) {
	// Create a TCPScanner with a short timeout
	scanner := NewTCPScanner(100*time.Millisecond, 1, 1, 1, 1)

	// Create a context that can be canceled
	ctx, cancel := context.WithCancel(context.Background())

	// Create a target to scan (using a likely unused port to avoid conflicts)
	targets := []models.Target{
		{Host: "www.google.com", Port: 9999}, // Unlikely to be open
	}

	// Start the scan
	resultsCh, err := scanner.Scan(ctx, targets)
	require.NoError(t, err, "Scan should not return an error")

	// Cancel the context immediately
	cancel()

	// Create a channel to collect results
	var results []models.Result
	done := make(chan struct{})

	go func() {
		defer close(done)
		for result := range resultsCh {
			results = append(results, result)
		}
	}()

	// Wait for results with timeout
	select {
	case <-done:
		// Channel closed normally
	case <-time.After(time.Second):
		t.Fatal("Timeout waiting for results channel to close")
	}

	// Check if we got any results that weren't due to cancellation
	for _, result := range results {
		if !strings.Contains(result.Error.Error(), "operation was canceled") &&
			!strings.Contains(result.Error.Error(), "context canceled") {
			t.Errorf("Got unexpected result after cancellation: %+v", result)
		}
	}
}
