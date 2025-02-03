package scan

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTCPScanner_HighConcurrency(t *testing.T) {
	t.Parallel()

	numTargets := 100
	targets := make([]models.Target, numTargets)

	for i := 0; i < numTargets; i++ {
		targets[i] = models.Target{
			Host: "localhost", // Use localhost to avoid DNS lookups
			Port: 12345,       // Use an unlikely port
			Mode: models.ModeTCP,
		}
	}

	scanner := NewTCPScanner(100*time.Millisecond, 10, 10, time.Second, time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	resultsChan, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	results := make([]models.Result, 0, numTargets)

	for result := range resultsChan {
		results = append(results, result)
	}

	// Verify we got responses for all targets
	require.Len(t, results, numTargets)

	// Clean up
	err = scanner.Stop(context.Background())
	require.NoError(t, err)
}

func TestTCPScanner_Scan(t *testing.T) {
	tests := []struct {
		name    string
		targets []models.Target
		timeout time.Duration
		wantErr bool
	}{
		{
			name: "scan localhost",
			targets: []models.Target{
				{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},
			},
			timeout: 1 * time.Second,
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scanner := NewTCPScanner(tt.timeout, 1, 1, 1, 1)
			results, err := scanner.Scan(context.Background(), tt.targets)

			if tt.wantErr {
				require.Error(t, err)
				return
			}

			require.NoError(t, err)

			var gotResults []models.Result
			for result := range results {
				gotResults = append(gotResults, result)
			}

			// Verify results
			require.Len(t, gotResults, len(tt.targets))

			for i, result := range gotResults {
				assert.Equal(t, tt.targets[i].Host, result.Target.Host)
				assert.Equal(t, tt.targets[i].Port, result.Target.Port)
				assert.NotZero(t, result.RespTime)
			}
		})
	}
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
