package sysmonvm

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultListenAddr     = "0.0.0.0:50110"
	defaultSampleInterval = 200 * time.Millisecond
	minSampleInterval     = 50 * time.Millisecond
	maxSampleInterval     = 5 * time.Second
)

// Config controls the sysmon-vm checker runtime.
type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	Security       *models.SecurityConfig `json:"security,omitempty"`
	SampleInterval string                 `json:"sample_interval,omitempty"`
}

// Normalize ensures defaults are populated and validated.
func (c *Config) Normalize() (time.Duration, error) {
	if c.ListenAddr == "" {
		c.ListenAddr = defaultListenAddr
	}

	if c.SampleInterval == "" {
		return defaultSampleInterval, nil
	}

	d, err := time.ParseDuration(c.SampleInterval)
	if err != nil {
		return 0, err
	}

	if d < minSampleInterval {
		d = minSampleInterval
	} else if d > maxSampleInterval {
		d = maxSampleInterval
	}

	return d, nil
}
