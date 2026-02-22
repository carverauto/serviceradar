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

// Package snmp pkg/agent/snmp/testing.go
package snmp

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// noopCollector is a collector that does nothing (for testing).
type noopCollector struct {
	targetName string
	results    chan DataPoint
}

func (c *noopCollector) Start(_ context.Context) error {
	return nil
}

func (c *noopCollector) Stop() error {
	if c.results != nil {
		close(c.results)
	}
	return nil
}

func (c *noopCollector) GetResults() <-chan DataPoint {
	return c.results
}

func (c *noopCollector) GetStatus() TargetStatus {
	return TargetStatus{
		Available: true,
		LastPoll:  time.Now(),
		OIDStatus: make(map[string]OIDStatus),
	}
}

// noopCollectorFactory creates noop collectors for testing.
type noopCollectorFactory struct{}

func (f *noopCollectorFactory) CreateCollector(target *Target, _ logger.Logger) (Collector, error) {
	return &noopCollector{
		targetName: target.Name,
		results:    make(chan DataPoint),
	}, nil
}

// noopAggregator is an aggregator that does nothing (for testing).
type noopAggregator struct{}

func (a *noopAggregator) AddPoint(_ *DataPoint) {}

func (a *noopAggregator) GetAggregatedData(_ string, _ Interval) (*DataPoint, error) {
	return nil, nil
}

func (a *noopAggregator) Drain() map[string][]DataPoint {
	return nil
}

func (a *noopAggregator) Reset() {}

// noopAggregatorFactory creates noop aggregators for testing.
type noopAggregatorFactory struct{}

func (f *noopAggregatorFactory) CreateAggregator(_ time.Duration, _ int) (Aggregator, error) {
	return &noopAggregator{}, nil
}

// NewMockServiceForTesting creates an SNMP service with mock factories that don't require network.
// This is intended for use in agent tests where we need an SNMP service that can start/stop
// without actually connecting to SNMP devices.
func NewMockServiceForTesting(config *SNMPConfig, log logger.Logger) (*SNMPService, error) {
	// Skip validation for testing - the config may not have all required fields
	// because we're not actually polling

	service := &SNMPService{
		collectors:        make(map[string]Collector),
		aggregators:       make(map[string]Aggregator),
		config:            config,
		done:              make(chan struct{}),
		status:            make(map[string]TargetStatus),
		logger:            log,
		collectorFactory:  &noopCollectorFactory{},
		aggregatorFactory: &noopAggregatorFactory{},
	}

	return service, nil
}
