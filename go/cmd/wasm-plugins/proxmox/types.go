package main

import (
	"errors"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	pluginID                  = "proxmox-inventory"
	discoverySource           = "proxmox"
	hostCredentialSentinel    = "__SERVICERADAR_HOST_CREDENTIAL__"
	hostProxmoxTicketSentinel = "__SERVICERADAR_HOST_PROXMOX_TICKET__"
	defaultTimeoutMS          = 30000
	maxTimeoutMS              = 300000
	// guestProbeTimeoutMS caps the best-effort qemu-agent / lxc runtime probes so
	// an unresponsive guest agent fails fast instead of consuming the full request
	// timeout per guest (which starved later nodes of enumeration time).
	guestProbeTimeoutMS         = 3000
	defaultHTTPMaxResponseBytes = 1024 * 1024
	maxHTTPResponseBytes        = sdk.MaxHTTPResponseBytes
	defaultMaxGuests            = 1000
	maxGuests                   = 5000
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
	BaseURL          string   `json:"base_url"`
	APIToken         string   `json:"api_token"`
	Targets          []Target `json:"targets"`
	TimeoutMS        int      `json:"timeout_ms"`
	MaxResponseBytes int      `json:"max_response_bytes"`
	MaxGuests        int      `json:"max_guests"`
	IncludeGuests    *bool    `json:"include_guests"`
	AutoDiscovery    bool     `json:"auto_discovery_enabled"`
}

type Target struct {
	BaseURL   string `json:"base_url"`
	APIToken  string `json:"api_token"`
	DeviceID  string `json:"device_id"`
	Hostname  string `json:"hostname"`
	Partition string `json:"partition"`
}

type configJSON struct {
	BaseURL          string   `json:"base_url"`
	APIToken         string   `json:"api_token"`
	Targets          []Target `json:"targets"`
	TimeoutMS        int      `json:"timeout_ms"`
	MaxResponseBytes int      `json:"max_response_bytes"`
	MaxGuests        int      `json:"max_guests"`
	IncludeGuests    *bool    `json:"include_guests"`
	AutoDiscovery    bool     `json:"auto_discovery_enabled"`
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
	Status          sdk.Status            `json:"status"`
	Summary         string                `json:"summary"`
	Details         string                `json:"details,omitempty"`
	Labels          map[string]string     `json:"labels,omitempty"`
	TelemetryEvents []sdk.OCSFEvent       `json:"-"`
	DeviceDiscovery []sdk.DeviceDiscovery `json:"device_discovery,omitempty"`
	ObservedAt      string                `json:"observed_at,omitempty"`
	SchemaVersion   int                   `json:"schema_version,omitempty"`
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
	MACAddress  string   `json:"hwaddr,omitempty"`
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
