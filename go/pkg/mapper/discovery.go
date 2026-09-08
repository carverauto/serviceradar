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

// Package mapper pkg/discovery/discovery.go
package mapper

import (
	"context"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const (
	evidenceClassDirectPhysical  = "direct-physical"
	evidenceClassDirectLogical   = "direct-logical"
	evidenceClassHostedVirtual   = "hosted-virtual"
	evidenceClassInferredSegment = "inferred-segment"
	evidenceClassObservedOnly    = "observed-only"

	confidenceTierHigh   = "high"
	confidenceTierMedium = "medium"
	confidenceTierLow    = "low"
)

const (
	mapperDebugBundleOption     = "mapper_debug_bundle"
	mapperDebugBundlePathOption = "mapper_debug_bundle_path"
	defaultMapperDebugBundleDir = "/tmp/serviceradar/mapper-debug"

	discoveryModeSNMP               = "snmp"
	protocolLLDP                    = "lldp"
	protocolCDP                     = "cdp"
	protocolSNMPL2                  = "snmp-l2"
	sourceSNMPARPFDB                = "snmp-arp-fdb"
	relationObservedTo              = "OBSERVED_TO"
	evidenceClassEndpointAttachment = "endpoint-attachment"
	stringTrueValue                 = "true"
	stringYesValue                  = "yes"
	fallbackUnknown                 = string(DiscoveryStatusUnknown)

	sourceAdapterUniFiV1    = "unifi.v1"
	sourceAdapterMikroTikV1 = "mikrotik.v1"
	sourceAdapterSNMPV1     = "snmp.v1"
	sourceAdapterLLDPV1     = "lldp.v1"
	sourceAdapterCDPV1      = "cdp.v1"
	topologyContractV2      = "mapper.topology_observation.v2"
)

// NewDiscoveryEngine creates a new discovery engine with the given configuration
func NewDiscoveryEngine(config *Config, publisher Publisher, log logger.Logger) (Mapper, error) {
	if err := validateConfig(config); err != nil {
		return nil, fmt.Errorf("invalid discovery engine configuration: %w", err)
	}

	probeSvc, err := newSharedICMPProbeService(log)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to initialize shared ICMP probe service; continuing without probes")
		probeSvc = noopHostProbeService{}
	}

	engine := &DiscoveryEngine{
		config:        config,
		activeJobs:    make(map[string]*DiscoveryJob),
		completedJobs: make(map[string]*DiscoveryResults),
		jobChan:       make(chan *DiscoveryJob, config.MaxActiveJobs),
		workers:       config.Workers,
		publisher:     publisher,
		done:          make(chan struct{}),
		schedulers:    make(map[string]*time.Ticker),
		logger:        log,
		hostProber:    probeSvc,
	}

	return engine, nil
}

// Start initializes and starts the discovery engine
func (e *DiscoveryEngine) Start(ctx context.Context) error {
	e.logger.Info().
		Int("workers", e.workers).
		Int("max_active_jobs", e.config.MaxActiveJobs).
		Msg("Starting DiscoveryEngine")

	e.wg.Add(e.workers) // Add worker count to WaitGroup

	for i := 0; i < e.workers; i++ {
		go e.worker(ctx, i)
	}

	// Start cleanup routine for completed jobs
	e.wg.Add(1)

	go func() {
		defer e.wg.Done()

		e.cleanupRoutine(ctx)
	}()

	// Start scheduled jobs
	e.wg.Add(1)

	go func() {
		defer e.wg.Done()

		e.scheduleJobs(ctx)
	}()

	e.logger.Info().Msg("DiscoveryEngine started")

	return nil
}

const (
	defaultFallbackTimeout   = 10 * time.Second // Fallback timeout for stopping
	defaultUniFiPhaseTimeout = 60 * time.Second
)

// Stop gracefully shuts down the discovery engine
func (e *DiscoveryEngine) Stop(ctx context.Context) error {
	e.logger.Info().Msg("Stopping DiscoveryEngine")

	// Stop all schedulers
	e.mu.Lock()

	for name, ticker := range e.schedulers {
		ticker.Stop()
		e.logger.Info().Str("job", name).Msg("Stopped scheduler for job")
	}

	e.schedulers = make(map[string]*time.Ticker) // Reset schedulers
	e.mu.Unlock()

	// Signal all goroutines to stop
	close(e.done)

	// Wait for all goroutines to finish
	waitChan := make(chan struct{})

	go func() {
		e.wg.Wait()
		close(waitChan)
	}()

	select {
	case <-waitChan:
		e.logger.Info().Msg("All DiscoveryEngine goroutines stopped")
	case <-ctx.Done():
		e.logger.Error().Err(ctx.Err()).Msg("DiscoveryEngine stop timed out or context canceled")
		return ctx.Err()
	case <-time.After(defaultFallbackTimeout):
		e.logger.Error().Msg("DiscoveryEngine stop timed out after 10s")
		return ErrDiscoveryStopTimeout
	}

	// Close jobChan after workers have stopped
	close(e.jobChan)

	if e.hostProber != nil {
		if err := e.hostProber.Close(); err != nil {
			e.logger.Warn().Err(err).Msg("Error stopping host probe service")
		}
	}

	e.logger.Info().Msg("DiscoveryEngine stopped")

	return nil
}
