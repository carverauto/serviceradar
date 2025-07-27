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

package mapper

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// DiscoveryEngine implements the Engine interface using SNMP.
type DiscoveryEngine struct {
	config        *Config
	activeJobs    map[string]*DiscoveryJob
	completedJobs map[string]*DiscoveryResults
	mu            sync.RWMutex
	jobChan       chan *DiscoveryJob
	workers       int
	publisher     Publisher
	done          chan struct{}
	wg            sync.WaitGroup
	schedulers    map[string]*time.Ticker
	logger        logger.Logger
}

// DiscoveryType identifies the type of discovery to perform.
type DiscoveryType string

const (
	DiscoveryTypeFull       DiscoveryType = "full"
	DiscoveryTypeBasic      DiscoveryType = "basic"
	DiscoveryTypeInterfaces DiscoveryType = "interfaces"
	DiscoveryTypeTopology   DiscoveryType = "topology"
)

// SNMPVersion represents the SNMP protocol version.
type SNMPVersion string

const (
	SNMPVersion1  SNMPVersion = "v1"
	SNMPVersion2c SNMPVersion = "v2c"
	SNMPVersion3  SNMPVersion = "v3"
)

// DiscoveryParams contains parameters for a discovery operation.
type DiscoveryParams struct {
	Seeds       []string          // IP addresses or CIDR ranges to scan
	Type        DiscoveryType     // Type of discovery to perform
	Credentials *SNMPCredentials  // SNMP credentials to use
	Options     map[string]string // Additional discovery options
	Concurrency int               // Maximum number of concurrent operations
	Timeout     time.Duration     // Timeout for each operation
	Retries     int               // Number of retries for failed operations
	AgentID     string            // ID of the agent performing discovery
	PollerID    string            // ID of the poller initiating discovery
}

// SNMPCredentials contains information needed to authenticate with SNMP devices.
type SNMPCredentials struct {
	Version         SNMPVersion                 // SNMP protocol version
	Community       string                      // Community string for v1/v2c
	Username        string                      // Username for v3
	AuthProtocol    string                      // Auth protocol for v3 (MD5/SHA)
	AuthPassword    string                      // Auth password for v3
	PrivacyProtocol string                      // Privacy protocol for v3 (DES/AES)
	PrivacyPassword string                      // Privacy password for v3
	TargetSpecific  map[string]*SNMPCredentials // Credentials for specific targets
}

// DiscoveryStatusType describes the current state of a discovery job.
type DiscoveryStatusType string

const (
	DiscoveryStatusUnknown   DiscoveryStatusType = "unknown"
	DiscoveryStatusPending   DiscoveryStatusType = "pending"
	DiscoveryStatusRunning   DiscoveryStatusType = "running"
	DiscoveryStatusCompleted DiscoveryStatusType = "completed"
	DiscoveryStatusFailed    DiscoveryStatusType = "failed"
	DiscoverStatusCanceled   DiscoveryStatusType = "canceled"
)

// DiscoveryStatus contains the current status of a discovery operation
type DiscoveryStatus struct {
	DiscoveryID      string              // Unique ID for this discovery job
	Status           DiscoveryStatusType // Current status
	Progress         float64             // Progress percentage (0-100)
	StartTime        time.Time           // When the discovery started
	EndTime          time.Time           // When the discovery completed (if finished)
	Error            string              // Error message (if any)
	DevicesFound     int                 // Number of devices found
	InterfacesFound  int                 // Number of interfaces found
	TopologyLinks    int                 // Number of topology links found
	EstimatedSeconds int                 // Estimated remaining seconds
}

// DiscoveryJob represents a running discovery operation.
type DiscoveryJob struct {
	ID             string
	Params         *DiscoveryParams
	Status         *DiscoveryStatus
	Results        *DiscoveryResults
	ctx            context.Context
	cancelFunc     context.CancelFunc
	scanQueue      []string
	mu             sync.RWMutex
	uniFiSiteCache map[string][]UniFiSite         // Key: baseURL, Value: list of sites
	deviceMap      map[string]*DeviceInterfaceMap // DeviceID -> DeviceInterfaceMap
}

// DiscoveryResults contains the results of a discovery operation.
type DiscoveryResults struct {
	DiscoveryID   string
	Status        *DiscoveryStatus
	Devices       []*DiscoveredDevice
	Interfaces    []*DiscoveredInterface
	TopologyLinks []*TopologyLink
	RawData       map[string]interface{} // Optional raw SNMP data
}

// DiscoveredDevice represents a discovered network device.
type DiscoveredDevice struct {
	DeviceID    string // Unique identifier for the device (agentID:pollerID:deviceIP)
	IP          string
	MAC         string
	Hostname    string
	SysDescr    string
	SysObjectID string
	SysContact  string
	SysLocation string
	Uptime      int64
	Metadata    map[string]string
	FirstSeen   time.Time
	LastSeen    time.Time
}

// DiscoveredInterface represents a discovered network interface.
type DiscoveredInterface struct {
	DeviceIP      string
	DeviceID      string
	IfIndex       int32
	IfName        string
	IfDescr       string
	IfAlias       string
	IfSpeed       uint64
	IfPhysAddress string
	IPAddresses   []string
	IfAdminStatus int32
	IfOperStatus  int32
	IfType        int32
	Metadata      map[string]string
}

// TopologyLink represents a discovered link between two devices
type TopologyLink struct {
	Protocol           string
	LocalDeviceIP      string
	LocalDeviceID      string
	LocalIfIndex       int32
	LocalIfName        string
	NeighborChassisID  string
	NeighborPortID     string
	NeighborPortDescr  string
	NeighborSystemName string
	NeighborMgmtAddr   string
	Metadata           map[string]string
}

// SNMPCredentialConfig represents SNMP credentials for specific target IP ranges.
type SNMPCredentialConfig struct {
	Targets         []string    `json:"targets"`          // IP addresses or CIDR ranges
	Version         SNMPVersion `json:"version"`          // SNMP version (v1, v2c, v3)
	Community       string      `json:"community"`        // Community string for v1/v2c
	Username        string      `json:"username"`         // Username for v3
	AuthProtocol    string      `json:"auth_protocol"`    // Auth protocol for v3 (MD5/SHA)
	AuthPassword    string      `json:"auth_password"`    // Auth password for v3
	PrivacyProtocol string      `json:"privacy_protocol"` // Privacy protocol for v3 (DES/AES)
	PrivacyPassword string      `json:"privacy_password"` // Privacy password for v3
}

// ScheduledJob represents a scheduled discovery job configuration
type ScheduledJob struct {
	Name        string            `json:"name"`
	Interval    string            `json:"interval"`
	Enabled     bool              `json:"enabled"`
	Seeds       []string          `json:"seeds"`
	Type        string            `json:"type"`
	Credentials SNMPCredentials   `json:"credentials"`
	Concurrency int               `json:"concurrency"`
	Timeout     string            `json:"timeout"`
	Retries     int               `json:"retries"`
	Options     map[string]string `json:"options"`
}

type Config struct {
	Workers            int                        `json:"workers"`
	Timeout            time.Duration              `json:"timeout"`
	Retries            int                        `json:"retries"`
	MaxActiveJobs      int                        `json:"max_active_jobs"`
	ResultRetention    time.Duration              `json:"result_retention"`
	DefaultCredentials SNMPCredentials            `json:"default_credentials"`
	OIDs               map[DiscoveryType][]string `json:"oids"`
	StreamConfig       StreamConfig               `json:"stream_config"`
	Credentials        []SNMPCredentialConfig     `json:"credentials"`
	Seeds              []string                   `json:"seeds"`
	Security           *models.SecurityConfig     `json:"security"`
	UniFiAPIs          []UniFiAPIConfig           `json:"unifi_apis"`
	ScheduledJobs      []*ScheduledJob            `json:"scheduled_jobs"`
	Logging            *logger.Config             `json:"logging"`
}

type UniFiAPIConfig struct {
	BaseURL            string `json:"base_url"`
	APIKey             string `json:"api_key"`
	Name               string `json:"name"`                           // Optional name for identifying the controller
	InsecureSkipVerify bool   `json:"insecure_skip_verify,omitempty"` // Skip TLS verification
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type Alias Config

	aux := &struct {
		Timeout         string `json:"timeout"`
		ResultRetention string `json:"result_retention"`
		StreamConfig    struct {
			DeviceStream         string `json:"device_stream"`
			InterfaceStream      string `json:"interface_stream"`
			TopologyStream       string `json:"topology_stream"`
			AgentID              string `json:"agent_id"`
			PollerID             string `json:"poller_id"`
			Partition            string `json:"partition"`
			PublishBatchSize     int    `json:"publish_batch_size"`
			PublishRetries       int    `json:"publish_retries"`
			PublishRetryInterval string `json:"publish_retry_interval"`
		} `json:"stream_config"`
		ScheduledJobs []struct {
			Name        string            `json:"name"`
			Interval    string            `json:"interval"`
			Enabled     bool              `json:"enabled"`
			Seeds       []string          `json:"seeds"`
			Type        string            `json:"type"`
			Credentials SNMPCredentials   `json:"credentials"`
			Concurrency int               `json:"concurrency"`
			Timeout     string            `json:"timeout"`
			Retries     int               `json:"retries"`
			Options     map[string]string `json:"options"`
		} `json:"scheduled_jobs"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}

	// Parse Timeout
	if aux.Timeout != "" {
		duration, err := time.ParseDuration(aux.Timeout)
		if err != nil {
			return fmt.Errorf("invalid timeout format: %w", err)
		}

		c.Timeout = duration
	}

	// Parse ResultRetention
	if aux.ResultRetention != "" {
		duration, err := time.ParseDuration(aux.ResultRetention)
		if err != nil {
			return fmt.Errorf("invalid result_retention format: %w", err)
		}

		c.ResultRetention = duration
	}

	// Parse StreamConfig.PublishRetryInterval
	if aux.StreamConfig.PublishRetryInterval != "" {
		duration, err := time.ParseDuration(aux.StreamConfig.PublishRetryInterval)
		if err != nil {
			return fmt.Errorf("invalid publish_retry_interval format: %w", err)
		}

		c.StreamConfig.PublishRetryInterval = duration
	}

	// Parse ScheduledJobs
	c.ScheduledJobs = make([]*ScheduledJob, len(aux.ScheduledJobs))
	for i := 0; i < len(aux.ScheduledJobs); i++ {
		c.ScheduledJobs[i] = &ScheduledJob{
			Name:        aux.ScheduledJobs[i].Name,
			Interval:    aux.ScheduledJobs[i].Interval,
			Enabled:     aux.ScheduledJobs[i].Enabled,
			Seeds:       aux.ScheduledJobs[i].Seeds,
			Type:        aux.ScheduledJobs[i].Type,
			Credentials: aux.ScheduledJobs[i].Credentials,
			Concurrency: aux.ScheduledJobs[i].Concurrency,
			Retries:     aux.ScheduledJobs[i].Retries,
			Options:     aux.ScheduledJobs[i].Options,
		}

		if aux.ScheduledJobs[i].Timeout != "" {
			c.ScheduledJobs[i].Timeout = aux.ScheduledJobs[i].Timeout
		}
	}

	return nil
}

// StreamConfig contains configuration for data publishing streams
type StreamConfig struct {
	DeviceStream         string
	InterfaceStream      string
	TopologyStream       string
	AgentID              string
	PollerID             string
	Partition            string
	PublishBatchSize     int
	PublishRetries       int
	PublishRetryInterval time.Duration
}

type DeviceInterfaceMap struct {
	DeviceID   string              // Primary DeviceID (based on primary MAC)
	MACs       map[string]struct{} // All MACs associated with this device
	IPs        map[string]struct{} // All IPs associated with this device
	SysName    string              // System name (from SNMP or UniFi)
	Interfaces []*DiscoveredInterface
}
