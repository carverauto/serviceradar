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

// Package snmp pkg/checker/snmp/interfaces.go

package snmp

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

//go:generate mockgen -destination=mock_snmp.go -package=snmp github.com/carverauto/serviceradar/pkg/checker/snmp Collector,Aggregator,Service,CollectorFactory,AggregatorFactory,SNMPClient,SNMPManager,DataStore

// Collector defines how to collect SNMP data from a target.
type Collector interface {
	// Start begins collecting data from the target
	Start(ctx context.Context) error
	// Stop halts data collection
	Stop() error
	// GetResults returns a channel that provides data points
	GetResults() <-chan DataPoint
	GetStatus() TargetStatus
}

// Aggregator defines how to aggregate collected SNMP data.
type Aggregator interface {
	// AddPoint adds a new data point for aggregation
	AddPoint(point *DataPoint)
	// GetAggregatedData retrieves aggregated data for a given OID and interval
	GetAggregatedData(oidName string, interval Interval) (*DataPoint, error)
	// Reset clears all aggregated data
	Reset()
}

// Service defines the main SNMP monitoring service.
type Service interface {
	// Start begins the SNMP monitoring service
	Start(ctx context.Context) error
	// Stop halts the SNMP monitoring service
	Stop() error
	// AddTarget adds a new SNMP target to monitor
	AddTarget(ctx context.Context, target *Target) error
	// RemoveTarget stops monitoring a target
	RemoveTarget(targetName string) error
	// GetStatus returns the current status of all monitored targets
	GetStatus(context.Context) (map[string]TargetStatus, error)
}

// CollectorFactory creates SNMP collectors.
type CollectorFactory interface {
	// CreateCollector creates a new collector for a target
	CreateCollector(target *Target) (Collector, error)
}

// AggregatorFactory creates data aggregators.
type AggregatorFactory interface {
	// CreateAggregator creates a new aggregator
	CreateAggregator(interval time.Duration, maxPoints int) (Aggregator, error)
}

// SNMPClient defines the interface for SNMP communication.
type SNMPClient interface {
	// Connect establishes the SNMP connection
	Connect() error
	// Get retrieves SNMP values for given OIDs
	Get(oids []string) (map[string]interface{}, error)
	// Close closes the SNMP connection
	Close() error
}

// SNMPManager defines the interface for managing SNMP data.
type SNMPManager interface {
	// GetSNMPMetrics fetches SNMP metrics from the database for a given node.
	GetSNMPMetrics(nodeID string, startTime, endTime time.Time) ([]db.SNMPMetric, error)
}

// DataStore defines how to store SNMP data.
type DataStore interface {
	// Store stores a data point
	Store(point DataPoint) error
	// Query retrieves data points matching criteria
	Query(filter DataFilter) ([]DataPoint, error)
	// Cleanup removes old data
	Cleanup(age time.Duration) error
}
