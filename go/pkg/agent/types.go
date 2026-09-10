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

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
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
	pluginManager      *PluginManager
	credentialBroker   CredentialBrokerResolver
	launchEnvelopes    *controlPlaneAutomationLaunchEnvelopeResolver
	artifactUploader   PluginArtifactUploader
	sidecarStatus      sidecarStatusProvider
	sidecarManager     sidecarLifecycleManager
	netprobeSidecar    *agentnetprobe.Sidecar
	addonManager       agentaddon.AddonManager
	addonTelemetry     *addonTelemetryBuffer
	addonOtlpRelay     *addonOtlpRelayDeps
	objectStore        ObjectStore
}

type sidecarStatusProvider interface {
	Status() []sidecar.Status
}

type sidecarLifecycleManager interface {
	sidecarStatusProvider
	StartAttach(context.Context) error
	Stop(context.Context) error
	Mode() (started, attach bool)
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
	BannerGrab    BannerGrabConfig      `json:"banner_grab,omitempty"`    // Optional active banner-grab phase
	Interval      Duration              `json:"interval"`
	Concurrency   int                   `json:"concurrency"`
	Timeout       Duration              `json:"timeout"`
	SweepGroupID  string                `json:"sweep_group_id,omitempty"` // Sweep group UUID for result tracking
	ConfigHash    string                `json:"config_hash,omitempty"`    // Hash of config for change detection
}

// BannerGrabConfig controls the optional active banner-grab phase.
type BannerGrabConfig struct {
	Enabled                bool             `json:"enabled"`
	Protocols              []string         `json:"protocols"`
	Ports                  map[string][]int `json:"ports"`
	ConnectTimeoutMS       int              `json:"connect_timeout_ms"`
	ReadTimeoutMS          int              `json:"read_timeout_ms"`
	MaxBannerBytes         int              `json:"max_banner_bytes"`
	MaxConcurrencyPerHost  int              `json:"max_concurrency_per_host"`
	MaxGlobalConcurrency   int              `json:"max_global_concurrency"`
	MaxProbeRatePerSecond  int              `json:"max_probe_rate_per_second"`
	MaxCandidateQueue      int              `json:"max_candidate_queue"`
	MatchBatchSize         int              `json:"match_batch_size"`
	MatchBatchMaxBytes     int              `json:"match_batch_max_bytes"`
	MinReprobeIntervalSec  int              `json:"min_reprobe_interval_s"`
	PerHostRateLimitMillis int              `json:"per_host_rate_limit_ms"`
}

// SweepGroupConfig represents a single sweep group config parsed from gateway payloads.
type SweepGroupConfig struct {
	ID             string
	SweepGroupID   string
	Networks       []string
	Ports          []int
	SweepModes     []models.SweepMode
	DeviceTargets  []models.DeviceTarget
	BannerGrab     BannerGrabConfig
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
	AgentID       string                 `json:"agent_id"`                 // Unique identifier for this agent
	AgentName     string                 `json:"agent_name,omitempty"`     // Explicit name for KV namespacing
	ComponentType string                 `json:"component_type,omitempty"` // Component type (agent, gateway, checker)
	HostIP        string                 `json:"host_ip,omitempty"`        // Host IP address for device correlation
	Partition     string                 `json:"partition,omitempty"`      // Partition for device correlation
	Security      *models.SecurityConfig `json:"security,omitempty"`       // Security config for checker connections
	KVAddress     string                 `json:"kv_address,omitempty"`     // Optional KV store address
	KVSecurity    *models.SecurityConfig `json:"kv_security,omitempty"`    // Separate security config for KV
	CheckersDir   string                 `json:"checkers_dir"`
	Logging       *logger.Config         `json:"logging,omitempty" hot:"reload"`

	// LocalOtlpEndpoint optionally names a co-resident OTLP/gRPC collector
	// endpoint (e.g. "http://127.0.0.1:4317") for self-telemetry
	// (refactor-otel-signal-correlation 10.5). It seeds the agent logger's
	// OTel endpoint ("auto" semantics: an explicit logging.otel.endpoint
	// wins) and is the add-on manager's fallback when the desired add-on set
	// has no sidecar-supervised otel-collector to derive the endpoint from.
	LocalOtlpEndpoint string `json:"local_otlp_endpoint,omitempty"`

	// AddonCgroupRoot optionally names a delegated cgroup v2 directory the agent
	// may write to (e.g. "/sys/fs/cgroup/serviceradar.slice/serviceradar-agent.service/addons")
	// under which agent-sidecar add-on subprocesses are placed with their
	// manifest resource limits (cpu.max/memory.max/memory.high/pids.max). It
	// takes precedence over a manifest slice for process-supervised add-ons.
	// When omitted, systemd deployments derive the delegated service root from
	// /proc/self/cgroup if the agent runs in the packaged supervisor subgroup.
	// Empty after runtime discovery disables cgroup enforcement unless the
	// manifest declares a writable slice; systemd-supervised add-ons use unit directives instead
	// (move-anomaly-detection-to-edge §4.2).
	AddonCgroupRoot string `json:"addon_cgroup_root,omitempty"`

	// Gateway configuration for push-based architecture
	GatewayAddr     string                 `json:"gateway_addr,omitempty"`     // Address of the agent-gateway to push status to
	GatewaySecurity *models.SecurityConfig `json:"gateway_security,omitempty"` // Security config for gateway connection
	// PluginHTTPTrustedCAFiles extends the host-side Wasm HTTP client's system
	// trust store with operator-managed PEM CA bundles. Wasm modules never receive
	// the bundle contents and cannot select or replace the trust roots.
	PluginHTTPTrustedCAFiles []string `json:"plugin_http_trusted_ca_files,omitempty"`
	PushInterval             Duration `json:"push_interval,omitempty"`             // How often to run the push loop (default: 30s)
	StatusDebounceInterval   Duration `json:"status_debounce_interval,omitempty"`  // Minimum interval between unchanged status pushes
	StatusHeartbeatInterval  Duration `json:"status_heartbeat_interval,omitempty"` // Maximum interval between status pushes (heartbeat)

	// Embedded sync runtime
	SyncRuntimeEnabled *bool                           `json:"sync_runtime_enabled,omitempty"` // Enable embedded integration sync runtime
	Bumblebee          *BumblebeeStatusConfig          `json:"bumblebee,omitempty"`            // Root scanner spool status integration
	EndpointInventory  *EndpointInventoryStatusConfig  `json:"endpoint_inventory,omitempty"`   // Endpoint software inventory spool status
	K8sPublicEndpoints *K8sPublicEndpointsStatusConfig `json:"k8s_public_endpoints,omitempty"` // Cluster public VIP inventory spool

	// Deprecated: accepted for compatibility with older rendered ConfigMaps.
	RemoteAccessKnownHostsFile string `json:"remote_access_known_hosts_file,omitempty"`

	// Optional per-session RDP helper gate. Agents advertise remote_access.rdp only
	// when enabled and the helper binary is locally executable.
	RemoteAccessRDPEnabled     *bool  `json:"remote_access_rdp_enabled,omitempty"`
	RemoteAccessRDPAdapterPath string `json:"remote_access_rdp_adapter_path,omitempty"`

	// EdgeRecordSender optionally enables the minimum durable-execution sender
	// that drains go/pkg/edge/spool over one EdgeRecordIngestService.Stream mTLS
	// lane per poll tick (openspec/changes/unify-sweep-results-proto, task 0.12
	// groups B/D). Disabled unless explicitly configured: the gateway-side RPC
	// server this depends on may not exist yet in a given deployment.
	EdgeRecordSender *EdgeRecordSenderConfig `json:"edge_record_sender,omitempty"`
}

// EdgeRecordSenderConfig configures the optional edge-record spool sender.
// GatewayAddr/Security default to the agent's own gateway_addr/gateway_security
// when empty: the edge-record lane is a SEPARATE pooled mTLS connection from
// the status-push connection (design.md's independent bulk/interactive/
// recovery transport rule), not a reason to require duplicate credentials in
// the common case where both point at the same gateway.
type EdgeRecordSenderConfig struct {
	Enabled bool `json:"enabled"`
	// SpoolDir is the directory holding the agent's edge-record spool segment
	// (go/pkg/edge/spool) and its persisted lane spool_id.
	SpoolDir     string                 `json:"spool_dir"`
	GatewayAddr  string                 `json:"gateway_addr,omitempty"`
	Security     *models.SecurityConfig `json:"security,omitempty"`
	PollInterval Duration               `json:"poll_interval,omitempty"`
}

type BumblebeeStatusConfig struct {
	Enabled     bool   `json:"enabled"`
	SpoolPath   string `json:"spool_path,omitempty"`
	CatalogPath string `json:"catalog_path,omitempty"`
	ProfilePath string `json:"profile_path,omitempty"`
	TmpDir      string `json:"tmp_dir,omitempty"`
}

type EndpointInventoryStatusConfig struct {
	Enabled     bool   `json:"enabled"`
	ConfigPath  string `json:"config_path,omitempty"`
	SpoolPath   string `json:"spool_path,omitempty"`
	CacheDir    string `json:"cache_dir,omitempty"`
	ProfilePath string `json:"profile_path,omitempty"`
	TmpDir      string `json:"tmp_dir,omitempty"`
}

func (c *EndpointInventoryStatusConfig) effectiveConfigPath() string {
	if c == nil || c.ConfigPath == "" {
		return "/etc/serviceradar/endpoint-inventory.json"
	}

	return c.ConfigPath
}

func (c *EndpointInventoryStatusConfig) effectiveSpoolPath() string {
	if c == nil || c.SpoolPath == "" {
		return endpointinventory.LatestPath("/var/lib/serviceradar/endpoint-inventory/spool")
	}

	return c.SpoolPath
}

func (c *EndpointInventoryStatusConfig) effectiveCacheDir() string {
	if c == nil || c.CacheDir == "" {
		return endpointinventory.DefaultConfig().CacheDir
	}

	return c.CacheDir
}

func (c *EndpointInventoryStatusConfig) effectiveProfilePath() string {
	if c == nil || c.ProfilePath == "" {
		return endpointinventory.DefaultConfig().ProfilePath
	}

	return c.ProfilePath
}

func (c *EndpointInventoryStatusConfig) effectiveTmpDir() string {
	if c == nil || c.TmpDir == "" {
		return endpointinventory.DefaultConfig().TmpDir
	}

	return c.TmpDir
}

func (c *BumblebeeStatusConfig) effectiveSpoolPath() string {
	if c == nil || c.SpoolPath == "" {
		return bumblebee.LatestPath("/var/lib/serviceradar/bumblebee/spool")
	}

	return c.SpoolPath
}

func (c *BumblebeeStatusConfig) effectiveCatalogPath() string {
	if c == nil || c.CatalogPath == "" {
		return bumblebee.DefaultConfig().CatalogPath
	}

	return c.CatalogPath
}

func (c *BumblebeeStatusConfig) effectiveProfilePath() string {
	if c == nil || c.ProfilePath == "" {
		return bumblebee.DefaultConfig().ProfilePath
	}

	return c.ProfilePath
}

func (c *BumblebeeStatusConfig) effectiveTmpDir() string {
	if c == nil || c.TmpDir == "" {
		return bumblebee.DefaultConfig().TmpDir
	}

	return c.TmpDir
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
