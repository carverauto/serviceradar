package sweeper

import (
	"context"
	"time"
)

type SweepMode string

const (
	ModeTCP  SweepMode = "tcp"
	ModeICMP SweepMode = "icmp"
)

// HostResult represents all results for a single host.
type HostResult struct {
	Host        string        `json:"host"`
	Available   bool          `json:"available"`
	FirstSeen   time.Time     `json:"first_seen"`
	LastSeen    time.Time     `json:"last_seen"`
	ICMPStatus  *ICMPStatus   `json:"icmp_status,omitempty"`
	PortResults []*PortResult `json:"port_results,omitempty"`
}

// ICMPStatus represents ICMP ping results.
type ICMPStatus struct {
	Available  bool          `json:"available"`
	RoundTrip  time.Duration `json:"round_trip"`
	PacketLoss float64       `json:"packet_loss"`
}

// PortResult represents a single port scan result.
type PortResult struct {
	Port      int           `json:"port"`
	Available bool          `json:"available"`
	RespTime  time.Duration `json:"response_time"`
	Service   string        `json:"service,omitempty"` // Optional service identification
}

type PortCount struct {
	Port      int `json:"port"`
	Available int `json:"available"`
}

// Sweeper defines the main interface for network sweeping.
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

// Scanner defines how to perform network sweeps.
type Scanner interface {
	// Scan performs the sweep and returns results through the channel
	Scan(context.Context, []Target) (<-chan Result, error)
	// Stop gracefully stops any ongoing scans
	Stop() error
}

// Store defines storage operations for sweep results.
type Store interface {
	// SaveResult persists a single scan result
	SaveResult(context.Context, *Result) error
	// GetResults retrieves results matching the filter
	GetResults(context.Context, *ResultFilter) ([]Result, error)
	// GetSweepSummary gets the latest sweep summary
	GetSweepSummary(context.Context) (*SweepSummary, error)
	// PruneResults removes results older than given duration
	PruneResults(context.Context, time.Duration) error
}

// ResultProcessor defines how to process and aggregate sweep results.
type ResultProcessor interface {
	// Process takes a Result and updates internal state
	Process(*Result) error
	// GetSummary returns the current summary of all processed results
	GetSummary() (*SweepSummary, error)
	// Reset clears the processor's state
	Reset()
}

// Reporter defines how to report sweep results.
type Reporter interface {
	// Report sends a summary somewhere (e.g., to a cloud service)
	Report(context.Context, *SweepSummary) error
}

// SweepService combines scanning, storage, and reporting.
type SweepService interface {
	// Start begins periodic sweeping
	Start(context.Context) error
	// Stop gracefully stops sweeping
	Stop() error
	// GetStatus returns current sweep status
	GetStatus(context.Context) (*SweepSummary, error)
	// UpdateConfig updates service configuration
	UpdateConfig(Config) error
}

// Result represents the outcome of a sweep against a target.
type Result struct {
	Target     Target
	Available  bool
	FirstSeen  time.Time
	LastSeen   time.Time
	RespTime   time.Duration
	PacketLoss float64
	Error      error
}

// Target represents a network target to be scanned.
type Target struct {
	Host string
	Port int
	Mode SweepMode
}

// SweepSummary provides aggregated sweep results.
type SweepSummary struct {
	Network        string       `json:"network"`
	TotalHosts     int          `json:"total_hosts"`
	AvailableHosts int          `json:"available_hosts"`
	LastSweep      int64        `json:"last_sweep"` // Unix timestamp
	Ports          []PortCount  `json:"ports"`
	Hosts          []HostResult `json:"hosts"`
}

// Config defines sweeper configuration.
type Config struct {
	Networks    []string      `json:"networks"`
	Ports       []int         `json:"ports"`
	SweepModes  []SweepMode   `json:"sweep_modes"`
	Interval    time.Duration `json:"interval"`
	Concurrency int           `json:"concurrency"`
	Timeout     time.Duration `json:"timeout"`
	ICMPCount   int           `json:"icmp_count"`
}

// ResultFilter defines criteria for retrieving results.
type ResultFilter struct {
	Host      string
	Port      int
	StartTime time.Time
	EndTime   time.Time
	Available *bool
}
