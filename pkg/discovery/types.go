package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"
)

// SnmpDiscoveryEngine implements the Engine interface using SNMP.
type SnmpDiscoveryEngine struct {
	config        *Config
	activeJobs    map[string]*DiscoveryJob
	completedJobs map[string]*DiscoveryResults
	mu            sync.RWMutex
	jobChan       chan *DiscoveryJob
	workers       int
	publisher     Publisher
	done          chan struct{}
	wg            sync.WaitGroup
}

// DiscoveryType identifies the type of discovery to perform
type DiscoveryType string

const (
	DiscoveryTypeFull       DiscoveryType = "full"
	DiscoveryTypeBasic      DiscoveryType = "basic"
	DiscoveryTypeInterfaces DiscoveryType = "interfaces"
	DiscoveryTypeTopology   DiscoveryType = "topology"
)

// SNMPVersion represents the SNMP protocol version
type SNMPVersion string

const (
	SNMPVersion1  SNMPVersion = "v1"
	SNMPVersion2c SNMPVersion = "v2c"
	SNMPVersion3  SNMPVersion = "v3"
)

// DiscoveryParams contains parameters for a discovery operation
type DiscoveryParams struct {
	Seeds       []string          // IP addresses or CIDR ranges to scan
	Type        DiscoveryType     // Type of discovery to perform
	Credentials SNMPCredentials   // SNMP credentials to use
	Options     map[string]string // Additional discovery options
	Concurrency int               // Maximum number of concurrent operations
	Timeout     time.Duration     // Timeout for each operation
	Retries     int               // Number of retries for failed operations
	AgentID     string            // ID of the agent performing discovery
	PollerID    string            // ID of the poller initiating discovery
}

// SNMPCredentials contains information needed to authenticate with SNMP devices
type SNMPCredentials struct {
	Version         SNMPVersion                // SNMP protocol version
	Community       string                     // Community string for v1/v2c
	Username        string                     // Username for v3
	AuthProtocol    string                     // Auth protocol for v3 (MD5/SHA)
	AuthPassword    string                     // Auth password for v3
	PrivacyProtocol string                     // Privacy protocol for v3 (DES/AES)
	PrivacyPassword string                     // Privacy password for v3
	TargetSpecific  map[string]SNMPCredentials // Credentials for specific targets
}

// DiscoveryStatusType describes the current state of a discovery job
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

// DiscoveryJob represents a running discovery operation
type DiscoveryJob struct {
	ID            string
	Params        *DiscoveryParams
	Status        *DiscoveryStatus
	Results       *DiscoveryResults
	ctx           context.Context
	cancelFunc    context.CancelFunc
	discoveredIPs map[string]bool
	scanQueue     []string
	mu            sync.RWMutex
}

// DiscoveryResults contains the results of a discovery operation
type DiscoveryResults struct {
	DiscoveryID   string
	Status        *DiscoveryStatus
	Devices       []*DiscoveredDevice
	Interfaces    []*DiscoveredInterface
	TopologyLinks []*TopologyLink
	RawData       map[string]interface{} // Optional raw SNMP data
}

// DiscoveredDevice represents a discovered network device
type DiscoveredDevice struct {
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

// DiscoveredInterface represents a discovered network interface
type DiscoveredInterface struct {
	DeviceIP      string
	DeviceID      string
	IfIndex       int
	IfName        string
	IfDescr       string
	IfAlias       string
	IfSpeed       int64
	IfPhysAddress string
	IPAddresses   []string
	IfAdminStatus int
	IfOperStatus  int
	IfType        int
	Metadata      map[string]string
}

// TopologyLink represents a discovered link between two devices
type TopologyLink struct {
	Protocol           string
	LocalDeviceIP      string
	LocalDeviceID      string
	LocalIfIndex       int
	LocalIfName        string
	NeighborChassisID  string
	NeighborPortID     string
	NeighborPortDescr  string
	NeighborSystemName string
	NeighborMgmtAddr   string
	Metadata           map[string]string
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
			PublishBatchSize     int    `json:"publish_batch_size"`
			PublishRetries       int    `json:"publish_retries"`
			PublishRetryInterval string `json:"publish_retry_interval"`
		} `json:"stream_config"`
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

	return nil
}

// StreamConfig contains configuration for data publishing streams
type StreamConfig struct {
	DeviceStream         string
	InterfaceStream      string
	TopologyStream       string
	AgentID              string
	PollerID             string
	PublishBatchSize     int
	PublishRetries       int
	PublishRetryInterval time.Duration
}
