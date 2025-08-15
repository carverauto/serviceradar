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

// sweepModeSlice handles both string and SweepMode slice unmarshaling
type sweepModeSlice []models.SweepMode

func (s *sweepModeSlice) UnmarshalJSON(b []byte) error {
	// Try to unmarshal as []string first (sync service format)
	var stringSlice []string
	if err := json.Unmarshal(b, &stringSlice); err == nil {
		*s = make([]models.SweepMode, len(stringSlice))
		for i, str := range stringSlice {
			(*s)[i] = models.SweepMode(str)
		}

		return nil
	}

	// Fallback to []SweepMode (legacy format)
	var sweepModes []models.SweepMode
	if err := json.Unmarshal(b, &sweepModes); err != nil {
		return err
	}

	*s = sweepModes

	return nil
}

// unmarshalConfig is a temporary struct for unmarshaling JSON with duration strings.
// Updated to support both legacy Config format and new SweepConfig format from sync service
type unmarshalConfig struct {
	Networks      []string              `json:"networks,omitempty"`
	Ports         []int                 `json:"ports,omitempty"`
	SweepModes    sweepModeSlice        `json:"sweep_modes,omitempty"`
	DeviceTargets []models.DeviceTarget `json:"device_targets,omitempty"` // Support for new device targets from sync
	Interval      durationWrapper       `json:"interval,omitempty"`
	Concurrency   int                   `json:"concurrency,omitempty"`
	Timeout       durationWrapper       `json:"timeout,omitempty"`
	ICMPCount     int                   `json:"icmp_count,omitempty"`
	MaxIdle       int                   `json:"max_idle,omitempty"`
	MaxLifetime   durationWrapper       `json:"max_lifetime,omitempty"`
	IdleTimeout   durationWrapper       `json:"idle_timeout,omitempty"`
	ICMPSettings  struct {
		RateLimit int             `json:"rate_limit,omitempty"`
		Timeout   durationWrapper `json:"timeout,omitempty"`
		MaxBatch  int             `json:"max_batch,omitempty"`
	} `json:"icmp_settings,omitempty"`
	TCPSettings struct {
		Concurrency int             `json:"concurrency,omitempty"`
		Timeout     durationWrapper `json:"timeout,omitempty"`
		MaxBatch    int             `json:"max_batch,omitempty"`
	} `json:"tcp_settings,omitempty"`
	EnableHighPerformanceICMP bool `json:"high_perf_icmp,omitempty"`
	ICMPRateLimit             int  `json:"icmp_rate_limit,omitempty"`
}
