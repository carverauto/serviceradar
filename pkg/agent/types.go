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

// Package agent pkg/agent/types.go
package agent

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
)

type Server struct {
	proto.UnimplementedAgentServiceServer
	mu                 sync.RWMutex
	checkers           map[string]checker.Checker
	checkerConfs       map[string]*CheckerConfig
	configDir          string
	services           []Service
	listenAddr         string
	registry           checker.Registry
	errChan            chan error
	done               chan struct{}
	config             *ServerConfig
	connections        map[string]*CheckerConnection
	kvStore            KVStore
	createSweepService func(sweepConfig *SweepConfig, kvStore KVStore) (Service, error)
	setupKVStore       func(ctx context.Context, cfgLoader *config.Config, cfg *ServerConfig) (KVStore, error)
	logger             logger.Logger
}
type Duration time.Duration

type SweepConfig struct {
	MaxTargets    int
	MaxGoroutines int
	BatchSize     int
	MemoryLimit   int64
	Networks      []string           `json:"networks"`
	Ports         []int              `json:"ports"`
	SweepModes    []models.SweepMode `json:"sweep_modes"`
	Interval      Duration           `json:"interval"`
	Concurrency   int                `json:"concurrency"`
	Timeout       Duration           `json:"timeout"`
}

type CheckerConfig struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Address    string          `json:"address,omitempty"`
	Port       int             `json:"port,omitempty"`
	Timeout    Duration        `json:"timeout,omitempty"`
	ListenAddr string          `json:"listen_addr,omitempty"`
	Additional json.RawMessage `json:"additional,omitempty"`
	Details    json.RawMessage `json:"details,omitempty"`
}

// ServerConfig holds the configuration for the agent server.
type ServerConfig struct {
	AgentID     string                 `json:"agent_id"`             // Unique identifier for this agent
	AgentName   string                 `json:"agent_name,omitempty"` // Explicit name for KV namespacing
	HostIP      string                 `json:"host_ip,omitempty"`    // Host IP address for device correlation
	Partition   string                 `json:"partition,omitempty"`  // Partition for device correlation
	ListenAddr  string                 `json:"listen_addr"`
	Security    *models.SecurityConfig `json:"security"`
	KVAddress   string                 `json:"kv_address,omitempty"`  // Optional KV store address
	KVSecurity  *models.SecurityConfig `json:"kv_security,omitempty"` // Separate security config for KV
	CheckersDir string                 `json:"checkers_dir"`          // Directory for external checkers
	Logging     *logger.Config         `json:"logging,omitempty"`     // Logger configuration
}

type CheckerConnection struct {
	client      *grpc.Client
	serviceName string
	serviceType string
	mu          sync.RWMutex
	address     string
	healthy     bool
	logger      logger.Logger
}

type ServiceError struct {
	ServiceName string
	Err         error
}

// ICMPChecker performs ICMP checks using a pre-configured scanner.
type ICMPChecker struct {
	Host     string
	DeviceID string
	scanner  scan.Scanner
	logger   logger.Logger
}

// ICMPResponse defines the structure of the ICMP check result.
type ICMPResponse struct {
	Host         string  `json:"host"`
	ResponseTime int64   `json:"response_time"` // in nanoseconds
	PacketLoss   float64 `json:"packet_loss"`
	Available    bool    `json:"available"`
	AgentID      string  `json:"agent_id,omitempty"`  // Optional agent ID for context
	PollerID     string  `json:"poller_id,omitempty"` // Optional poller ID for context
	DeviceID     string  `json:"device_id,omitempty"` // Device ID for proper correlation (partition:host_ip)
}

// UnmarshalJSON implements the json.Unmarshaler interface to allow parsing of a Duration from a JSON string or number.
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
