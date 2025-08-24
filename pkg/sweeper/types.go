package sweeper

import (
	"encoding/json"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

type durationWrapper time.Duration

func (d *durationWrapper) UnmarshalJSON(b []byte) error {
	var s string

	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}

	if s == "" {
		*d = durationWrapper(0)
		return nil
	}

	dur, err := time.ParseDuration(s)
	if err != nil {
		return err
	}

	*d = durationWrapper(dur)

	return nil
}

// unmarshalConfig is a temporary struct for unmarshaling JSON with duration strings.
type unmarshalConfig struct {
	Networks      []string              `json:"networks"`
	Ports         []int                 `json:"ports"`
	SweepModes    []models.SweepMode    `json:"sweep_modes"`
	DeviceTargets []models.DeviceTarget `json:"device_targets,omitempty"`
	Interval      durationWrapper       `json:"interval"`
	Concurrency   int                   `json:"concurrency"`
	Timeout       durationWrapper       `json:"timeout"`
	ICMPCount     int                   `json:"icmp_count"`
	MaxIdle       int                   `json:"max_idle"`
	MaxLifetime   durationWrapper       `json:"max_lifetime,omitempty"`
	IdleTimeout   durationWrapper       `json:"idle_timeout,omitempty"`
	ICMPSettings  struct {
		RateLimit int             `json:"rate_limit"`
		Timeout   durationWrapper `json:"timeout,omitempty"`
		MaxBatch  int             `json:"max_batch"`
	} `json:"icmp_settings"`
	TCPSettings struct {
		Concurrency        int             `json:"concurrency"`
		Timeout            durationWrapper `json:"timeout,omitempty"`
		MaxBatch           int             `json:"max_batch"`
		RouteDiscoveryHost string          `json:"route_discovery_host,omitempty"`
		
		// Ring buffer tuning for SYN scanner memory vs performance tradeoffs
		RingBlockSize  int `json:"ring_block_size,omitempty"`  // Block size in bytes (default: 1MB, max: 8MB)
		RingBlockCount int `json:"ring_block_count,omitempty"` // Number of blocks (default: 8, max: 32, total max: 64MB)
		
		// Network interface selection for multi-homed hosts
		Interface string `json:"interface,omitempty"` // Network interface (e.g., "eth0", "wlan0") - auto-detected if empty
		
		// Advanced NAT/firewall compatibility options
		SuppressRSTReply bool `json:"suppress_rst_reply,omitempty"` // Suppress RST packet generation (optional)
	} `json:"tcp_settings"`
	EnableHighPerformanceICMP bool `json:"high_perf_icmp,omitempty"`
	ICMPRateLimit             int  `json:"icmp_rate_limit,omitempty"`
}
