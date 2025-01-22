package models

import "time"

// SweepData represents network sweep results.
type SweepData struct {
	Network        string       `json:"network"`
	TotalHosts     int32        `json:"total_hosts"`
	AvailableHosts int32        `json:"available_hosts"`
	LastSweep      int64        `json:"last_sweep"`
	Ports          []PortStatus `json:"ports"`
}

// PortStatus represents port availability information.
type PortStatus struct {
	Port      int32 `json:"port"`
	Available int32 `json:"available"`
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

type SweepMode string

const (
	ModeTCP  SweepMode = "tcp"
	ModeICMP SweepMode = "icmp"
)

// Target represents a network target to be scanned.
type Target struct {
	Host     string
	Port     int
	Mode     SweepMode
	Metadata map[string]interface{} // Additional metadata about the scan

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

// ResultFilter defines criteria for retrieving results.
type ResultFilter struct {
	Host      string
	Port      int
	StartTime time.Time
	EndTime   time.Time
	Available *bool
}

// ContainsMode checks if a mode is in a list of modes.
func ContainsMode(modes []SweepMode, mode SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}

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

// SweepSummary provides aggregated sweep results.
type SweepSummary struct {
	Network        string       `json:"network"`
	TotalHosts     int          `json:"total_hosts"`
	AvailableHosts int          `json:"available_hosts"`
	LastSweep      int64        `json:"last_sweep"` // Unix timestamp
	Ports          []PortCount  `json:"ports"`
	Hosts          []HostResult `json:"hosts"`
}
