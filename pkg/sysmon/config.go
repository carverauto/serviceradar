/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package sysmon provides cross-platform system metrics collection.
package sysmon

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

const (
	// DefaultSampleInterval is the default interval between metric collections.
	DefaultSampleInterval = 10 * time.Second

	// MinSampleInterval is the minimum allowed sample interval.
	MinSampleInterval = 50 * time.Millisecond

	// MaxSampleInterval is the maximum allowed sample interval.
	MaxSampleInterval = 5 * time.Minute

	// DefaultConfigRefreshInterval is how often agents check for config updates.
	DefaultConfigRefreshInterval = 5 * time.Minute
)

// Config controls the sysmon collector runtime behavior.
type Config struct {
	// Enabled controls whether sysmon collection is active.
	Enabled bool `json:"enabled"`

	// SampleInterval is the duration between metric collections.
	// Supports Go duration strings like "10s", "1m", "500ms".
	SampleInterval string `json:"sample_interval,omitempty"`

	// CollectCPU enables CPU metrics collection.
	CollectCPU bool `json:"collect_cpu"`

	// CollectMemory enables memory metrics collection.
	CollectMemory bool `json:"collect_memory"`

	// CollectDisk enables disk metrics collection.
	CollectDisk bool `json:"collect_disk"`

	// CollectNetwork enables network interface metrics collection.
	CollectNetwork bool `json:"collect_network"`

	// CollectProcesses enables process metrics collection.
	CollectProcesses bool `json:"collect_processes"`

	// DiskPaths specifies which mount points to monitor.
	// If empty, all mounted filesystems are monitored.
	DiskPaths []string `json:"disk_paths,omitempty"`

	// Thresholds defines warning/critical thresholds for alerting.
	Thresholds map[string]string `json:"thresholds,omitempty"`
}

// DefaultConfig returns a configuration with sensible defaults.
func DefaultConfig() Config {
	return Config{
		Enabled:          true,
		SampleInterval:   "10s",
		CollectCPU:       true,
		CollectMemory:    true,
		CollectDisk:      true,
		CollectNetwork:   false, // Opt-in due to verbosity
		CollectProcesses: false, // Opt-in due to resource usage
		DiskPaths:        []string{"/"},
		Thresholds:       make(map[string]string),
	}
}

// ParsedConfig holds the parsed and validated configuration values.
type ParsedConfig struct {
	Enabled          bool
	SampleInterval   time.Duration
	CollectCPU       bool
	CollectMemory    bool
	CollectDisk      bool
	CollectNetwork   bool
	CollectProcesses bool
	DiskPaths        []string
	Thresholds       map[string]string
}

// Parse validates and parses the configuration into usable values.
func (c *Config) Parse() (*ParsedConfig, error) {
	parsed := &ParsedConfig{
		Enabled:          c.Enabled,
		CollectCPU:       c.CollectCPU,
		CollectMemory:    c.CollectMemory,
		CollectDisk:      c.CollectDisk,
		CollectNetwork:   c.CollectNetwork,
		CollectProcesses: c.CollectProcesses,
		DiskPaths:        c.DiskPaths,
		Thresholds:       c.Thresholds,
	}

	// Parse sample interval
	if c.SampleInterval == "" {
		parsed.SampleInterval = DefaultSampleInterval
	} else {
		d, err := time.ParseDuration(c.SampleInterval)
		if err != nil {
			return nil, fmt.Errorf("invalid sample_interval %q: %w", c.SampleInterval, err)
		}

		if d < MinSampleInterval {
			d = MinSampleInterval
		} else if d > MaxSampleInterval {
			d = MaxSampleInterval
		}

		parsed.SampleInterval = d
	}

	// Default disk paths if none specified
	if len(parsed.DiskPaths) == 0 {
		parsed.DiskPaths = []string{"/"}
	}

	// Initialize thresholds map if nil
	if parsed.Thresholds == nil {
		parsed.Thresholds = make(map[string]string)
	}

	return parsed, nil
}

// LoadConfigFromFile reads and parses a sysmon configuration from a JSON file.
func LoadConfigFromFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}

// MergeWithDefaults returns a new config with default values for any unset fields.
func (c *Config) MergeWithDefaults() Config {
	defaults := DefaultConfig()

	// Start with defaults and override with set values
	merged := defaults

	// Only override if explicitly set (we check for non-zero/non-empty values)
	merged.Enabled = c.Enabled

	if c.SampleInterval != "" {
		merged.SampleInterval = c.SampleInterval
	}

	// Boolean fields - these are always set, so just copy them
	merged.CollectCPU = c.CollectCPU
	merged.CollectMemory = c.CollectMemory
	merged.CollectDisk = c.CollectDisk
	merged.CollectNetwork = c.CollectNetwork
	merged.CollectProcesses = c.CollectProcesses

	if len(c.DiskPaths) > 0 {
		merged.DiskPaths = c.DiskPaths
	}

	if len(c.Thresholds) > 0 {
		merged.Thresholds = c.Thresholds
	}

	return merged
}
