// Package main implements the Proxmox inventory WASM plugin for ServiceRadar.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

const (
	pluginID                    = "proxmox-inventory"
	discoverySource             = "proxmox"
	defaultTimeoutMS            = 30000
	maxTimeoutMS                = 300000
	defaultHTTPMaxResponseBytes = 1024 * 1024
	maxHTTPResponseBytes        = sdk.MaxHTTPResponseBytes
)

var (
	errMissingTarget            = errors.New("at least one Proxmox target is required")
	errMissingToken             = errors.New("Proxmox API token is required")
	proxmoxHTTP      httpClient = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}
)

type httpClient interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

type Config struct {
	BaseURL            string         `json:"base_url"`
	APIToken           string         `json:"api_token"`
	APITokenSecretRef  string         `json:"api_token_secret_ref"`
	CredentialBroker   map[string]any `json:"credential_broker,omitempty"`
	Targets            []Target       `json:"targets"`
	TimeoutMS          int            `json:"timeout_ms"`
	MaxResponseBytes   int            `json:"max_response_bytes"`
	IncludeGuests      *bool          `json:"include_guests"`
	InsecureSkipVerify bool           `json:"insecure_skip_verify"`
	AutoDiscovery      bool           `json:"auto_discovery_enabled"`
}

type Target struct {
	BaseURL   string `json:"base_url"`
	APIToken  string `json:"api_token"`
	DeviceID  string `json:"device_id"`
	Hostname  string `json:"hostname"`
	Partition string `json:"partition"`
}

type configJSON struct {
	BaseURL            string   `json:"base_url"`
	APIToken           string   `json:"api_token"`
	APITokenSecretRef  string   `json:"api_token_secret_ref"`
	Targets            []Target `json:"targets"`
	TimeoutMS          int      `json:"timeout_ms"`
	MaxResponseBytes   int      `json:"max_response_bytes"`
	IncludeGuests      *bool    `json:"include_guests"`
	InsecureSkipVerify bool     `json:"insecure_skip_verify"`
	AutoDiscovery      bool     `json:"auto_discovery_enabled"`
}

type pluginInputsJSON struct {
	Schema        string        `json:"schema"`
	PolicyID      string        `json:"policy_id"`
	PolicyVersion int           `json:"policy_version"`
	AgentID       string        `json:"agent_id"`
	GeneratedAt   string        `json:"generated_at"`
	Template      *configJSON   `json:"template,omitempty"`
	Inputs        []pluginInput `json:"inputs"`
}

type pluginInput struct {
	Name       string            `json:"name"`
	Entity     string            `json:"entity"`
	Query      string            `json:"query"`
	ChunkIndex int               `json:"chunk_index"`
	ChunkTotal int               `json:"chunk_total"`
	ChunkHash  string            `json:"chunk_hash"`
	Items      []pluginInputItem `json:"items"`
}

type pluginInputItem struct {
	UID            string `json:"uid"`
	DeviceUID      string `json:"device_uid"`
	DeviceID       string `json:"device_id"`
	IP             string `json:"ip"`
	DeviceIP       string `json:"device_ip"`
	Hostname       string `json:"hostname"`
	Name           string `json:"name"`
	BaseURL        string `json:"base_url"`
	ProxmoxBaseURL string `json:"proxmox_base_url"`
	Endpoint       string `json:"endpoint"`
	ManagementURL  string `json:"management_url"`
	Partition      string `json:"partition"`
	Site           string `json:"site"`
}

type checkSummary struct {
	Targets           int `json:"targets"`
	Nodes             int `json:"nodes"`
	Guests            int `json:"guests"`
	QEMU              int `json:"qemu"`
	LXC               int `json:"lxc"`
	Storage           int `json:"storage"`
	NetworkInterfaces int `json:"network_interfaces"`
	Disks             int `json:"disks"`
	CephEnabledNodes  int `json:"ceph_enabled_nodes"`
	Bottleneck        int `json:"bottleneck_events"`
}

type resourceSummary struct {
	MaxNodeCPURatio       float64 `json:"max_node_cpu_ratio,omitempty"`
	MaxNodeMemRatio       float64 `json:"max_node_mem_ratio,omitempty"`
	MaxNodeIOWaitRatio    float64 `json:"max_node_io_wait_ratio,omitempty"`
	MaxNodeStorageRatio   float64 `json:"max_node_storage_ratio,omitempty"`
	MaxGuestCPURatio      float64 `json:"max_guest_cpu_ratio,omitempty"`
	MaxGuestMemRatio      float64 `json:"max_guest_mem_ratio,omitempty"`
	MaxGuestDiskRatio     float64 `json:"max_guest_disk_ratio,omitempty"`
	RunningGuests         int     `json:"running_guests,omitempty"`
	StoppedGuests         int     `json:"stopped_guests,omitempty"`
	OnlineNodes           int     `json:"online_nodes,omitempty"`
	OfflineNodes          int     `json:"offline_nodes,omitempty"`
	StorageCount          int     `json:"storage_count,omitempty"`
	NetworkInterfaceCount int     `json:"network_interface_count,omitempty"`
	DiskCount             int     `json:"disk_count,omitempty"`
	CephEnabledNodes      int     `json:"ceph_enabled_nodes,omitempty"`
	CephWarnNodes         int     `json:"ceph_warn_nodes,omitempty"`
	CephErrorNodes        int     `json:"ceph_error_nodes,omitempty"`
	ResourceBottleneck    int     `json:"resource_bottleneck_events,omitempty"`
}

type pluginResult struct {
	Status        sdk.Status        `json:"status"`
	Summary       string            `json:"summary"`
	Details       string            `json:"details,omitempty"`
	Metrics       []pluginMetric    `json:"metrics,omitempty"`
	Labels        map[string]string `json:"labels,omitempty"`
	ObservedAt    string            `json:"observed_at,omitempty"`
	SchemaVersion int               `json:"schema_version,omitempty"`
}

type pluginMetric struct {
	Name  string   `json:"name"`
	Value float64  `json:"value"`
	Unit  string   `json:"unit,omitempty"`
	Warn  *float64 `json:"warn,omitempty"`
	Crit  *float64 `json:"crit,omitempty"`
	Min   *float64 `json:"min,omitempty"`
	Max   *float64 `json:"max,omitempty"`
}

type proxmoxInventory struct {
	Version  *proxmoxVersion      `json:"version,omitempty"`
	Cluster  []proxmoxClusterNode `json:"cluster,omitempty"`
	Nodes    []proxmoxNode        `json:"nodes"`
	Guests   []proxmoxGuest       `json:"guests,omitempty"`
	Warnings map[string]string    `json:"warnings,omitempty"`
	Summary  resourceSummary      `json:"resource_summary,omitempty"`
}

type proxmoxVersionResponse struct {
	Data proxmoxVersion `json:"data"`
}

type proxmoxNodesResponse struct {
	Data []proxmoxNode `json:"data"`
}

type proxmoxResourcesResponse struct {
	Data []proxmoxResource `json:"data"`
}

type proxmoxClusterStatusResponse struct {
	Data []proxmoxClusterNode `json:"data"`
}

type proxmoxNodeStatusResponse struct {
	Data proxmoxNodeStatus `json:"data"`
}

type proxmoxStorageResponse struct {
	Data []proxmoxStorage `json:"data"`
}

type proxmoxNetworkResponse struct {
	Data []proxmoxNetworkInterface `json:"data"`
}

type proxmoxDiskResponse struct {
	Data []proxmoxDisk `json:"data"`
}

type proxmoxStringMapResponse struct {
	Data map[string]string `json:"data"`
}

type proxmoxGuestAgentNetworkResponse struct {
	Data proxmoxGuestAgentNetworkData `json:"data"`
}

type proxmoxGuestAgentFSInfoResponse struct {
	Data proxmoxGuestAgentFSInfoData `json:"data"`
}

type proxmoxLXCInterfacesResponse struct {
	Data []proxmoxLXCInterface `json:"data"`
}

type proxmoxGuestAgentNetworkData struct {
	Result []proxmoxGuestAgentInterface `json:"result"`
}

type proxmoxGuestAgentFSInfoData struct {
	Result []proxmoxGuestFilesystem `json:"result"`
}

type proxmoxGuestAgentInterface struct {
	Name            string                       `json:"name"`
	HardwareAddress string                       `json:"hardware-address"`
	IPAddresses     []proxmoxGuestAgentIPAddress `json:"ip-addresses"`
}

type proxmoxGuestAgentIPAddress struct {
	IPAddress     string `json:"ip-address"`
	IPAddressType string `json:"ip-address-type"`
	Prefix        int    `json:"prefix"`
}

type proxmoxGuestFilesystem struct {
	Name       string  `json:"name,omitempty"`
	Mountpoint string  `json:"mountpoint,omitempty"`
	Type       string  `json:"type,omitempty"`
	TotalBytes float64 `json:"total-bytes,omitempty"`
	UsedBytes  float64 `json:"used-bytes,omitempty"`
}

type proxmoxLXCInterface struct {
	Name       string `json:"name,omitempty"`
	Hardware   string `json:"hardware,omitempty"`
	MACAddress string `json:"hwaddr,omitempty"`
	Inet       string `json:"inet,omitempty"`
	Inet6      string `json:"inet6,omitempty"`
}

type proxmoxVersion struct {
	Version string `json:"version,omitempty"`
	Release string `json:"release,omitempty"`
	RepoID  string `json:"repoid,omitempty"`
}

type proxmoxClusterNode struct {
	ID      string `json:"id,omitempty"`
	Name    string `json:"name,omitempty"`
	Type    string `json:"type,omitempty"`
	NodeID  int    `json:"nodeid,omitempty"`
	Nodes   int    `json:"nodes,omitempty"`
	Quorate int    `json:"quorate,omitempty"`
	IP      string `json:"ip,omitempty"`
	Local   int    `json:"local,omitempty"`
	Online  int    `json:"online,omitempty"`
}

type proxmoxNode struct {
	Node         string                    `json:"node"`
	Status       string                    `json:"status"`
	IP           string                    `json:"ip,omitempty"`
	CPU          float64                   `json:"cpu"`
	MaxCPU       float64                   `json:"maxcpu"`
	Mem          float64                   `json:"mem"`
	MaxMem       float64                   `json:"maxmem"`
	Uptime       float64                   `json:"uptime"`
	RuntimeState proxmoxNodeStatus         `json:"runtime_status,omitempty"`
	Storage      []proxmoxStorage          `json:"storage,omitempty"`
	Network      []proxmoxNetworkInterface `json:"network,omitempty"`
	Disks        []proxmoxDisk             `json:"disks,omitempty"`
	Ceph         *proxmoxCeph              `json:"ceph,omitempty"`
}

type proxmoxNodeStatus struct {
	Wait float64 `json:"wait,omitempty"`
}

type proxmoxStorage struct {
	Storage string  `json:"storage"`
	Type    string  `json:"type,omitempty"`
	Content string  `json:"content,omitempty"`
	Used    float64 `json:"used,omitempty"`
	Avail   float64 `json:"avail,omitempty"`
	Total   float64 `json:"total,omitempty"`
}

type proxmoxNetworkInterface struct {
	Iface       string   `json:"iface"`
	Type        string   `json:"type,omitempty"`
	Method      string   `json:"method,omitempty"`
	Method6     string   `json:"method6,omitempty"`
	Address     string   `json:"address,omitempty"`
	Netmask     string   `json:"netmask,omitempty"`
	Gateway     string   `json:"gateway,omitempty"`
	CIDR        string   `json:"cidr,omitempty"`
	BridgePorts string   `json:"bridge-ports,omitempty"`
	Families    []string `json:"families,omitempty"`
}

type proxmoxDisk struct {
	DevPath string  `json:"devpath,omitempty"`
	ByID    string  `json:"by_id_link,omitempty"`
	Type    string  `json:"type,omitempty"`
	Model   string  `json:"model,omitempty"`
	Vendor  string  `json:"vendor,omitempty"`
	Used    string  `json:"used,omitempty"`
	Health  string  `json:"health,omitempty"`
	Size    float64 `json:"size,omitempty"`
}

type proxmoxCeph struct {
	Health string `json:"health,omitempty"`
}

type proxmoxCephStatusResponse struct {
	Data proxmoxCephStatus `json:"data"`
}

type proxmoxCephStatus struct {
	Health        string `json:"health,omitempty"`
	Status        string `json:"status,omitempty"`
	OverallStatus string `json:"overall_status,omitempty"`
}

type proxmoxResource struct {
	ID      string  `json:"id"`
	Node    string  `json:"node"`
	Name    string  `json:"name"`
	Type    string  `json:"type"`
	Status  string  `json:"status"`
	VMID    int     `json:"vmid"`
	CPU     float64 `json:"cpu"`
	MaxCPU  float64 `json:"maxcpu"`
	Mem     float64 `json:"mem"`
	MaxMem  float64 `json:"maxmem"`
	Disk    float64 `json:"disk"`
	MaxDisk float64 `json:"maxdisk"`
	Uptime  float64 `json:"uptime"`
}

type proxmoxGuest struct {
	proxmoxResource
	Config      map[string]string              `json:"config,omitempty"`
	Interfaces  []proxmoxGuestNetworkInterface `json:"interfaces,omitempty"`
	Filesystems []proxmoxGuestFilesystem       `json:"filesystems,omitempty"`
}

type proxmoxGuestNetworkInterface struct {
	Name        string            `json:"name,omitempty"`
	ConfigKey   string            `json:"config_key,omitempty"`
	Model       string            `json:"model,omitempty"`
	MACAddress  string            `json:"mac_address,omitempty"`
	IPAddresses []string          `json:"ip_addresses,omitempty"`
	Bridge      string            `json:"bridge,omitempty"`
	VLANID      int               `json:"vlan_id,omitempty"`
	Source      string            `json:"source,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
}

type proxmoxDetails struct {
	Schema          string            `json:"schema"`
	Targets         []proxmoxTarget   `json:"targets"`
	Summary         checkSummary      `json:"summary"`
	ResourceSummary resourceSummary   `json:"resource_summary,omitempty"`
	Errors          map[string]string `json:"errors,omitempty"`
}

type proxmoxTarget struct {
	BaseURL  string               `json:"base_url"`
	Version  *proxmoxVersion      `json:"version,omitempty"`
	Cluster  []proxmoxClusterNode `json:"cluster,omitempty"`
	Nodes    []proxmoxNode        `json:"nodes"`
	Guests   []proxmoxGuest       `json:"guests,omitempty"`
	Summary  resourceSummary      `json:"resource_summary,omitempty"`
	Warnings map[string]string    `json:"warnings,omitempty"`
	Meta     map[string]string    `json:"metadata,omitempty"`
}

//export run_check
func run_check() {
	cfg, err := loadConfig()
	if err != nil {
		_ = submitPluginResult(newPluginResult(sdk.StatusUnknown, "Proxmox configuration could not be loaded"))
		return
	}
	applyRuntimeConfigLimits(&cfg)

	result, err := runProxmoxCheck(cfg)
	if err != nil {
		_ = submitPluginResult(newPluginResult(sdk.StatusCritical, sanitizeError(err)))
		return
	}

	_ = submitPluginResult(result)
}

func loadConfig() (Config, error) {
	raw, err := loadConfigBytes()
	if err != nil {
		return defaultConfig(), err
	}
	if len(raw) == 0 {
		return defaultConfig(), nil
	}

	return configFromRawConfig(string(raw)), nil
}

func configFromJSON(raw json.RawMessage) (Config, error) {
	if looksLikePluginInputsJSON(raw) {
		return configFromPluginInputsJSON(raw)
	}

	cfg := defaultConfig()
	if err := applyConfigJSON(raw, &cfg); err != nil {
		return defaultConfig(), err
	}

	return cfg, nil
}

func configFromMap(raw map[string]any) (Config, error) {
	if looksLikePluginInputs(raw) {
		return configFromPluginInputs(raw)
	}

	cfg := defaultConfig()
	if err := applyConfigMap(raw, &cfg); err != nil {
		return defaultConfig(), err
	}

	return cfg, nil
}

func configFromRawConfig(raw string) Config {
	cfg := defaultConfig()
	cfg.BaseURL = jsonStringValue(raw, "base_url")
	cfg.APIToken = jsonStringValue(raw, "api_token")
	cfg.APITokenSecretRef = jsonStringValue(raw, "api_token_secret_ref")
	cfg.TimeoutMS = jsonIntValue(raw, "timeout_ms")
	cfg.MaxResponseBytes = jsonIntValue(raw, "max_response_bytes")
	if value, ok := jsonBoolValue(raw, "include_guests"); ok {
		cfg.IncludeGuests = &value
	}
	if value, ok := jsonBoolValue(raw, "insecure_skip_verify"); ok {
		cfg.InsecureSkipVerify = value
	}
	if value, ok := jsonBoolValue(raw, "auto_discovery_enabled"); ok {
		cfg.AutoDiscovery = value
	}

	if strings.Contains(raw, sdk.PluginInputsSchemaV1) {
		cfg.Targets = targetsFromRawPluginInputItems(raw, cfg)
		if len(cfg.Targets) > 0 {
			cfg.BaseURL = ""
		}
	}

	return cfg
}

func configFromPluginInputsJSON(raw json.RawMessage) (Config, error) {
	var payload pluginInputsJSON
	if err := json.Unmarshal(raw, &payload); err != nil {
		return defaultConfig(), err
	}

	return configFromPluginInputsPayload(payload)
}

func configFromPluginInputsPayload(payload pluginInputsJSON) (Config, error) {
	if err := validatePluginInputsJSON(payload); err != nil {
		return defaultConfig(), err
	}

	cfg := defaultConfig()
	if payload.Template != nil {
		applyConfigStruct(*payload.Template, &cfg)
	}

	generatedTargets := targetsFromPluginInputsJSON(payload, cfg)
	if len(generatedTargets) > 0 {
		cfg.Targets = append(cfg.Targets, generatedTargets...)
		cfg.Targets = dedupeTargets(cfg.Targets)
		cfg.BaseURL = ""
	}

	return cfg, nil
}

func configFromPluginInputs(raw map[string]any) (Config, error) {
	payload, err := sdk.ParsePluginInputsMap(raw)
	if err != nil {
		return defaultConfig(), err
	}

	cfg := defaultConfig()
	if payload.Template != nil {
		if err := applyConfigMap(payload.Template, &cfg); err != nil {
			return defaultConfig(), err
		}
	}

	generatedTargets := targetsFromPluginInputs(payload, cfg)
	if len(generatedTargets) > 0 {
		cfg.Targets = append(cfg.Targets, generatedTargets...)
		cfg.Targets = dedupeTargets(cfg.Targets)
		cfg.BaseURL = ""
	}

	return cfg, nil
}

func runProxmoxCheck(cfg Config) (*pluginResult, error) {
	cfg.applyDefaults()
	applyHTTPClientLimits(cfg)

	targets := cfg.effectiveTargets()
	if len(targets) == 0 {
		return nil, errMissingTarget
	}

	now := time.Now().UTC()
	details := proxmoxDetails{
		Schema:  "serviceradar.proxmox_enrichment.v1",
		Targets: make([]proxmoxTarget, 0, len(targets)),
		Errors:  map[string]string{},
	}

	for _, target := range targets {
		inventory, err := fetchTargetInventory(cfg, target)
		if err != nil {
			details.Errors[target.safeName()] = sanitizeError(err)
			continue
		}

		details.Targets = append(details.Targets, proxmoxTarget{
			BaseURL:  target.redactedBaseURL(),
			Version:  inventory.Version,
			Cluster:  inventory.Cluster,
			Nodes:    inventory.Nodes,
			Guests:   inventory.Guests,
			Summary:  inventory.Summary,
			Warnings: inventory.Warnings,
			Meta:     targetMetadata(target),
		})
		details.Summary.Targets++
		details.Summary.Nodes += len(inventory.Nodes)
		details.Summary.Guests += len(inventory.Guests)
		details.Summary.QEMU += countGuests(inventory.Guests, "qemu")
		details.Summary.LXC += countGuests(inventory.Guests, "lxc")
		details.Summary.Storage += inventory.Summary.StorageCount
		details.Summary.NetworkInterfaces += inventory.Summary.NetworkInterfaceCount
		details.Summary.Disks += inventory.Summary.DiskCount
		details.Summary.CephEnabledNodes += inventory.Summary.CephEnabledNodes
		details.Summary.Bottleneck += inventory.Summary.ResourceBottleneck
		details.ResourceSummary = mergeResourceSummary(details.ResourceSummary, inventory.Summary)
	}

	if details.Summary.Targets == 0 {
		return nil, fmt.Errorf("all Proxmox targets failed: %s", joinErrors(details.Errors))
	}

	if len(details.Errors) == 0 {
		details.Errors = nil
	}

	body, err := marshalProxmoxDetails(details)
	if err != nil {
		return nil, fmt.Errorf("encode details: %w", err)
	}

	status := sdk.StatusOK
	summary := fmt.Sprintf(
		"Proxmox inventory: %d target(s), %d node(s), %d guest(s)",
		details.Summary.Targets,
		details.Summary.Nodes,
		details.Summary.Guests,
	)
	if len(details.Errors) > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d target error(s)", len(details.Errors))
	}
	if details.Summary.Bottleneck > 0 {
		status = sdk.StatusWarning
		summary += fmt.Sprintf(", %d resource bottleneck(s)", details.Summary.Bottleneck)
	}

	result := newPluginResult(status, summary)
	result.Details = string(body)
	result.ObservedAt = now.Format(time.RFC3339Nano)
	result.AddMetric("proxmox_targets", float64(details.Summary.Targets), "count", nil)
	result.AddMetric("proxmox_nodes", float64(details.Summary.Nodes), "count", nil)
	result.AddMetric("proxmox_guests", float64(details.Summary.Guests), "count", nil)
	result.AddMetric("proxmox_qemu_guests", float64(details.Summary.QEMU), "count", nil)
	result.AddMetric("proxmox_lxc_guests", float64(details.Summary.LXC), "count", nil)
	result.AddMetric("proxmox_storage", float64(details.Summary.Storage), "count", nil)
	result.AddMetric("proxmox_network_interfaces", float64(details.Summary.NetworkInterfaces), "count", nil)
	result.AddMetric("proxmox_disks", float64(details.Summary.Disks), "count", nil)
	result.AddMetric("proxmox_ceph_enabled_nodes", float64(details.Summary.CephEnabledNodes), "count", nil)
	result.AddMetric("proxmox_ceph_warn_nodes", float64(details.ResourceSummary.CephWarnNodes), "count", sdk.Thresholds(1, 1))
	result.AddMetric("proxmox_ceph_error_nodes", float64(details.ResourceSummary.CephErrorNodes), "count", sdk.Thresholds(1, 1))
	result.AddMetric("proxmox_node_cpu_ratio_max", details.ResourceSummary.MaxNodeCPURatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_node_mem_ratio_max", details.ResourceSummary.MaxNodeMemRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_node_io_wait_ratio_max", details.ResourceSummary.MaxNodeIOWaitRatio, "ratio", sdk.Thresholds(0.20, 0.40))
	result.AddMetric("proxmox_node_storage_ratio_max", details.ResourceSummary.MaxNodeStorageRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_cpu_ratio_max", details.ResourceSummary.MaxGuestCPURatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_mem_ratio_max", details.ResourceSummary.MaxGuestMemRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddMetric("proxmox_guest_disk_ratio_max", details.ResourceSummary.MaxGuestDiskRatio, "ratio", sdk.Thresholds(0.80, 0.90))
	result.AddLabel("plugin_id", pluginID)

	return result, nil
}

func defaultConfig() Config {
	return Config{TimeoutMS: defaultTimeoutMS}
}

func newPluginResult(status sdk.Status, summary string) *pluginResult {
	if status == "" {
		status = sdk.StatusUnknown
	}
	if strings.TrimSpace(summary) == "" {
		summary = string(status)
	}

	return &pluginResult{
		Status:        status,
		Summary:       summary,
		SchemaVersion: 1,
		ObservedAt:    time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func (r *pluginResult) AddMetric(name string, value float64, unit string, thresholds *sdk.ThresholdSpec) {
	if r == nil || strings.TrimSpace(name) == "" {
		return
	}

	metric := pluginMetric{Name: name, Value: value, Unit: unit}
	if thresholds != nil {
		metric.Warn = thresholds.Warn
		metric.Crit = thresholds.Crit
		metric.Min = thresholds.Min
		metric.Max = thresholds.Max
	}
	r.Metrics = append(r.Metrics, metric)
}

func (r *pluginResult) AddLabel(key, value string) {
	if r == nil || strings.TrimSpace(key) == "" {
		return
	}
	if r.Labels == nil {
		r.Labels = map[string]string{}
	}
	r.Labels[key] = value
}

func submitPluginResult(result *pluginResult) error {
	if result == nil {
		result = newPluginResult(sdk.StatusUnknown, "")
	}
	if result.SchemaVersion == 0 {
		result.SchemaVersion = 1
	}
	if result.ObservedAt == "" {
		result.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}

	return sdk.SubmitResult(result.JSON())
}

func (r *pluginResult) JSON() []byte {
	var b strings.Builder
	b.WriteString(`{"status":`)
	b.WriteString(strconv.Quote(string(r.Status)))
	b.WriteString(`,"summary":`)
	b.WriteString(strconv.Quote(r.Summary))
	if r.Details != "" {
		b.WriteString(`,"details":`)
		b.WriteString(strconv.Quote(r.Details))
	}
	if len(r.Metrics) > 0 {
		b.WriteString(`,"metrics":[`)
		for i, metric := range r.Metrics {
			if i > 0 {
				b.WriteByte(',')
			}
			appendMetricJSON(&b, metric)
		}
		b.WriteByte(']')
	}
	if len(r.Labels) > 0 {
		b.WriteString(`,"labels":{`)
		keys := make([]string, 0, len(r.Labels))
		for key := range r.Labels {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.Quote(key))
			b.WriteByte(':')
			b.WriteString(strconv.Quote(r.Labels[key]))
		}
		b.WriteByte('}')
	}
	if r.ObservedAt != "" {
		b.WriteString(`,"observed_at":`)
		b.WriteString(strconv.Quote(r.ObservedAt))
	}
	if r.SchemaVersion > 0 {
		b.WriteString(`,"schema_version":`)
		b.WriteString(strconv.Itoa(r.SchemaVersion))
	}
	b.WriteByte('}')

	return []byte(b.String())
}

func appendMetricJSON(b *strings.Builder, metric pluginMetric) {
	b.WriteString(`{"name":`)
	b.WriteString(strconv.Quote(metric.Name))
	b.WriteString(`,"value":`)
	b.WriteString(strconv.FormatFloat(metric.Value, 'f', -1, 64))
	if metric.Unit != "" {
		b.WriteString(`,"unit":`)
		b.WriteString(strconv.Quote(metric.Unit))
	}
	appendOptionalFloat(b, "warn", metric.Warn)
	appendOptionalFloat(b, "crit", metric.Crit)
	appendOptionalFloat(b, "min", metric.Min)
	appendOptionalFloat(b, "max", metric.Max)
	b.WriteByte('}')
}

func appendOptionalFloat(b *strings.Builder, key string, value *float64) {
	if value == nil {
		return
	}
	b.WriteByte(',')
	b.WriteString(strconv.Quote(key))
	b.WriteByte(':')
	b.WriteString(strconv.FormatFloat(*value, 'f', -1, 64))
}

func applyConfigMap(raw map[string]any, cfg *Config) error {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(encoded, cfg); err != nil {
		return err
	}

	return nil
}

func applyConfigJSON(raw json.RawMessage, cfg *Config) error {
	var decoded configJSON
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return err
	}

	applyConfigStruct(decoded, cfg)

	return nil
}

func applyConfigStruct(decoded configJSON, cfg *Config) {
	cfg.BaseURL = decoded.BaseURL
	cfg.APIToken = decoded.APIToken
	cfg.APITokenSecretRef = decoded.APITokenSecretRef
	cfg.Targets = decoded.Targets
	cfg.TimeoutMS = decoded.TimeoutMS
	cfg.MaxResponseBytes = decoded.MaxResponseBytes
	cfg.IncludeGuests = decoded.IncludeGuests
	cfg.InsecureSkipVerify = decoded.InsecureSkipVerify
	cfg.AutoDiscovery = decoded.AutoDiscovery
}

func fetchTargetInventory(cfg Config, target Target) (proxmoxInventory, error) {
	token := normalizeProxmoxAPIToken(firstNonEmpty(target.APIToken, cfg.APIToken))
	if token == "" {
		return proxmoxInventory{}, errMissingToken
	}

	inventory := proxmoxInventory{Warnings: map[string]string{}}

	version, err := fetchVersion(cfg, target, token)
	if err != nil {
		inventory.Warnings["version"] = sanitizeError(err)
	} else {
		inventory.Version = &version
	}

	cluster, err := fetchClusterStatus(cfg, target, token)
	if err != nil {
		inventory.Warnings["cluster_status"] = sanitizeError(err)
	} else {
		inventory.Cluster = cluster
	}

	nodes, err := fetchNodes(cfg, target, token)
	if err != nil {
		return proxmoxInventory{}, err
	}
	inventory.Nodes = annotateNodesWithClusterStatus(
		enrichNodes(cfg, target, token, nodes, inventory.Warnings),
		inventory.Cluster,
	)

	if !cfg.includeGuests() {
		inventory.Summary = summarizeInventory(inventory.Nodes, nil)
		inventory.Warnings = nilIfEmpty(inventory.Warnings)
		return inventory, nil
	}

	guests, err := fetchGuests(cfg, target, token)
	if err != nil {
		return proxmoxInventory{}, err
	}
	inventory.Guests = enrichGuests(cfg, target, token, guests, inventory.Warnings)
	inventory.Summary = summarizeInventory(inventory.Nodes, inventory.Guests)
	inventory.Warnings = nilIfEmpty(inventory.Warnings)

	return inventory, nil
}

func fetchVersion(cfg Config, target Target, token string) (proxmoxVersion, error) {
	var envelope proxmoxVersionResponse
	if err := getJSON(cfg, target, token, "/api2/json/version", &envelope); err != nil {
		return proxmoxVersion{}, fmt.Errorf("fetch version: %w", err)
	}

	return envelope.Data, nil
}

func fetchClusterStatus(cfg Config, target Target, token string) ([]proxmoxClusterNode, error) {
	var envelope proxmoxClusterStatusResponse
	if err := getJSON(cfg, target, token, "/api2/json/cluster/status", &envelope); err != nil {
		return nil, fmt.Errorf("fetch cluster status: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodes(cfg Config, target Target, token string) ([]proxmoxNode, error) {
	var envelope proxmoxNodesResponse
	if err := getJSON(cfg, target, token, "/api2/json/nodes", &envelope); err != nil {
		return nil, fmt.Errorf("fetch nodes: %w", err)
	}

	return envelope.Data, nil
}

func fetchGuests(cfg Config, target Target, token string) ([]proxmoxResource, error) {
	var envelope proxmoxResourcesResponse
	if err := getJSON(cfg, target, token, "/api2/json/cluster/resources?type=vm", &envelope); err != nil {
		return nil, fmt.Errorf("fetch guests: %w", err)
	}

	return envelope.Data, nil
}

func enrichNodes(cfg Config, target Target, token string, nodes []proxmoxNode, warnings map[string]string) []proxmoxNode {
	out := make([]proxmoxNode, 0, len(nodes))
	for _, node := range nodes {
		status, err := fetchNodeStatus(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":status"] = sanitizeError(err)
		} else {
			node.RuntimeState = status
		}

		storage, err := fetchNodeStorage(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":storage"] = sanitizeError(err)
		} else {
			node.Storage = storage
		}

		network, err := fetchNodeNetwork(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":network"] = sanitizeError(err)
		} else {
			node.Network = network
		}

		disks, err := fetchNodeDisks(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":disks"] = sanitizeError(err)
		} else {
			node.Disks = disks
		}

		ceph, err := fetchNodeCeph(cfg, target, token, node.Node)
		if err != nil {
			warnings["node:"+node.Node+":ceph"] = sanitizeError(err)
		} else if !ceph.empty() {
			node.Ceph = &ceph
		}
		out = append(out, node)
	}

	return out
}

func annotateNodesWithClusterStatus(nodes []proxmoxNode, cluster []proxmoxClusterNode) []proxmoxNode {
	if len(nodes) == 0 || len(cluster) == 0 {
		return nodes
	}

	clusterByNode := make(map[string]proxmoxClusterNode, len(cluster))
	for _, entry := range cluster {
		if !strings.EqualFold(strings.TrimSpace(entry.Type), "node") {
			continue
		}
		name := firstNonEmpty(entry.Name, strings.TrimPrefix(entry.ID, "node/"))
		if name == "" {
			continue
		}
		clusterByNode[strings.ToLower(name)] = entry
	}

	out := make([]proxmoxNode, 0, len(nodes))
	for _, node := range nodes {
		if entry, ok := clusterByNode[strings.ToLower(strings.TrimSpace(node.Node))]; ok {
			if node.IP == "" {
				node.IP = strings.TrimSpace(entry.IP)
			}
		}
		if node.IP == "" {
			node.IP = primaryNodeIP(node.Network)
		}
		out = append(out, node)
	}

	return out
}

func primaryNodeIP(interfaces []proxmoxNetworkInterface) string {
	for _, iface := range interfaces {
		if ip := normalizedNodeIP(iface.Address); ip != "" {
			return ip
		}
		if ip := normalizedNodeIP(iface.CIDR); ip != "" {
			return ip
		}
	}

	return ""
}

func normalizedNodeIP(value string) string {
	value = stripIPPrefix(value)
	if value == "" {
		return ""
	}

	lower := strings.ToLower(value)
	if lower == "127.0.0.1" || lower == "::1" || strings.HasPrefix(lower, "169.254.") || strings.HasPrefix(lower, "fe80:") {
		return ""
	}

	return value
}

func fetchNodeStatus(cfg Config, target Target, token, node string) (proxmoxNodeStatus, error) {
	var envelope proxmoxNodeStatusResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return proxmoxNodeStatus{}, fmt.Errorf("fetch node status: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeStorage(cfg Config, target Target, token, node string) ([]proxmoxStorage, error) {
	var envelope proxmoxStorageResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/storage"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node storage: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeNetwork(cfg Config, target Target, token, node string) ([]proxmoxNetworkInterface, error) {
	var envelope proxmoxNetworkResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/network"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node network: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeDisks(cfg Config, target Target, token, node string) ([]proxmoxDisk, error) {
	var envelope proxmoxDiskResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/disks/list"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node disks: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeCeph(cfg Config, target Target, token, node string) (proxmoxCeph, error) {
	status, err := fetchNodeCephStatus(cfg, target, token, node)
	if err != nil {
		return proxmoxCeph{}, err
	}

	ceph := proxmoxCeph{
		Health: cephHealth(status),
	}

	return ceph, nil
}

func fetchNodeCephStatus(cfg Config, target Target, token, node string) (proxmoxCephStatus, error) {
	var envelope proxmoxCephStatusResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/ceph/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return proxmoxCephStatus{}, fmt.Errorf("fetch node ceph status: %w", err)
	}

	return envelope.Data, nil
}

func enrichGuests(cfg Config, target Target, token string, guests []proxmoxResource, warnings map[string]string) []proxmoxGuest {
	out := make([]proxmoxGuest, 0, len(guests))
	for _, resource := range guests {
		guest := proxmoxGuest{proxmoxResource: resource}
		kind := guestEndpointKind(resource.Type)
		if kind == "" || resource.Node == "" || resource.VMID <= 0 {
			out = append(out, guest)
			continue
		}

		config, err := fetchGuestConfig(cfg, target, token, resource.Node, kind, resource.VMID)
		if err != nil {
			warnings[fmt.Sprintf("guest:%s:%d:config", kind, resource.VMID)] = sanitizeError(err)
		} else {
			guest.Config = sanitizeStringMap(config)
			guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromGuestConfig(guest.Config))
		}

		if kind == "qemu" && strings.EqualFold(resource.Status, "running") {
			agentInterfaces, err := fetchGuestAgentNetworkInterfaces(cfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:agent_network", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromGuestAgent(agentInterfaces))
			}

			filesystems, err := fetchGuestAgentFilesystems(cfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:agent_filesystems", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Filesystems = filterGuestFilesystems(filesystems)
				if used, total := summarizeGuestFilesystems(guest.Filesystems); total > 0 {
					guest.Disk = used
					guest.MaxDisk = total
				}
			}
		}

		if kind == "lxc" && strings.EqualFold(resource.Status, "running") {
			lxcInterfaces, err := fetchLXCInterfaces(cfg, target, token, resource.Node, resource.VMID)
			if err != nil {
				warnings[fmt.Sprintf("guest:%s:%d:interfaces", kind, resource.VMID)] = sanitizeError(err)
			} else {
				guest.Interfaces = mergeGuestInterfaces(guest.Interfaces, interfacesFromLXCInterfaces(lxcInterfaces))
			}
		}

		out = append(out, guest)
	}

	return out
}

func fetchGuestConfig(cfg Config, target Target, token, node, kind string, vmid int) (map[string]string, error) {
	var envelope proxmoxStringMapResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/%s/%d/config", url.PathEscape(node), kind, vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest config: %w", err)
	}

	return envelope.Data, nil
}

func fetchGuestAgentNetworkInterfaces(cfg Config, target Target, token, node string, vmid int) ([]proxmoxGuestAgentInterface, error) {
	var envelope proxmoxGuestAgentNetworkResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/qemu/%d/agent/network-get-interfaces", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest agent network interfaces: %w", err)
	}

	return envelope.Data.Result, nil
}

func fetchGuestAgentFilesystems(cfg Config, target Target, token, node string, vmid int) ([]proxmoxGuestFilesystem, error) {
	var envelope proxmoxGuestAgentFSInfoResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/qemu/%d/agent/get-fsinfo", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest agent filesystems: %w", err)
	}

	return envelope.Data.Result, nil
}

func fetchLXCInterfaces(cfg Config, target Target, token, node string, vmid int) ([]proxmoxLXCInterface, error) {
	var envelope proxmoxLXCInterfacesResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/lxc/%d/interfaces", url.PathEscape(node), vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch lxc interfaces: %w", err)
	}

	return envelope.Data, nil
}

func interfacesFromGuestConfig(config map[string]string) []proxmoxGuestNetworkInterface {
	if len(config) == 0 {
		return nil
	}

	keys := make([]string, 0, len(config))
	for key := range config {
		if isGuestNetConfigKey(key) {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)

	out := make([]proxmoxGuestNetworkInterface, 0, len(keys))
	for _, key := range keys {
		raw := config[key]
		if strings.TrimSpace(raw) == "" {
			continue
		}

		iface := interfaceFromGuestConfigValue(key, raw)
		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		out = append(out, iface)
	}

	return out
}

func isGuestNetConfigKey(key string) bool {
	if !strings.HasPrefix(key, "net") || len(key) == 3 {
		return false
	}
	for _, r := range key[3:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func interfaceFromGuestConfigValue(configKey, raw string) proxmoxGuestNetworkInterface {
	values := parseProxmoxConfigList(raw)
	iface := proxmoxGuestNetworkInterface{
		ConfigKey: configKey,
		Name:      firstNonEmpty(values["name"], configKey),
		Bridge:    values["bridge"],
		Source:    "config",
		Metadata:  map[string]string{"config": raw},
	}

	if vlanID := parsePositiveInt(firstNonEmpty(values["tag"], values["vlan-id"], values["vlan_id"])); vlanID > 0 {
		iface.VLANID = vlanID
	}

	for _, key := range []string{"hwaddr", "macaddr", "mac"} {
		if mac := normalizeMACForOutput(values[key]); mac != "" {
			iface.MACAddress = mac
			break
		}
	}

	if iface.MACAddress == "" {
		for _, model := range []string{"virtio", "e1000", "e1000e", "rtl8139", "vmxnet3", "ne2k_pci", "i82551", "i82557b", "i82559er"} {
			if mac := normalizeMACForOutput(values[model]); mac != "" {
				iface.MACAddress = mac
				iface.Model = model
				break
			}
		}
	}

	if iface.Model == "" {
		iface.Model = firstNonEmpty(values["type"], values["model"])
	}

	for _, key := range []string{"ip", "ip6"} {
		if ip := normalizeGuestIP(values[key]); ip != "" {
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}
	}

	return iface
}

func parseProxmoxConfigList(raw string) map[string]string {
	values := map[string]string{}
	for _, part := range strings.Split(raw, ",") {
		key, value, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		if key != "" && value != "" {
			values[key] = value
		}
	}
	return values
}

func interfacesFromGuestAgent(agentInterfaces []proxmoxGuestAgentInterface) []proxmoxGuestNetworkInterface {
	out := make([]proxmoxGuestNetworkInterface, 0, len(agentInterfaces))
	for _, agentIface := range agentInterfaces {
		iface := proxmoxGuestNetworkInterface{
			Name:       agentIface.Name,
			MACAddress: normalizeMACForOutput(agentIface.HardwareAddress),
			Source:     "guest_agent",
		}

		for _, address := range agentIface.IPAddresses {
			ip := normalizeGuestIP(address.IPAddress)
			if ip == "" || isLoopbackOrLinkLocal(ip) {
				continue
			}
			if address.Prefix > 0 && !strings.Contains(ip, "/") {
				ip = fmt.Sprintf("%s/%d", ip, address.Prefix)
			}
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}

		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		out = append(out, iface)
	}

	return out
}

func interfacesFromLXCInterfaces(lxcInterfaces []proxmoxLXCInterface) []proxmoxGuestNetworkInterface {
	out := make([]proxmoxGuestNetworkInterface, 0, len(lxcInterfaces))
	for _, lxcIface := range lxcInterfaces {
		iface := proxmoxGuestNetworkInterface{
			Name:       lxcIface.Name,
			MACAddress: normalizeMACForOutput(firstNonEmpty(lxcIface.MACAddress, lxcIface.Hardware)),
			Source:     "lxc_interfaces",
		}

		for _, ip := range []string{lxcIface.Inet, lxcIface.Inet6} {
			ip = normalizeGuestIP(ip)
			if ip == "" || isLoopbackOrLinkLocal(ip) {
				continue
			}
			iface.IPAddresses = appendUniqueString(iface.IPAddresses, ip)
		}

		if iface.MACAddress == "" && len(iface.IPAddresses) == 0 {
			continue
		}
		out = append(out, iface)
	}

	return out
}

func filterGuestFilesystems(filesystems []proxmoxGuestFilesystem) []proxmoxGuestFilesystem {
	out := make([]proxmoxGuestFilesystem, 0, len(filesystems))
	for _, fs := range filesystems {
		if fs.TotalBytes <= 0 || ignoredGuestFilesystem(fs) {
			continue
		}
		out = append(out, fs)
	}
	return out
}

func summarizeGuestFilesystems(filesystems []proxmoxGuestFilesystem) (float64, float64) {
	var used, total float64
	for _, fs := range filesystems {
		if fs.TotalBytes <= 0 {
			continue
		}
		used += fs.UsedBytes
		total += fs.TotalBytes
	}
	return used, total
}

func ignoredGuestFilesystem(fs proxmoxGuestFilesystem) bool {
	fsType := strings.ToLower(strings.TrimSpace(fs.Type))
	switch fsType {
	case "tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2", "overlay", "squashfs",
		"tracefs", "debugfs", "securityfs", "pstore", "bpf", "fusectl", "mqueue", "hugetlbfs",
		"rpc_pipefs", "nsfs", "autofs":
		return true
	}

	mountpoint := strings.TrimSpace(fs.Mountpoint)
	return strings.HasPrefix(mountpoint, "/proc") ||
		strings.HasPrefix(mountpoint, "/sys") ||
		strings.HasPrefix(mountpoint, "/dev") ||
		strings.HasPrefix(mountpoint, "/run")
}

func mergeGuestInterfaces(left, right []proxmoxGuestNetworkInterface) []proxmoxGuestNetworkInterface {
	out := append([]proxmoxGuestNetworkInterface{}, left...)
	for _, incoming := range right {
		idx := findGuestInterface(out, incoming)
		if idx < 0 {
			out = append(out, incoming)
			continue
		}

		current := out[idx]
		current.Name = firstNonEmpty(current.Name, incoming.Name)
		current.ConfigKey = firstNonEmpty(current.ConfigKey, incoming.ConfigKey)
		current.Model = firstNonEmpty(current.Model, incoming.Model)
		current.MACAddress = firstNonEmpty(current.MACAddress, incoming.MACAddress)
		current.Bridge = firstNonEmpty(current.Bridge, incoming.Bridge)
		if current.VLANID == 0 {
			current.VLANID = incoming.VLANID
		}
		current.Source = mergeSource(current.Source, incoming.Source)
		current.IPAddresses = appendUniqueStrings(current.IPAddresses, incoming.IPAddresses)
		current.Metadata = mergeMetadata(current.Metadata, incoming.Metadata)
		out[idx] = current
	}

	return out
}

func findGuestInterface(interfaces []proxmoxGuestNetworkInterface, incoming proxmoxGuestNetworkInterface) int {
	incomingMAC := normalizeMACKey(incoming.MACAddress)
	for idx, candidate := range interfaces {
		if incomingMAC != "" && normalizeMACKey(candidate.MACAddress) == incomingMAC {
			return idx
		}
		if incoming.Name != "" && candidate.Name != "" && strings.EqualFold(candidate.Name, incoming.Name) {
			return idx
		}
		if incoming.ConfigKey != "" && candidate.ConfigKey != "" && candidate.ConfigKey == incoming.ConfigKey {
			return idx
		}
	}

	return -1
}

func mergeSource(left, right string) string {
	switch {
	case left == "":
		return right
	case right == "", left == right:
		return left
	case strings.Contains(left, right):
		return left
	case strings.Contains(right, left):
		return right
	default:
		return left + "," + right
	}
}

func mergeMetadata(left, right map[string]string) map[string]string {
	if len(left) == 0 {
		return right
	}
	if len(right) == 0 {
		return left
	}
	merged := make(map[string]string, len(left)+len(right))
	for key, value := range left {
		merged[key] = value
	}
	for key, value := range right {
		if _, exists := merged[key]; !exists {
			merged[key] = value
		}
	}
	return merged
}

func getJSON[T any](cfg Config, target Target, token, path string, out *T) error {
	resp, err := proxmoxHTTP.Do(sdk.HTTPRequest{
		Method:             http.MethodGet,
		URL:                strings.TrimRight(target.BaseURL, "/") + path,
		Headers:            map[string]string{"Authorization": token, "Accept": "application/json"},
		TimeoutMS:          cfg.TimeoutMS,
		InsecureSkipVerify: cfg.InsecureSkipVerify,
	})
	if err != nil {
		return err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return fmt.Errorf("HTTP %d%s", resp.Status, responseBodySuffix(resp.Body))
	}
	if err := decodeProxmoxJSON(resp.Body, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	return nil
}

func decodeProxmoxJSON[T any](body []byte, out *T) error {
	raw := string(body)

	switch typed := any(out).(type) {
	case *proxmoxVersionResponse:
		data := jsonDataObject(raw)
		typed.Data = proxmoxVersion{
			Version: jsonStringValue(data, "version"),
			Release: jsonStringValue(data, "release"),
			RepoID:  jsonStringValue(data, "repoid"),
		}
	case *proxmoxNodesResponse:
		typed.Data = parseProxmoxNodes(jsonDataArray(raw))
	case *proxmoxResourcesResponse:
		typed.Data = parseProxmoxResources(jsonDataArray(raw))
	case *proxmoxClusterStatusResponse:
		typed.Data = parseProxmoxClusterNodes(jsonDataArray(raw))
	case *proxmoxNodeStatusResponse:
		data := jsonDataObject(raw)
		typed.Data = proxmoxNodeStatus{Wait: jsonFloatValue(data, "wait")}
	case *proxmoxStorageResponse:
		typed.Data = parseProxmoxStorage(jsonDataArray(raw))
	case *proxmoxNetworkResponse:
		typed.Data = parseProxmoxNetwork(jsonDataArray(raw))
	case *proxmoxDiskResponse:
		typed.Data = parseProxmoxDisks(jsonDataArray(raw))
	case *proxmoxCephStatusResponse:
		data := jsonDataObject(raw)
		health := jsonStringValue(data, "health")
		if healthObject := jsonObjectValue(data, "health"); healthObject != "" {
			health = firstNonEmpty(jsonStringValue(healthObject, "status"), health)
		}
		typed.Data = proxmoxCephStatus{
			Health:        health,
			Status:        jsonStringValue(data, "status"),
			OverallStatus: jsonStringValue(data, "overall_status"),
		}
	case *proxmoxStringMapResponse:
		typed.Data = jsonObjectStringMap(jsonDataObject(raw))
	case *proxmoxGuestAgentNetworkResponse:
		typed.Data.Result = parseGuestAgentInterfaces(jsonArrayValue(jsonDataObject(raw), "result"))
	case *proxmoxGuestAgentFSInfoResponse:
		typed.Data.Result = parseGuestFilesystems(jsonArrayValue(jsonDataObject(raw), "result"))
	case *proxmoxLXCInterfacesResponse:
		typed.Data = parseLXCInterfaces(jsonDataArray(raw))
	default:
		return fmt.Errorf("unsupported proxmox response type")
	}

	return nil
}

func jsonDataArray(raw string) string {
	return jsonArrayValue(raw, "data")
}

func jsonDataObject(raw string) string {
	return jsonObjectValue(raw, "data")
}

func jsonArrayValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end || raw[start] != '[' {
		return ""
	}

	return raw[start:end]
}

func jsonObjectValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end || raw[start] != '{' {
		return ""
	}

	return raw[start:end]
}

func parseProxmoxNodes(array string) []proxmoxNode {
	items := rawJSONObjectList(array)
	out := make([]proxmoxNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNode{
			Node:   jsonStringValue(item, "node"),
			Status: jsonStringValue(item, "status"),
			IP:     jsonStringValue(item, "ip"),
			CPU:    jsonFloatValue(item, "cpu"),
			MaxCPU: jsonFloatValue(item, "maxcpu"),
			Mem:    jsonFloatValue(item, "mem"),
			MaxMem: jsonFloatValue(item, "maxmem"),
			Uptime: jsonFloatValue(item, "uptime"),
		})
	}

	return out
}

func parseProxmoxResources(array string) []proxmoxResource {
	items := rawJSONObjectList(array)
	out := make([]proxmoxResource, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxResource{
			ID:      jsonStringValue(item, "id"),
			Node:    jsonStringValue(item, "node"),
			Name:    jsonStringValue(item, "name"),
			Type:    jsonStringValue(item, "type"),
			Status:  jsonStringValue(item, "status"),
			VMID:    jsonIntValue(item, "vmid"),
			CPU:     jsonFloatValue(item, "cpu"),
			MaxCPU:  jsonFloatValue(item, "maxcpu"),
			Mem:     jsonFloatValue(item, "mem"),
			MaxMem:  jsonFloatValue(item, "maxmem"),
			Disk:    jsonFloatValue(item, "disk"),
			MaxDisk: jsonFloatValue(item, "maxdisk"),
			Uptime:  jsonFloatValue(item, "uptime"),
		})
	}

	return out
}

func parseProxmoxClusterNodes(array string) []proxmoxClusterNode {
	items := rawJSONObjectList(array)
	out := make([]proxmoxClusterNode, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxClusterNode{
			ID:      jsonStringValue(item, "id"),
			Name:    jsonStringValue(item, "name"),
			Type:    jsonStringValue(item, "type"),
			NodeID:  jsonIntValue(item, "nodeid"),
			Nodes:   jsonIntValue(item, "nodes"),
			Quorate: jsonIntValue(item, "quorate"),
			IP:      jsonStringValue(item, "ip"),
			Local:   jsonIntValue(item, "local"),
			Online:  jsonIntValue(item, "online"),
		})
	}

	return out
}

func parseProxmoxStorage(array string) []proxmoxStorage {
	items := rawJSONObjectList(array)
	out := make([]proxmoxStorage, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxStorage{
			Storage: jsonStringValue(item, "storage"),
			Type:    jsonStringValue(item, "type"),
			Content: jsonStringValue(item, "content"),
			Used:    jsonFloatValue(item, "used"),
			Avail:   jsonFloatValue(item, "avail"),
			Total:   jsonFloatValue(item, "total"),
		})
	}

	return out
}

func parseProxmoxNetwork(array string) []proxmoxNetworkInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxNetworkInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxNetworkInterface{
			Iface:       jsonStringValue(item, "iface"),
			Type:        jsonStringValue(item, "type"),
			Method:      jsonStringValue(item, "method"),
			Method6:     jsonStringValue(item, "method6"),
			Address:     jsonStringValue(item, "address"),
			Netmask:     jsonStringValue(item, "netmask"),
			Gateway:     jsonStringValue(item, "gateway"),
			CIDR:        jsonStringValue(item, "cidr"),
			BridgePorts: jsonStringValue(item, "bridge-ports"),
			Families:    jsonStringArrayValue(item, "families"),
		})
	}

	return out
}

func parseProxmoxDisks(array string) []proxmoxDisk {
	items := rawJSONObjectList(array)
	out := make([]proxmoxDisk, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxDisk{
			DevPath: jsonStringValue(item, "devpath"),
			ByID:    jsonStringValue(item, "by_id_link"),
			Type:    jsonStringValue(item, "type"),
			Model:   jsonStringValue(item, "model"),
			Vendor:  jsonStringValue(item, "vendor"),
			Used:    jsonStringValue(item, "used"),
			Health:  jsonStringValue(item, "health"),
			Size:    jsonFloatValue(item, "size"),
		})
	}

	return out
}

func parseGuestAgentInterfaces(array string) []proxmoxGuestAgentInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestAgentInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentInterface{
			Name:            jsonStringValue(item, "name"),
			HardwareAddress: jsonStringValue(item, "hardware-address"),
			IPAddresses:     parseGuestAgentIPAddresses(jsonArrayValue(item, "ip-addresses")),
		})
	}

	return out
}

func parseGuestAgentIPAddresses(array string) []proxmoxGuestAgentIPAddress {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestAgentIPAddress, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestAgentIPAddress{
			IPAddress:     jsonStringValue(item, "ip-address"),
			IPAddressType: jsonStringValue(item, "ip-address-type"),
			Prefix:        jsonIntValue(item, "prefix"),
		})
	}

	return out
}

func parseGuestFilesystems(array string) []proxmoxGuestFilesystem {
	items := rawJSONObjectList(array)
	out := make([]proxmoxGuestFilesystem, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxGuestFilesystem{
			Name:       jsonStringValue(item, "name"),
			Mountpoint: jsonStringValue(item, "mountpoint"),
			Type:       jsonStringValue(item, "type"),
			TotalBytes: jsonFloatValue(item, "total-bytes"),
			UsedBytes:  jsonFloatValue(item, "used-bytes"),
		})
	}

	return out
}

func parseLXCInterfaces(array string) []proxmoxLXCInterface {
	items := rawJSONObjectList(array)
	out := make([]proxmoxLXCInterface, 0, len(items))
	for _, item := range items {
		out = append(out, proxmoxLXCInterface{
			Name:       jsonStringValue(item, "name"),
			Hardware:   jsonStringValue(item, "hardware"),
			MACAddress: jsonStringValue(item, "hwaddr"),
			Inet:       jsonStringValue(item, "inet"),
			Inet6:      jsonStringValue(item, "inet6"),
		})
	}

	return out
}

func jsonObjectStringMap(object string) map[string]string {
	object = strings.TrimSpace(object)
	if len(object) < 2 || object[0] != '{' {
		return nil
	}
	out := map[string]string{}
	for i := 1; i < len(object)-1; {
		i = skipJSONWhitespace(object, i)
		if i >= len(object)-1 || object[i] == '}' {
			break
		}
		if object[i] != '"' {
			i++
			continue
		}
		keyEnd := jsonStringEnd(object, i)
		if keyEnd < 0 {
			break
		}
		key, err := strconv.Unquote(object[i : keyEnd+1])
		if err != nil {
			break
		}
		colon := skipJSONWhitespace(object, keyEnd+1)
		if colon >= len(object) || object[colon] != ':' {
			i = keyEnd + 1
			continue
		}
		valueStart := skipJSONWhitespace(object, colon+1)
		valueEnd := jsonValueEnd(object, valueStart)
		if valueEnd < 0 {
			break
		}
		value := strings.TrimSpace(object[valueStart:valueEnd])
		if strings.HasPrefix(value, `"`) {
			if unquoted, err := strconv.Unquote(value); err == nil {
				out[key] = unquoted
			}
		} else if value != "null" && value != "" && !strings.HasPrefix(value, "{") && !strings.HasPrefix(value, "[") {
			out[key] = strings.Trim(value, ` "`)
		}
		i = valueEnd + 1
	}
	if len(out) == 0 {
		return nil
	}

	return out
}

func responseBodySuffix(body []byte) string {
	bodyText := strings.Join(strings.Fields(string(body)), " ")
	bodyText = sanitizeSecretString(bodyText)
	if bodyText == "" {
		return ""
	}
	if len(bodyText) > 300 {
		bodyText = bodyText[:300] + "..."
	}

	return ": " + bodyText
}

func addNodeDiscoveries(discovery *sdk.DeviceDiscovery, target Target, nodes []proxmoxNode) {
	for _, node := range nodes {
		available := strings.EqualFold(node.Status, "online")
		hostname := firstNonEmpty(node.Node, target.Hostname)
		deviceID := "proxmox:pve:" + node.Node
		if targetMatchesNode(target, node) {
			deviceID = firstNonEmpty(target.DeviceID, deviceID)
		}

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    deviceID,
			Hostname:    hostname,
			IP:          stripIPPrefix(node.IP),
			VendorName:  "Proxmox",
			Model:       "PVE",
			Type:        "hypervisor",
			Role:        "proxmox_pve",
			Status:      node.Status,
			IsAvailable: &available,
			Labels: map[string]string{
				"provider": "proxmox",
				"role":     "pve",
			},
		})
	}
}

func targetMatchesNode(target Target, node proxmoxNode) bool {
	for _, candidate := range []string{target.Hostname, hostFromURL(target.BaseURL)} {
		if sameHostOrNode(candidate, node.Node) {
			return true
		}
	}

	return false
}

func hostFromURL(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}

	return parsed.Hostname()
}

func sameHostOrNode(candidate, node string) bool {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	node = strings.ToLower(strings.TrimSpace(node))
	if candidate == "" || node == "" {
		return false
	}

	return candidate == node || strings.Split(candidate, ".")[0] == node
}

func addGuestDiscoveries(discovery *sdk.DeviceDiscovery, guests []proxmoxGuest) {
	for _, guest := range guests {
		kind := normalizeGuestKind(guest.Type)
		available := strings.EqualFold(guest.Status, "running")

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    proxmoxGuestID(guest.proxmoxResource),
			Hostname:    firstNonEmpty(guest.Name, guest.ID),
			IP:          primaryIP(guest.Interfaces),
			MAC:         primaryMAC(guest.Interfaces),
			VendorName:  "Proxmox",
			Model:       kind,
			Type:        kind,
			Role:        "proxmox_" + kind,
			Status:      guest.Status,
			IsAvailable: &available,
			Labels: map[string]string{
				"provider": "proxmox",
				"role":     kind,
			},
		})
	}
}

func (cfg *Config) applyDefaults() {
	if cfg.TimeoutMS <= 0 {
		cfg.TimeoutMS = defaultTimeoutMS
	}
	if cfg.TimeoutMS > maxTimeoutMS {
		cfg.TimeoutMS = maxTimeoutMS
	}
	if cfg.MaxResponseBytes <= 0 {
		cfg.MaxResponseBytes = defaultHTTPMaxResponseBytes
	}
	if cfg.MaxResponseBytes > maxHTTPResponseBytes {
		cfg.MaxResponseBytes = maxHTTPResponseBytes
	}
	if cfg.Targets == nil {
		cfg.Targets = []Target{}
	}
}

func (cfg Config) includeGuests() bool {
	if cfg.IncludeGuests == nil {
		return true
	}

	return *cfg.IncludeGuests
}

func (cfg Config) effectiveTargets() []Target {
	targets := make([]Target, 0, len(cfg.Targets)+1)
	for _, target := range cfg.Targets {
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	if strings.TrimSpace(cfg.BaseURL) != "" {
		targets = append(targets, Target{
			BaseURL:  cfg.BaseURL,
			APIToken: cfg.APIToken,
		})
	}

	return targets
}

func looksLikePluginInputs(raw map[string]any) bool {
	if strings.TrimSpace(stringValue(raw, "schema")) == sdk.PluginInputsSchemaV1 {
		return true
	}
	if _, ok := raw["inputs"]; ok {
		return true
	}

	return false
}

func looksLikePluginInputsPayload(payload pluginInputsJSON) bool {
	return strings.TrimSpace(payload.Schema) == sdk.PluginInputsSchemaV1 ||
		len(payload.Inputs) > 0 ||
		strings.TrimSpace(payload.PolicyID) != ""
}

func looksLikePluginInputsJSON(raw json.RawMessage) bool {
	var probe struct {
		Schema string            `json:"schema"`
		Inputs []json.RawMessage `json:"inputs"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return false
	}

	return strings.TrimSpace(probe.Schema) == sdk.PluginInputsSchemaV1 || len(probe.Inputs) > 0
}

func validatePluginInputsJSON(payload pluginInputsJSON) error {
	if strings.TrimSpace(payload.Schema) != sdk.PluginInputsSchemaV1 {
		return fmt.Errorf("plugin inputs payload has invalid schema: %q", payload.Schema)
	}
	if strings.TrimSpace(payload.PolicyID) == "" {
		return errors.New("plugin inputs payload missing policy_id")
	}
	if payload.PolicyVersion < 1 {
		return errors.New("plugin inputs payload has invalid policy_version")
	}
	if strings.TrimSpace(payload.AgentID) == "" {
		return errors.New("plugin inputs payload missing agent_id")
	}
	if strings.TrimSpace(payload.GeneratedAt) == "" {
		return errors.New("plugin inputs payload missing generated_at")
	}
	if len(payload.Inputs) == 0 {
		return errors.New("plugin inputs payload missing inputs")
	}

	for i, input := range payload.Inputs {
		if strings.TrimSpace(input.Name) == "" {
			return fmt.Errorf("plugin inputs payload missing input name at inputs[%d]", i)
		}
		if strings.TrimSpace(input.Entity) == "" {
			return fmt.Errorf("plugin inputs payload missing input entity at inputs[%d]", i)
		}
		if strings.TrimSpace(input.Query) == "" {
			return fmt.Errorf("plugin inputs payload missing input query at inputs[%d]", i)
		}
		if input.ChunkIndex < 0 {
			return fmt.Errorf("plugin inputs payload has invalid input chunk_index at inputs[%d]", i)
		}
		if input.ChunkTotal < 1 {
			return fmt.Errorf("plugin inputs payload has invalid input chunk_total at inputs[%d]", i)
		}
		if strings.TrimSpace(input.ChunkHash) == "" {
			return fmt.Errorf("plugin inputs payload missing input chunk_hash at inputs[%d]", i)
		}
		if len(input.Items) == 0 {
			return fmt.Errorf("plugin inputs payload missing input items at inputs[%d]", i)
		}
	}

	return nil
}

func targetsFromPluginInputs(payload *sdk.PluginInputsPayload, cfg Config) []Target {
	if payload == nil {
		return nil
	}

	targets := make([]Target, 0)
	for _, input := range payload.FlattenItems() {
		if input.Entity != "devices" {
			continue
		}

		target := targetFromInputItem(input.Item, cfg)
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	return targets
}

func targetsFromPluginInputsJSON(payload pluginInputsJSON, cfg Config) []Target {
	targets := make([]Target, 0)
	for _, input := range payload.Inputs {
		if input.Entity != "devices" {
			continue
		}

		for _, item := range input.Items {
			target := targetFromPluginInputItem(item, cfg)
			if strings.TrimSpace(target.BaseURL) != "" {
				targets = append(targets, target)
			}
		}
	}

	return targets
}

func targetFromInputItem(item map[string]any, cfg Config) Target {
	hostname := firstNonEmpty(
		stringValue(item, "hostname"),
		stringValue(item, "name"),
	)

	return Target{
		BaseURL:  baseURLForItem(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			stringValue(item, "uid"),
			stringValue(item, "device_uid"),
			stringValue(item, "device_id"),
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			stringValue(item, "partition"),
			stringValue(item, "site"),
		),
	}
}

func targetFromPluginInputItem(item pluginInputItem, cfg Config) Target {
	hostname := firstNonEmpty(item.Hostname, item.Name)

	return Target{
		BaseURL:  baseURLForPluginInputItem(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			item.UID,
			item.DeviceUID,
			item.DeviceID,
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			item.Partition,
			item.Site,
		),
	}
}

func applyHTTPClientLimits(cfg Config) {
	client, ok := proxmoxHTTP.(*sdk.HTTPClient)
	if !ok {
		return
	}

	client.MaxResponseBytes = uint32(cfg.MaxResponseBytes)
}

func baseURLForItem(item map[string]any, cfg Config) string {
	direct := firstNonEmpty(
		stringValue(item, "base_url"),
		stringValue(item, "proxmox_base_url"),
		stringValue(item, "endpoint"),
		stringValue(item, "management_url"),
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		stringValue(item, "ip"),
		stringValue(item, "device_ip"),
		stringValue(item, "hostname"),
		stringValue(item, "name"),
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}

func baseURLForPluginInputItem(item pluginInputItem, cfg Config) string {
	direct := firstNonEmpty(
		item.BaseURL,
		item.ProxmoxBaseURL,
		item.Endpoint,
		item.ManagementURL,
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		item.IP,
		item.DeviceIP,
		item.Hostname,
		item.Name,
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}

func normalizeBaseURL(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") {
		return strings.TrimRight(value, "/")
	}

	return "https://" + strings.TrimRight(value, "/") + ":8006"
}

func normalizeProxmoxAPIToken(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "PVEAPIToken=") {
		return value
	}

	return "PVEAPIToken=" + value
}

func dedupeTargets(targets []Target) []Target {
	seen := map[string]bool{}
	out := make([]Target, 0, len(targets))

	for _, target := range targets {
		key := target.BaseURL + "|" + target.DeviceID + "|" + target.Hostname
		if seen[key] || strings.TrimSpace(target.BaseURL) == "" {
			continue
		}
		seen[key] = true
		out = append(out, target)
	}

	return out
}

func stringValue(mapValue map[string]any, key string) string {
	if mapValue == nil {
		return ""
	}
	if value, ok := mapValue[key]; ok {
		switch typed := value.(type) {
		case string:
			return strings.TrimSpace(typed)
		case fmt.Stringer:
			return strings.TrimSpace(typed.String())
		}
	}

	return ""
}

func targetsFromRawPluginInputItems(raw string, cfg Config) []Target {
	items := rawJSONObjectList(rawItemsArray(raw))
	targets := make([]Target, 0, len(items))

	for _, item := range items {
		target := targetFromRawPluginInputItem(item, cfg)
		if strings.TrimSpace(target.BaseURL) != "" {
			targets = append(targets, target)
		}
	}

	return dedupeTargets(targets)
}

func targetFromRawPluginInputItem(item string, cfg Config) Target {
	hostname := firstNonEmpty(jsonStringValue(item, "hostname"), jsonStringValue(item, "name"))

	return Target{
		BaseURL:  rawItemBaseURL(item, cfg),
		APIToken: cfg.APIToken,
		DeviceID: firstNonEmpty(
			jsonStringValue(item, "uid"),
			jsonStringValue(item, "device_uid"),
			jsonStringValue(item, "device_id"),
		),
		Hostname: hostname,
		Partition: firstNonEmpty(
			jsonStringValue(item, "partition"),
			jsonStringValue(item, "site"),
		),
	}
}

func rawItemBaseURL(item string, cfg Config) string {
	direct := firstNonEmpty(
		jsonStringValue(item, "base_url"),
		jsonStringValue(item, "proxmox_base_url"),
		jsonStringValue(item, "endpoint"),
		jsonStringValue(item, "management_url"),
	)
	if direct != "" {
		return normalizeBaseURL(direct)
	}

	host := firstNonEmpty(
		jsonStringValue(item, "ip"),
		jsonStringValue(item, "device_ip"),
		jsonStringValue(item, "hostname"),
		jsonStringValue(item, "name"),
	)
	if host != "" {
		return normalizeBaseURL(host)
	}

	return normalizeBaseURL(cfg.BaseURL)
}

func rawItemsArray(raw string) string {
	start, end, ok := jsonValueSpan(raw, "items")
	if !ok || start >= end || raw[start] != '[' {
		return ""
	}

	return raw[start:end]
}

func rawJSONObjectList(raw string) []string {
	out := []string{}
	start := -1
	depth := 0
	inString := false
	escaped := false

	for i := range raw {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
			}
			continue
		}

		switch ch {
		case '"':
			inString = true
		case '{':
			if depth == 0 {
				start = i
			}
			depth++
		case '}':
			if depth == 0 {
				continue
			}
			depth--
			if depth == 0 && start >= 0 {
				out = append(out, raw[start:i+1])
				start = -1
			}
		}
	}

	return out
}

func jsonStringValue(raw string, key string) string {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return ""
	}
	value := strings.TrimSpace(raw[start:end])
	if value == "" || value == "null" {
		return ""
	}
	if strings.HasPrefix(value, `"`) {
		unquoted, err := strconv.Unquote(value)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(unquoted)
	}

	return strings.Trim(value, ` "`)
}

func jsonIntValue(raw string, key string) int {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return 0
	}
	value := strings.TrimSpace(raw[start:end])
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0
	}

	return parsed
}

func jsonFloatValue(raw string, key string) float64 {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return 0
	}
	value := strings.TrimSpace(raw[start:end])
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0
	}

	return parsed
}

func jsonStringArrayValue(raw string, key string) []string {
	array := jsonArrayValue(raw, key)
	if array == "" {
		return nil
	}
	values := make([]string, 0)
	for i := 1; i < len(array)-1; {
		i = skipJSONWhitespace(array, i)
		if i >= len(array)-1 || array[i] == ']' {
			break
		}
		if array[i] == '"' {
			end := jsonStringEnd(array, i)
			if end < 0 {
				break
			}
			if value, err := strconv.Unquote(array[i : end+1]); err == nil {
				values = append(values, value)
			}
			i = end + 1
		} else {
			end := jsonValueEnd(array, i)
			if end < 0 {
				break
			}
			value := strings.TrimSpace(array[i:end])
			if value != "" && value != "null" {
				values = append(values, strings.Trim(value, ` "`))
			}
			i = end
		}
		for i < len(array) && array[i] != ',' && array[i] != ']' {
			i++
		}
		if i < len(array) && array[i] == ',' {
			i++
		}
	}
	if len(values) == 0 {
		return nil
	}

	return values
}

func jsonBoolValue(raw string, key string) (bool, bool) {
	start, end, ok := jsonValueSpan(raw, key)
	if !ok || start >= end {
		return false, false
	}
	switch strings.TrimSpace(raw[start:end]) {
	case "true":
		return true, true
	case "false":
		return false, true
	default:
		return false, false
	}
}

func jsonValueSpan(raw string, key string) (int, int, bool) {
	colon, ok := jsonKeyColon(raw, key)
	if !ok {
		return 0, 0, false
	}
	start := skipJSONWhitespace(raw, colon+1)
	if start >= len(raw) {
		return 0, 0, false
	}

	switch raw[start] {
	case '"':
		end := jsonStringEnd(raw, start)
		if end < 0 {
			return 0, 0, false
		}
		return start, end + 1, true
	case '{', '[':
		end := jsonCompositeEnd(raw, start)
		if end < 0 {
			return 0, 0, false
		}
		return start, end + 1, true
	default:
		end := start
		for end < len(raw) && raw[end] != ',' && raw[end] != '}' && raw[end] != ']' {
			end++
		}
		return start, end, true
	}
}

func jsonKeyColon(raw string, key string) (int, bool) {
	inString := false
	escaped := false
	stringStart := -1

	for i := range raw {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
				if stringStart >= 0 {
					quoted := raw[stringStart : i+1]
					unquoted, err := strconv.Unquote(quoted)
					if err == nil && unquoted == key {
						next := skipJSONWhitespace(raw, i+1)
						if next < len(raw) && raw[next] == ':' {
							return next, true
						}
					}
				}
			}
			continue
		}
		if ch == '"' {
			inString = true
			stringStart = i
		}
	}

	return 0, false
}

func jsonStringEnd(raw string, start int) int {
	escaped := false
	for i := start + 1; i < len(raw); i++ {
		if escaped {
			escaped = false
			continue
		}
		switch raw[i] {
		case '\\':
			escaped = true
		case '"':
			return i
		}
	}

	return -1
}

func jsonValueEnd(raw string, start int) int {
	if start >= len(raw) {
		return -1
	}
	switch raw[start] {
	case '"':
		end := jsonStringEnd(raw, start)
		if end < 0 {
			return -1
		}
		return end + 1
	case '{', '[':
		end := jsonCompositeEnd(raw, start)
		if end < 0 {
			return -1
		}
		return end + 1
	default:
		end := start
		for end < len(raw) && raw[end] != ',' && raw[end] != '}' && raw[end] != ']' {
			end++
		}
		return end
	}
}

func jsonCompositeEnd(raw string, start int) int {
	open := raw[start]
	close := byte('}')
	if open == '[' {
		close = ']'
	}

	depth := 0
	inString := false
	escaped := false

	for i := start; i < len(raw); i++ {
		ch := raw[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			switch ch {
			case '\\':
				escaped = true
			case '"':
				inString = false
			}
			continue
		}

		switch ch {
		case '"':
			inString = true
		case open:
			depth++
		case close:
			depth--
			if depth == 0 {
				return i
			}
		}
	}

	return -1
}

func skipJSONWhitespace(raw string, start int) int {
	for start < len(raw) {
		switch raw[start] {
		case ' ', '\n', '\r', '\t':
			start++
		default:
			return start
		}
	}

	return start
}

func (target Target) safeName() string {
	return firstNonEmpty(target.Hostname, target.DeviceID, target.redactedBaseURL())
}

func (target Target) redactedBaseURL() string {
	return strings.TrimSpace(target.BaseURL)
}

func targetMetadata(target Target) map[string]string {
	meta := map[string]string{}
	if target.DeviceID != "" {
		meta["device_id"] = target.DeviceID
	}
	if target.Hostname != "" {
		meta["hostname"] = target.Hostname
	}
	if target.Partition != "" {
		meta["partition"] = target.Partition
	}
	if len(meta) == 0 {
		return nil
	}

	return meta
}

func (target proxmoxTarget) safeEventPrefix() string {
	if target.Meta != nil {
		if deviceID := strings.TrimSpace(target.Meta["device_id"]); deviceID != "" {
			return deviceID + ":"
		}
		if hostname := strings.TrimSpace(target.Meta["hostname"]); hostname != "" {
			return hostname + ":"
		}
	}
	if target.BaseURL != "" {
		return target.BaseURL + ":"
	}

	return ""
}

func proxmoxGuestID(guest proxmoxResource) string {
	if guest.ID != "" {
		return "proxmox:" + strings.ReplaceAll(guest.ID, "/", ":")
	}

	return fmt.Sprintf("proxmox:%s:%s:%d", normalizeGuestKind(guest.Type), guest.Node, guest.VMID)
}

func normalizeGuestKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "qemu":
		return "vm"
	case "lxc":
		return "container"
	default:
		return "guest"
	}
}

func normalizeMACForOutput(value string) string {
	key := normalizeMACKey(value)
	if key == "" {
		return ""
	}

	parts := make([]string, 0, 6)
	for i := 0; i < len(key); i += 2 {
		parts = append(parts, key[i:i+2])
	}

	return strings.Join(parts, ":")
}

func normalizeMACKey(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	replacer := strings.NewReplacer(":", "", "-", "", ".", "")
	value = replacer.Replace(value)
	if len(value) != 12 {
		return ""
	}
	for _, r := range value {
		if !((r >= '0' && r <= '9') || (r >= 'A' && r <= 'F')) {
			return ""
		}
	}
	return value
}

func normalizeGuestIP(value string) string {
	value = strings.TrimSpace(value)
	switch strings.ToLower(value) {
	case "", "dhcp", "auto", "manual", "none":
		return ""
	default:
		return value
	}
}

func primaryIP(interfaces []proxmoxGuestNetworkInterface) string {
	for _, iface := range interfaces {
		for _, ip := range iface.IPAddresses {
			if plain := stripIPPrefix(ip); plain != "" && !isLoopbackOrLinkLocal(plain) {
				return plain
			}
		}
	}
	return ""
}

func primaryMAC(interfaces []proxmoxGuestNetworkInterface) string {
	for _, iface := range interfaces {
		if iface.MACAddress != "" {
			return iface.MACAddress
		}
	}
	return ""
}

func stripIPPrefix(value string) string {
	value = strings.TrimSpace(value)
	if idx := strings.Index(value, "/"); idx >= 0 {
		value = value[:idx]
	}
	return value
}

func isLoopbackOrLinkLocal(value string) bool {
	value = strings.ToLower(stripIPPrefix(value))
	return strings.HasPrefix(value, "127.") ||
		value == "::1" ||
		strings.HasPrefix(value, "169.254.") ||
		strings.HasPrefix(value, "fe80:")
}

func appendUniqueStrings(left []string, right []string) []string {
	for _, value := range right {
		left = appendUniqueString(left, value)
	}
	return left
}

func appendUniqueString(values []string, value string) []string {
	value = strings.TrimSpace(value)
	if value == "" {
		return values
	}
	for _, existing := range values {
		if strings.EqualFold(existing, value) {
			return values
		}
	}
	return append(values, value)
}

func parsePositiveInt(value string) int {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || parsed < 0 {
		return 0
	}
	return parsed
}

func guestEndpointKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "qemu":
		return "qemu"
	case "lxc":
		return "lxc"
	default:
		return ""
	}
}

func summarizeInventory(nodes []proxmoxNode, guests []proxmoxGuest) resourceSummary {
	summary := resourceSummary{}
	for _, node := range nodes {
		if strings.EqualFold(node.Status, "online") {
			summary.OnlineNodes++
		} else {
			summary.OfflineNodes++
		}

		summary.MaxNodeCPURatio = maxFloat(summary.MaxNodeCPURatio, ratio(node.CPU, 1))
		summary.MaxNodeMemRatio = maxFloat(summary.MaxNodeMemRatio, ratio(node.Mem, node.MaxMem))
		summary.MaxNodeIOWaitRatio = maxFloat(summary.MaxNodeIOWaitRatio, ratio(floatValue(node.RuntimeState, "wait"), 1))
		summary.StorageCount += len(node.Storage)
		summary.NetworkInterfaceCount += len(node.Network)
		summary.DiskCount += len(node.Disks)
		for _, storage := range node.Storage {
			summary.MaxNodeStorageRatio = maxFloat(summary.MaxNodeStorageRatio, ratio(storage.Used, storage.Total))
		}
		if node.Ceph != nil {
			summary.CephEnabledNodes++
			switch cephHealthClass(node.Ceph.Health) {
			case "critical":
				summary.CephErrorNodes++
			case "warning":
				summary.CephWarnNodes++
			}
		}
	}

	for _, guest := range guests {
		if strings.EqualFold(guest.Status, "running") {
			summary.RunningGuests++
		} else {
			summary.StoppedGuests++
		}

		summary.MaxGuestCPURatio = maxFloat(summary.MaxGuestCPURatio, ratio(guest.CPU, 1))
		summary.MaxGuestMemRatio = maxFloat(summary.MaxGuestMemRatio, ratio(guest.Mem, guest.MaxMem))
		summary.MaxGuestDiskRatio = maxFloat(summary.MaxGuestDiskRatio, ratio(guest.Disk, guest.MaxDisk))
	}

	summary.ResourceBottleneck = countResourceBottlenecks(nodes, guests)

	return summary
}

func countResourceBottlenecks(nodes []proxmoxNode, guests []proxmoxGuest) int {
	count := 0
	for _, node := range nodes {
		if ratio(node.CPU, 1) >= 0.80 ||
			ratio(node.Mem, node.MaxMem) >= 0.80 ||
			ratio(floatValue(node.RuntimeState, "wait"), 1) >= 0.20 {
			count++
		}
		for _, storage := range node.Storage {
			if ratio(storage.Used, storage.Total) >= 0.80 {
				count++
			}
		}
		if node.Ceph != nil && cephHealthClass(node.Ceph.Health) != "" {
			count++
		}
	}
	for _, guest := range guests {
		if ratio(guest.CPU, 1) >= 0.80 ||
			ratio(guest.Mem, guest.MaxMem) >= 0.80 ||
			ratio(guest.Disk, guest.MaxDisk) >= 0.80 {
			count++
		}
	}

	return count
}

func mergeResourceSummary(acc, next resourceSummary) resourceSummary {
	acc.MaxNodeCPURatio = maxFloat(acc.MaxNodeCPURatio, next.MaxNodeCPURatio)
	acc.MaxNodeMemRatio = maxFloat(acc.MaxNodeMemRatio, next.MaxNodeMemRatio)
	acc.MaxNodeIOWaitRatio = maxFloat(acc.MaxNodeIOWaitRatio, next.MaxNodeIOWaitRatio)
	acc.MaxNodeStorageRatio = maxFloat(acc.MaxNodeStorageRatio, next.MaxNodeStorageRatio)
	acc.MaxGuestCPURatio = maxFloat(acc.MaxGuestCPURatio, next.MaxGuestCPURatio)
	acc.MaxGuestMemRatio = maxFloat(acc.MaxGuestMemRatio, next.MaxGuestMemRatio)
	acc.MaxGuestDiskRatio = maxFloat(acc.MaxGuestDiskRatio, next.MaxGuestDiskRatio)
	acc.RunningGuests += next.RunningGuests
	acc.StoppedGuests += next.StoppedGuests
	acc.OnlineNodes += next.OnlineNodes
	acc.OfflineNodes += next.OfflineNodes
	acc.StorageCount += next.StorageCount
	acc.NetworkInterfaceCount += next.NetworkInterfaceCount
	acc.DiskCount += next.DiskCount
	acc.CephEnabledNodes += next.CephEnabledNodes
	acc.CephWarnNodes += next.CephWarnNodes
	acc.CephErrorNodes += next.CephErrorNodes
	acc.ResourceBottleneck += next.ResourceBottleneck

	return acc
}

func emitResourceEvents(result *sdk.Result, details proxmoxDetails) {
	for _, target := range details.Targets {
		for _, node := range target.Nodes {
			emitRatioEvent(result, "node_cpu", target.safeEventPrefix()+node.Node, ratio(node.CPU, 1))
			emitRatioEvent(result, "node_memory", target.safeEventPrefix()+node.Node, ratio(node.Mem, node.MaxMem))
			emitIOWaitEvent(result, target.safeEventPrefix()+node.Node, ratio(floatValue(node.RuntimeState, "wait"), 1))
			for _, storage := range node.Storage {
				emitRatioEvent(result, "node_storage", target.safeEventPrefix()+node.Node+":"+storage.Storage, ratio(storage.Used, storage.Total))
			}
			emitCephHealthEvent(result, target.safeEventPrefix()+node.Node, node.Ceph)
			for _, disk := range node.Disks {
				emitDiskHealthEvent(result, target.safeEventPrefix()+node.Node, disk)
			}
		}
		for _, guest := range target.Guests {
			key := fmt.Sprintf("%s%s:%d", target.safeEventPrefix(), guestEndpointKind(guest.Type), guest.VMID)
			emitRatioEvent(result, "guest_cpu", key, ratio(guest.CPU, 1))
			emitRatioEvent(result, "guest_memory", key, ratio(guest.Mem, guest.MaxMem))
			emitRatioEvent(result, "guest_disk", key, ratio(guest.Disk, guest.MaxDisk))
		}
	}
}

func emitIOWaitEvent(result *sdk.Result, key string, value float64) {
	switch {
	case value >= 0.40:
		result.EmitEvent(
			sdk.SeverityCritical,
			fmt.Sprintf("Proxmox node I/O wait bottleneck %.0f%%", value*100),
			"proxmox:node_io_wait:"+key,
		)
	case value >= 0.20:
		result.EmitEvent(
			sdk.SeverityWarning,
			fmt.Sprintf("Proxmox node I/O wait pressure %.0f%%", value*100),
			"proxmox:node_io_wait:"+key,
		)
	}
}

func emitRatioEvent(result *sdk.Result, kind, key string, value float64) {
	switch {
	case value >= 0.90:
		result.EmitEvent(
			sdk.SeverityCritical,
			fmt.Sprintf("Proxmox %s bottleneck %.0f%%", strings.ReplaceAll(kind, "_", " "), value*100),
			"proxmox:"+kind+":"+key,
		)
	case value >= 0.80:
		result.EmitEvent(
			sdk.SeverityWarning,
			fmt.Sprintf("Proxmox %s pressure %.0f%%", strings.ReplaceAll(kind, "_", " "), value*100),
			"proxmox:"+kind+":"+key,
		)
	}
}

func emitCephHealthEvent(result *sdk.Result, key string, ceph *proxmoxCeph) {
	if ceph == nil {
		return
	}

	switch cephHealthClass(ceph.Health) {
	case "critical":
		result.EmitEvent(
			sdk.SeverityCritical,
			"Proxmox Ceph health critical: "+ceph.Health,
			"proxmox:ceph_health:"+key,
		)
	case "warning":
		result.EmitEvent(
			sdk.SeverityWarning,
			"Proxmox Ceph health warning: "+ceph.Health,
			"proxmox:ceph_health:"+key,
		)
	}
}

func emitDiskHealthEvent(result *sdk.Result, key string, disk proxmoxDisk) {
	health := strings.ToUpper(strings.TrimSpace(disk.Health))
	if health == "" || health == "OK" || health == "PASSED" {
		return
	}

	diskID := firstNonEmpty(disk.DevPath, disk.ByID, disk.Model, "disk")
	result.EmitEvent(
		sdk.SeverityWarning,
		"Proxmox disk health warning: "+diskID+" "+health,
		"proxmox:disk_health:"+key+":"+diskID,
	)
}

func countGuests(guests []proxmoxGuest, guestType string) int {
	count := 0
	for _, guest := range guests {
		if strings.EqualFold(guest.Type, guestType) {
			count++
		}
	}

	return count
}

func (ceph proxmoxCeph) empty() bool {
	return ceph.Health == ""
}

func cephHealth(status proxmoxCephStatus) string {
	return firstNonEmpty(status.Health, status.OverallStatus, status.Status)
}

func cephHealthClass(health string) string {
	health = strings.ToUpper(strings.TrimSpace(health))
	switch {
	case health == "":
		return ""
	case strings.Contains(health, "ERR") || strings.Contains(health, "CRIT"):
		return "critical"
	case strings.Contains(health, "WARN"):
		return "warning"
	default:
		return ""
	}
}

func ratio(value, maxValue float64) float64 {
	if value <= 0 || maxValue <= 0 {
		return 0
	}
	if value > 1 && maxValue == 1 {
		return 1
	}

	return value / maxValue
}

func maxFloat(a, b float64) float64 {
	if b > a {
		return b
	}

	return a
}

func floatValue(values proxmoxNodeStatus, key string) float64 {
	switch key {
	case "wait":
		return values.Wait
	default:
		return 0
	}
}

func stringAny(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return ""
	}
}

func nilIfEmpty(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}

	return values
}

func sanitizeStringMap(raw map[string]string) map[string]string {
	if len(raw) == 0 {
		return nil
	}

	sanitized := make(map[string]string, len(raw))
	for key, value := range raw {
		if sensitiveKey(key) {
			sanitized[key] = "REDACTED"
			continue
		}
		sanitized[key] = sanitizeSecretString(value)
	}

	return sanitized
}

func sanitizeMap(raw map[string]any) map[string]any {
	if len(raw) == 0 {
		return nil
	}

	sanitized := make(map[string]any, len(raw))
	for key, value := range raw {
		if sensitiveKey(key) {
			sanitized[key] = "REDACTED"
			continue
		}
		sanitized[key] = sanitizeAny(value)
	}

	return sanitized
}

func sanitizeAny(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		return sanitizeMap(typed)
	case []any:
		out := make([]any, 0, len(typed))
		for _, item := range typed {
			out = append(out, sanitizeAny(item))
		}
		return out
	case string:
		return sanitizeSecretString(typed)
	default:
		return value
	}
}

func sanitizeMapList(raw []map[string]any) []map[string]any {
	if len(raw) == 0 {
		return nil
	}

	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		out = append(out, sanitizeMap(item))
	}

	return out
}

func sensitiveKey(key string) bool {
	normalized := strings.ToLower(strings.TrimSpace(key))
	for _, needle := range []string{"password", "passwd", "secret", "token", "credential", "apikey", "api_key", "privatekey", "private_key"} {
		if strings.Contains(normalized, needle) {
			return true
		}
	}

	return false
}

func sanitizeSecretString(value string) string {
	if strings.Contains(value, "PVEAPIToken=") {
		return redactPVEAPITokenMaterial(value)
	}

	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}

	return ""
}

func joinErrors(errorsByTarget map[string]string) string {
	parts := make([]string, 0, len(errorsByTarget))
	for target, reason := range errorsByTarget {
		parts = append(parts, target+": "+reason)
	}

	return strings.Join(parts, "; ")
}

func sanitizeError(err error) string {
	if err == nil {
		return ""
	}

	msg := err.Error()
	msg = redactPVEAPITokenMaterial(msg)

	return msg
}

func redactPVEAPITokenMaterial(value string) string {
	const marker = "PVEAPIToken="
	searchStart := 0

	for {
		relativeIdx := strings.Index(value[searchStart:], marker)
		if relativeIdx < 0 {
			return value
		}

		idx := searchStart + relativeIdx
		end := idx + len(marker)
		for end < len(value) {
			switch value[end] {
			case '"', '\'', ',', '}', ']', '<', ' ', '\t', '\n', '\r':
				value = value[:idx] + marker + "REDACTED" + value[end:]
				searchStart = idx + len(marker) + len("REDACTED")
				goto next
			default:
				end++
			}
		}
		value = value[:idx] + marker + "REDACTED"
		searchStart = len(value)

	next:
	}
}

func main() {}
