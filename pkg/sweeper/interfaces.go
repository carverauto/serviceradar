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

// Target represents a network target to be scanned.
type Target struct {
	Host string
	Port int
	Mode SweepMode
}

// HostResult represents all results for a single host
type HostResult struct {
	Host        string        `json:"host"`
	Available   bool          `json:"available"`
	FirstSeen   time.Time     `json:"first_seen"`
	LastSeen    time.Time     `json:"last_seen"`
	ICMPStatus  *ICMPStatus   `json:"icmp_status,omitempty"`
	PortResults []*PortResult `json:"port_results,omitempty"`
}

// ICMPStatus represents ICMP ping results
type ICMPStatus struct {
	Available  bool          `json:"available"`
	RoundTrip  time.Duration `json:"round_trip"`
	PacketLoss float64       `json:"packet_loss"`
}

// PortResult represents a single port scan result
type PortResult struct {
	Port      int           `json:"port"`
	Available bool          `json:"available"`
	RespTime  time.Duration `json:"response_time"`
	Service   string        `json:"service,omitempty"` // Optional service identification
}

// SweepSummary provides aggregated sweep results
type SweepSummary struct {
	Network        string       `json:"network"`
	TotalHosts     int          `json:"total_hosts"`
	AvailableHosts int          `json:"available_hosts"`
	LastSweep      time.Time    `json:"last_sweep"`
	Ports          []PortCount  `json:"ports"`
	Hosts          []HostResult `json:"hosts"` // Detailed host results
}

type PortCount struct {
	Port      int `json:"port"`
	Available int `json:"available"`
}

// Result represents the outcome of a sweep against a target.
type Result struct {
	Target     Target
	Available  bool
	FirstSeen  time.Time
	LastSeen   time.Time
	RespTime   time.Duration
	PacketLoss float64 // Percentage of packet loss for ICMP
	Error      error
}

// Scanner defines how to perform network sweeps.
type Scanner interface {
	// Scan performs the sweep and returns results through the channel
	Scan(context.Context, []Target) (<-chan Result, error)

	// Stop gracefully stops any ongoing scans
	Stop() error
}

// ResultFilter defines criteria for retrieving results.
type ResultFilter struct {
	Host      string
	Port      int
	StartTime time.Time
	EndTime   time.Time
	Available *bool
}

// Config defines sweeper configuration.
type Config struct {
	Networks    []string      `json:"networks"`    // CIDR ranges to sweep
	Ports       []int         `json:"ports"`       // Ports to check
	SweepModes  []SweepMode   `json:"sweep_modes"` // Modes to use (tcp, icmp)
	Interval    time.Duration `json:"interval"`    // How often to sweep
	Concurrency int           `json:"concurrency"` // Maximum concurrent scans
	Timeout     time.Duration `json:"timeout"`     // Individual scan timeout
	ICMPCount   int           `json:"icmp_count"`  // Number of ICMP attempts
}

type Store interface {
	// SaveResult persists a single scan result
	SaveResult(context.Context, *Result) error

	// SaveHostResult persists comprehensive host results
	SaveHostResult(context.Context, *HostResult) error

	// GetResults retrieves results matching the filter
	GetResults(context.Context, *ResultFilter) ([]Result, error)

	// GetHostResults retrieves detailed host results
	GetHostResults(context.Context, *ResultFilter) ([]HostResult, error)

	// GetSweepSummary gets the latest sweep summary
	GetSweepSummary(context.Context) (*SweepSummary, error)

	// PruneResults removes results older than given duration
	PruneResults(context.Context, time.Duration) error
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
