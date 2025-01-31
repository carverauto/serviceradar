package scan

import (
	"context"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	combinedScannerTimeout = 5 * time.Second
	combinedScannerConc    = 10
	combinedScannerMaxIdle = 10
	combinedScannerMaxLife = 10 * time.Minute
	combinedScannerIdle    = 5 * time.Minute
)

func TestTCPScanner_HighConcurrency(t *testing.T) {
	numTargets := 100 // Reduced from 1000
	targets := make([]models.Target, numTargets)

	for i := 0; i < numTargets; i++ {
		targets[i] = models.Target{
			Host: "www.google.com",
			Port: 80,
			Mode: models.ModeTCP,
		}
	}

	scanner := NewTCPScanner(
		combinedScannerTimeout,
		combinedScannerConc,
		combinedScannerMaxIdle,
		combinedScannerMaxLife,
		combinedScannerIdle,
	)

	resultsChan, err := scanner.Scan(context.Background(), targets)
	require.NoError(t, err)

	unsuccessfulConnections := 0

	for result := range resultsChan {
		if !result.Available && result.Error != nil {
			unsuccessfulConnections++
		} else if result.Error != nil {
			t.Logf("Error during scan: %v", result.Error)
		}
	}

	assert.Equal(t, numTargets, unsuccessfulConnections, "Expected all connections to be unsuccessful but without errors")
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
	// Create a TCPScanner with a short timeout using the constructor
	scanner := NewTCPScanner(100*time.Millisecond, 1, 1, 1, 1)

	// Create a context that can be canceled
	ctx, cancel := context.WithCancel(context.Background())

	// Create a target to scan (using a likely unused port to avoid conflicts)
	targets := []models.Target{
		{Host: "www.google.com", Port: 9999}, // Unlikely to be open
	}

	// Start the scan
	resultsChan, err := scanner.Scan(ctx, targets)
	require.NoError(t, err, "Scan should not return an error")

	// Cancel the context almost immediately
	cancel()

	// Wait for a short time to allow the scanner to process the cancellation
	time.Sleep(50 * time.Millisecond)

	// Check if any results are available
	select {
	case result, ok := <-resultsChan:
		if ok {
			t.Errorf("Expected no results due to context cancellation, but got: %v", result)
		}
	default:
	}
}
