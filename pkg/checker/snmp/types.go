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

// Package snmp pkg/checker/snmp/types.go
package snmp

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Interval represents a time interval for data aggregation.
type Interval string

const (
	Minute Interval = "minute"
	Hour   Interval = "hour"
	Day    Interval = "day"
)

// SNMPCollector implements the Collector interface.
type SNMPCollector struct {
	target     *Target
	client     SNMPClient
	dataChan   chan DataPoint
	errorChan  chan error
	done       chan struct{}
	closeOnce  sync.Once
	mu         sync.RWMutex
	status     TargetStatus
	bufferPool *sync.Pool
	logger     logger.Logger
}

// SNMPVersion represents supported SNMP versions.
type SNMPVersion string

const (
	Version1  SNMPVersion = "v1"
	Version2c SNMPVersion = "v2c"
	Version3  SNMPVersion = "v3"
)

// DataType represents the type of data being collected.
type DataType string

const (
	TypeCounter DataType = "counter"
	TypeGauge   DataType = "gauge"
	TypeBoolean DataType = "boolean"
	TypeBytes   DataType = "bytes"
	TypeString  DataType = "string"
	TypeFloat   DataType = "float"
)

// Duration is a wrapper for time.Duration that implements JSON marshaling.
type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}

	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))

		return nil
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}

		*d = Duration(tmp)

		return nil
	default:
		return errInvalidDuration
	}
}

// DataPoint represents a single collected data point.
type DataPoint struct {
	OIDName   string      `json:"oid_name"`
	Value     interface{} `json:"value"`
	Timestamp time.Time   `json:"timestamp"`
	DataType  DataType    `json:"data_type"`
	Scale     float64     `json:"scale"`
	Delta     bool        `json:"delta"`
}

// Target represents a device to monitor via SNMP.
type Target struct {
	Name      string      `json:"name"`
	Host      string      `json:"host"`
	Port      uint16      `json:"port"`
	Community string      `json:"community"`
	Version   SNMPVersion `json:"version"`
	Interval  Duration    `json:"interval"`
	Timeout   Duration    `json:"timeout"`
	Retries   int         `json:"retries"`
	OIDs      []OIDConfig `json:"oids"`
	MaxPoints int         `json:"max_points"`
}

// OIDConfig represents an OID to monitor.
type OIDConfig struct {
	OID      string   `json:"oid"`
	Name     string   `json:"name"`
	DataType DataType `json:"type"`
	Scale    float64  `json:"scale,omitempty"` // For scaling values (e.g., bytes to megabytes)
	Delta    bool     `json:"delta,omitempty"` // Calculate change between samples
}

// SNMPService implements both the Service interface and proto.AgentServiceServer.
type SNMPService struct {
	proto.UnimplementedAgentServiceServer
	collectors        map[string]Collector
	aggregators       map[string]Aggregator
	config            *SNMPConfig
	mu                sync.RWMutex
	done              chan struct{}
	collectorFactory  CollectorFactory
	aggregatorFactory AggregatorFactory
	status            map[string]TargetStatus
	logger            logger.Logger
}

// OIDStatus represents the current status of an OID.
type OIDStatus struct {
	LastValue  interface{} `json:"last_value"`
	LastUpdate time.Time   `json:"last_update"`
	ErrorCount int         `json:"error_count"`
	LastError  string      `json:"last_error,omitempty"`
}

// TargetStatus represents the current status of an SNMP target.
type TargetStatus struct {
	Available bool                 `json:"available"`
	LastPoll  time.Time            `json:"last_poll"`
	OIDStatus map[string]OIDStatus `json:"oid_status"`
	Error     string               `json:"error,omitempty"`
	HostIP    string               `json:"host_ip"`   // IP address for device registration
	HostName  string               `json:"host_name"` // Target name for display
	Target    *Target              `json:"-"`
}

// DataFilter defines criteria for querying stored data.
type DataFilter struct {
	OIDName   string
	StartTime time.Time
	EndTime   time.Time
	Limit     int
}
