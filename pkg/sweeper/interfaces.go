package sweeper

import (
	"context"
	"time"
)

// Target represents a network target to be scanned
type Target struct {
	Host string
	Port int
}

// Result represents the outcome of a sweep against a target
type Result struct {
	Target    Target
	Available bool
	FirstSeen time.Time
	LastSeen  time.Time
	RespTime  time.Duration
	Error     error
}

// Scanner defines how to perform network sweeps
type Scanner interface {
	// Scan performs the sweep and returns results through the channel
	Scan(context.Context, []Target) (<-chan Result, error)

	// Stop gracefully stops any ongoing scans
	Stop() error
}

// Store defines how sweep results are persisted
type Store interface {
	// SaveResult persists a single scan result
	SaveResult(context.Context, Result) error

	// GetResults retrieves results matching the filter
	GetResults(context.Context, *ResultFilter) ([]Result, error)

	// PruneResults removes results older than the given duration
	PruneResults(context.Context, time.Duration) error
}

// ResultFilter defines criteria for retrieving results
type ResultFilter struct {
	Host      string
	Port      int
	StartTime time.Time
	EndTime   time.Time
	Available *bool
}

// Config defines sweeper configuration
type Config struct {
	Networks    []string      // CIDR ranges to sweep
	Ports       []int         // Ports to check
	Interval    time.Duration // How often to sweep
	Concurrency int           // Maximum concurrent scans
	Timeout     time.Duration // Individual scan timeout
}

// Sweeper defines the main interface for network sweeping
type Sweeper interface {
	// Start begins periodic sweeping based on configuration
	Start(context.Context) error

	// Stop gracefully stops sweeping
	Stop() error

	// GetResults retrieves sweep results based on filter
	GetResults(context.Context, *ResultFilter) ([]Result, error)

	// GetConfig returns current sweeper configuration
	GetConfig() Config

	// UpdateConfig updates sweeper configuration
	UpdateConfig(Config) error
}
