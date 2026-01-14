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

package sysmon

import (
	"context"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// Collector defines the interface for system metrics collection.
type Collector interface {
	// Start begins periodic metric collection in the background.
	Start(ctx context.Context) error

	// Stop halts metric collection and releases resources.
	Stop() error

	// Collect performs a single metric collection cycle and returns the sample.
	Collect(ctx context.Context) (*MetricSample, error)

	// Reconfigure updates the collector with new configuration.
	// The collector applies changes without requiring a restart.
	Reconfigure(config *ParsedConfig) error

	// Latest returns the most recent metric sample, or nil if none available.
	Latest() *MetricSample
}

// DefaultCollector implements the Collector interface using gopsutil.
type DefaultCollector struct {
	config *ParsedConfig
	log    logger.Logger

	hostID    string
	hostIP    string
	agentID   string
	partition *string

	mu           sync.RWMutex
	latest       *MetricSample
	running      bool
	stopCh       chan struct{}
	stoppedCh    chan struct{}
	cancel       context.CancelFunc
	cpuCollector *CPUCollector
}

// CollectorOption configures a DefaultCollector.
type CollectorOption func(*DefaultCollector)

// WithLogger sets a custom logger for the collector.
func WithLogger(log logger.Logger) CollectorOption {
	return func(c *DefaultCollector) {
		c.log = log
	}
}

// WithAgentID sets the agent identifier for metric samples.
func WithAgentID(agentID string) CollectorOption {
	return func(c *DefaultCollector) {
		c.agentID = agentID
	}
}

// WithPartition sets the partition identifier for metric samples.
func WithPartition(partition string) CollectorOption {
	return func(c *DefaultCollector) {
		c.partition = &partition
	}
}

// NewCollector creates a new DefaultCollector with the given configuration.
func NewCollector(config *ParsedConfig, opts ...CollectorOption) (*DefaultCollector, error) {
	c := &DefaultCollector{
		config:    config,
		stopCh:    make(chan struct{}),
		stoppedCh: make(chan struct{}),
	}

	// Apply options
	for _, opt := range opts {
		opt(c)
	}

	// Set defaults if not provided
	if c.log == nil {
		c.log = logger.NewTestLogger()
	}

	// Initialize host identification
	c.hostID = getHostID()
	c.hostIP = getLocalIP(context.Background())

	// Initialize CPU collector for frequency sampling
	c.cpuCollector = NewCPUCollector(config.SampleInterval)

	return c, nil
}

// Start begins periodic metric collection in the background.
func (c *DefaultCollector) Start(ctx context.Context) error {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return nil
	}
	c.running = true
	c.stopCh = make(chan struct{})
	c.stoppedCh = make(chan struct{})

	// Create a cancellable context for the collection loop.
	// This allows Stop() to interrupt long-running operations like CPU sampling.
	collectionCtx, cancel := context.WithCancel(ctx)
	c.cancel = cancel
	c.mu.Unlock()

	go c.collectionLoop(collectionCtx)

	c.log.Info().
		Str("sample_interval", c.config.SampleInterval.String()).
		Bool("collect_cpu", c.config.CollectCPU).
		Bool("collect_memory", c.config.CollectMemory).
		Bool("collect_disk", c.config.CollectDisk).
		Bool("collect_network", c.config.CollectNetwork).
		Bool("collect_processes", c.config.CollectProcesses).
		Msg("sysmon collector started")

	return nil
}

// Stop halts metric collection and releases resources.
func (c *DefaultCollector) Stop() error {
	c.mu.Lock()
	if !c.running {
		c.mu.Unlock()
		return nil
	}
	c.running = false

	// Cancel the context first to interrupt any in-progress collection
	// (e.g., CPU sampling which can block for the sample interval)
	if c.cancel != nil {
		c.cancel()
	}

	close(c.stopCh)
	c.mu.Unlock()

	// Wait for collection loop to finish
	<-c.stoppedCh

	c.log.Info().Msg("sysmon collector stopped")
	return nil
}

// Collect performs a single metric collection cycle.
func (c *DefaultCollector) Collect(ctx context.Context) (*MetricSample, error) {
	c.mu.RLock()
	config := c.config
	cpuCollector := c.cpuCollector
	c.mu.RUnlock()

	// If collection is disabled, return an empty sample
	if !config.Enabled {
		return nil, nil
	}

	sample := NewMetricSample(c.hostID, c.hostIP, c.agentID, c.partition)

	// Collect CPU metrics
	if config.CollectCPU {
		cpus, clusters, err := cpuCollector.Collect(ctx)
		if err != nil {
			c.log.Warn().Err(err).Msg("CPU collection failed")
		} else {
			sample.CPUs = cpus
			sample.Clusters = clusters
		}
	}

	// Collect memory metrics
	if config.CollectMemory {
		mem, err := CollectMemory(ctx)
		if err != nil {
			c.log.Warn().Err(err).Msg("memory collection failed")
		} else {
			sample.Memory = *mem
		}
	}

	// Collect disk metrics
	if config.CollectDisk {
		disks, err := CollectDisks(ctx, config.DiskPaths)
		if err != nil {
			c.log.Warn().Err(err).Msg("disk collection failed")
		} else {
			sample.Disks = disks
		}
	}

	// Collect network metrics
	if config.CollectNetwork {
		network, err := CollectNetwork(ctx)
		if err != nil {
			c.log.Warn().Err(err).Msg("network collection failed")
		} else {
			sample.Network = network
		}
	}

	// Collect process metrics
	if config.CollectProcesses {
		processes, err := CollectProcesses(ctx)
		if err != nil {
			c.log.Warn().Err(err).Msg("process collection failed")
		} else {
			sample.Processes = processes
		}
	}

	// Update timestamp to reflect collection completion
	sample.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)

	// Store as latest
	c.mu.Lock()
	c.latest = sample
	c.mu.Unlock()

	return sample, nil
}

// Reconfigure updates the collector with new configuration.
func (c *DefaultCollector) Reconfigure(config *ParsedConfig) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	oldInterval := c.config.SampleInterval
	c.config = config

	// Update CPU collector if sample interval changed
	if oldInterval != config.SampleInterval {
		c.cpuCollector = NewCPUCollector(config.SampleInterval)
	}

	c.log.Info().
		Str("sample_interval", config.SampleInterval.String()).
		Bool("collect_cpu", config.CollectCPU).
		Bool("collect_memory", config.CollectMemory).
		Bool("collect_disk", config.CollectDisk).
		Bool("collect_network", config.CollectNetwork).
		Bool("collect_processes", config.CollectProcesses).
		Msg("sysmon collector reconfigured")

	return nil
}

// Latest returns the most recent metric sample.
func (c *DefaultCollector) Latest() *MetricSample {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.latest
}

func (c *DefaultCollector) collectionLoop(ctx context.Context) {
	defer close(c.stoppedCh)

	// Perform initial collection immediately
	if _, err := c.Collect(ctx); err != nil {
		c.log.Warn().Err(err).Msg("initial collection failed")
	}

	c.mu.RLock()
	interval := c.config.SampleInterval
	c.mu.RUnlock()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-c.stopCh:
			return
		case <-ticker.C:
			// Check if interval changed
			c.mu.RLock()
			newInterval := c.config.SampleInterval
			c.mu.RUnlock()

			if newInterval != interval {
				ticker.Reset(newInterval)
				interval = newInterval
			}

			if _, err := c.Collect(ctx); err != nil {
				c.log.Warn().Err(err).Msg("periodic collection failed")
			}
		}
	}
}
