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

// Package snmp pkg/agent/snmp/types.go
package snmp

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// Interval represents a time interval for data aggregation.
type Interval string

const (
	// Minute represents a one-minute aggregation interval.
	Minute Interval = "minute"
	Hour   Interval = "hour"
	Day    Interval = "day"
)

// SNMPCollector implements the Collector interface.
// SNMPCollector implements the Collector interface for SNMP data collection.
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
// SNMPVersion represents the supported SNMP protocol versions.
type SNMPVersion string

const (
	// Version1 represents SNMP version 1.
	Version1  SNMPVersion = "v1"
	Version2c SNMPVersion = "v2c"
	Version3  SNMPVersion = "v3"
)

// DataType represents the type of data being collected.
type DataType string

const (
	// TypeCounter represents a monotonically increasing counter value.
	TypeCounter DataType = "counter"
	TypeGauge   DataType = "gauge"
	TypeBoolean DataType = "boolean"
	TypeBytes   DataType = "bytes"
	TypeString  DataType = "string"
	TypeFloat   DataType = "float"
)

// Duration is a wrapper for time.Duration that implements JSON marshaling.
type Duration time.Duration

// UnmarshalJSON implements the json.Unmarshaler interface for Duration.
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

// SecurityLevel represents SNMPv3 security levels.
type SecurityLevel string

const (
	// SecurityLevelNoAuthNoPriv represents no authentication and no privacy.
	SecurityLevelNoAuthNoPriv SecurityLevel = "noAuthNoPriv"
	// SecurityLevelAuthNoPriv represents authentication without privacy.
	SecurityLevelAuthNoPriv SecurityLevel = "authNoPriv"
	// SecurityLevelAuthPriv represents authentication with privacy.
	SecurityLevelAuthPriv SecurityLevel = "authPriv"
)

// AuthProtocol represents SNMPv3 authentication protocols.
type AuthProtocol string

const (
	// AuthProtocolMD5 represents MD5 authentication.
	AuthProtocolMD5 AuthProtocol = "MD5"
	// AuthProtocolSHA represents SHA authentication.
	AuthProtocolSHA AuthProtocol = "SHA"
	// AuthProtocolSHA224 represents SHA-224 authentication.
	AuthProtocolSHA224 AuthProtocol = "SHA224"
	// AuthProtocolSHA256 represents SHA-256 authentication.
	AuthProtocolSHA256 AuthProtocol = "SHA256"
	// AuthProtocolSHA384 represents SHA-384 authentication.
	AuthProtocolSHA384 AuthProtocol = "SHA384"
	// AuthProtocolSHA512 represents SHA-512 authentication.
	AuthProtocolSHA512 AuthProtocol = "SHA512"
)

// PrivProtocol represents SNMPv3 privacy protocols.
type PrivProtocol string

const (
	// PrivProtocolDES represents DES privacy.
	PrivProtocolDES PrivProtocol = "DES"
	// PrivProtocolAES represents AES-128 privacy.
	PrivProtocolAES PrivProtocol = "AES"
	// PrivProtocolAES192 represents AES-192 privacy.
	PrivProtocolAES192 PrivProtocol = "AES192"
	// PrivProtocolAES256 represents AES-256 privacy.
	PrivProtocolAES256 PrivProtocol = "AES256"
)

// V3Auth represents SNMPv3 authentication parameters.
type V3Auth struct {
	Username      string        `json:"username"`
	SecurityLevel SecurityLevel `json:"security_level"`
	AuthProtocol  AuthProtocol  `json:"auth_protocol,omitempty"`
	AuthPassword  string        `json:"auth_password,omitempty" sensitive:"true"`
	PrivProtocol  PrivProtocol  `json:"priv_protocol,omitempty"`
	PrivPassword  string        `json:"priv_password,omitempty" sensitive:"true"`
}

// Target represents a device to monitor via SNMP.
type Target struct {
	Name      string      `json:"name"`
	Host      string      `json:"host"`
	Port      uint16      `json:"port"`
	Community string      `json:"community" sensitive:"true"`
	Version   SNMPVersion `json:"version"`
	V3Auth    *V3Auth     `json:"v3_auth,omitempty"`
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
// SNMPService implements both the Service interface and proto.AgentServiceServer.
type SNMPService struct {
	proto.UnimplementedAgentServiceServer
	collectors        map[string]Collector
	aggregators       map[string]Aggregator
	config            *SNMPConfig
	mu                sync.RWMutex
	done              chan struct{}
	serviceCtx        context.Context
	cancel            context.CancelFunc
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
