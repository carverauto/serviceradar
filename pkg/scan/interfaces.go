package scan

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_scanner.go -package=scan github.com/carverauto/serviceradar/pkg/scan Scanner,ResultProcessor

// Scanner defines how to perform network sweeps.
type Scanner interface {
	// Scan performs the sweep and returns results through the channel
	Scan(context.Context, []models.Target) (<-chan models.Result, error)
	// Stop gracefully stops any ongoing scans
	Stop(ctx context.Context) error
}

// ResultProcessor defines how to process and aggregate sweep results.
type ResultProcessor interface {
	// Process takes a Result and updates internal state
	Process(result *models.Result) error
	// GetSummary returns the current summary of all processed results
	GetSummary() (*models.SweepSummary, error)
	// Reset clears the processor's state
	Reset()
}
