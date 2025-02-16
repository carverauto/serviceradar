// pkg/checker/snmp/interfaces.go

package snmp

import (
	"context"
	"time"
)

//go:generate mockgen -destination=mock_snmp.go -package=snmp github.com/mfreeman451/serviceradar/pkg/checker/snmp Collector,Aggregator,Service

// Collector defines how to collect SNMP data from a target.
type Collector interface {
	// Start begins collecting data from the target
	Start(ctx context.Context) error
	// Stop halts data collection
	Stop() error
	// GetResults returns a channel that provides data points
	GetResults() <-chan DataPoint
}

// Aggregator defines how to aggregate collected SNMP data.
type Aggregator interface {
	// AddPoint adds a new data point for aggregation
	AddPoint(point DataPoint)
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
	AddTarget(target *Target) error
	// RemoveTarget stops monitoring a target
	RemoveTarget(targetName string) error
	// GetStatus returns the current status of all monitored targets
	GetStatus() (map[string]TargetStatus, error)
}

// TargetStatus represents the current status of an SNMP target.
type TargetStatus struct {
	Available bool                 `json:"available"`
	LastPoll  time.Time            `json:"last_poll"`
	OIDStatus map[string]OIDStatus `json:"oid_status"`
	Error     string               `json:"error,omitempty"`
}

// OIDStatus represents the current status of an OID.
type OIDStatus struct {
	LastValue  interface{} `json:"last_value"`
	LastUpdate time.Time   `json:"last_update"`
	ErrorCount int         `json:"error_count"`
	LastError  string      `json:"last_error,omitempty"`
}

// DataPoint represents a single collected data point.
type DataPoint struct {
	OIDName   string      `json:"oid_name"`
	Value     interface{} `json:"value"`
	Timestamp time.Time   `json:"timestamp"`
}

// CollectorFactory creates SNMP collectors.
type CollectorFactory interface {
	// CreateCollector creates a new collector for a target
	CreateCollector(target *Target) (Collector, error)
}

// AggregatorFactory creates data aggregators.
type AggregatorFactory interface {
	// CreateAggregator creates a new aggregator
	CreateAggregator(interval time.Duration) (Aggregator, error)
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

// DataStore defines how to store SNMP data.
type DataStore interface {
	// Store stores a data point
	Store(point DataPoint) error
	// Query retrieves data points matching criteria
	Query(filter DataFilter) ([]DataPoint, error)
	// Cleanup removes old data
	Cleanup(age time.Duration) error
}

// DataFilter defines criteria for querying stored data.
type DataFilter struct {
	OIDName   string
	StartTime time.Time
	EndTime   time.Time
	Limit     int
}
