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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

const (
	intervalLiteral         = "interval"
	networkSweepServiceName = "network_sweep"
)

// Server represents the main agent server that handles service coordination and management.
// In push-mode, the Server coordinates embedded services, collecting their status
// to be pushed to the gateway by PushLoop.
type Server struct {
	mu                 sync.RWMutex
	configDir          string
	services           []Service
	errChan            chan error
	done               chan struct{}
	config             *ServerConfig
	createSweepService func(ctx context.Context, sweepConfig *SweepConfig) (Service, error)
	logger             logger.Logger
	sysmonService      *SysmonService
	snmpService        *SNMPAgentService
	mapperService      *MapperService
	tftpService        *TFTPService
	pluginManager      *PluginManager
}

// Duration represents a time duration that can be unmarshaled from JSON.
type Duration time.Duration

// SweepConfig defines configuration parameters for network sweep operations.
type SweepConfig struct {
	MaxTargets    int
	MaxGoroutines int
	BatchSize     int
	MemoryLimit   int64
	Networks      []string              `json:"networks"`
	Ports         []int                 `json:"ports"`
	SweepModes    []models.SweepMode    `json:"sweep_modes"`
	DeviceTargets []models.DeviceTarget `json:"device_targets,omitempty"` // Per-device sweep configuration
	Interval      Duration              `json:"interval"`
	Concurrency   int                   `json:"concurrency"`
	Timeout       Duration              `json:"timeout"`
	SweepGroupID  string                `json:"sweep_group_id,omitempty"` // Sweep group UUID for result tracking
	ConfigHash    string                `json:"config_hash,omitempty"`    // Hash of config for change detection
}

// SweepGroupConfig represents a single sweep group config parsed from gateway payloads.
type SweepGroupConfig struct {
	ID             string
	SweepGroupID   string
	Networks       []string
	Ports          []int
	SweepModes     []models.SweepMode
	DeviceTargets  []models.DeviceTarget
	Interval       Duration
	Concurrency    int
	Timeout        Duration
	ScheduleType   string
	CronExpression string
	ConfigHash     string
}

// SweepGroupsConfig bundles multiple sweep group configs with a shared config hash.
type SweepGroupsConfig struct {
	Groups     []SweepGroupConfig
	ConfigHash string
}

// ServerConfig holds the configuration for the agent server.
type ServerConfig struct {
	AgentID       string                 `json:"agent_id"`                        // Unique identifier for this agent
	AgentName     string                 `json:"agent_name,omitempty"`            // Explicit name for KV namespacing
	ComponentType string                 `json:"component_type,omitempty"`        // Component type (agent, gateway, checker)
	HostIP      string                 `json:"host_ip,omitempty"`     // Host IP address for device correlation
	Partition   string                 `json:"partition,omitempty"`   // Partition for device correlation
	Security    *models.SecurityConfig `json:"security,omitempty"`    // Security config for checker connections
	KVAddress   string                 `json:"kv_address,omitempty"`  // Optional KV store address
	KVSecurity  *models.SecurityConfig `json:"kv_security,omitempty"` // Separate security config for KV
	CheckersDir string                 `json:"checkers_dir"`
	Logging     *logger.Config         `json:"logging,omitempty" hot:"reload"`

	// Gateway configuration for push-based architecture
	GatewayAddr             string                 `json:"gateway_addr,omitempty"`              // Address of the agent-gateway to push status to
	GatewaySecurity         *models.SecurityConfig `json:"gateway_security,omitempty"`          // Security config for gateway connection
	PushInterval            Duration               `json:"push_interval,omitempty"`             // How often to run the push loop (default: 30s)
	StatusDebounceInterval  Duration               `json:"status_debounce_interval,omitempty"`  // Minimum interval between unchanged status pushes
	StatusHeartbeatInterval Duration               `json:"status_heartbeat_interval,omitempty"` // Maximum interval between status pushes (heartbeat)

	// Embedded sync runtime
	SyncRuntimeEnabled *bool `json:"sync_runtime_enabled,omitempty"` // Enable embedded integration sync runtime
}

// ServiceError represents an error that occurred in a specific service.
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
	AgentID      string  `json:"agent_id,omitempty"`   // Optional agent ID for context
	GatewayID    string  `json:"gateway_id,omitempty"` // Optional gateway ID for context
	DeviceID     string  `json:"device_id,omitempty"`  // Device ID for proper correlation (partition:host_ip)
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
