package sweeper

import (
	"context"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// Sweeper defines the main interface for network sweeping.
type Sweeper interface {
	// Start begins periodic sweeping based on configuration
	Start(context.Context) error

	// Stop gracefully stops sweeping
	Stop() error

	// GetResults retrieves sweep results based on filter
	GetResults(context.Context, *models.ResultFilter) ([]models.Result, error)

	// GetConfig returns current sweeper configuration
	GetConfig() models.Config

	// UpdateConfig updates sweeper configuration
	UpdateConfig(models.Config) error
}

// Store defines storage operations for sweep results.
type Store interface {
	// SaveResult persists a single scan result
	SaveResult(context.Context, *models.Result) error
	// GetResults retrieves results matching the filter
	GetResults(context.Context, *models.ResultFilter) ([]models.Result, error)
	// GetSweepSummary gets the latest sweep summary
	GetSweepSummary(context.Context) (*models.SweepSummary, error)
	// PruneResults removes results older than given duration
	PruneResults(context.Context, time.Duration) error
}

// Reporter defines how to report sweep results.
type Reporter interface {
	// Report sends a summary somewhere (e.g., to a cloud service)
	Report(context.Context, *models.SweepSummary) error
}

// SweepService combines scanning, storage, and reporting.
type SweepService interface {
	// Start begins periodic sweeping
	Start(context.Context) error
	// Stop gracefully stops sweeping
	Stop() error
	// GetStatus returns current sweep status
	GetStatus(context.Context) (*models.SweepSummary, error)
	// UpdateConfig updates service configuration
	UpdateConfig(models.Config) error
}
