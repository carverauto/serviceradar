// Package main implements the Proxmox inventory WASM plugin for ServiceRadar.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

const (
	pluginID         = "proxmox-inventory"
	discoverySource  = "proxmox"
	defaultTimeoutMS = 30000
	maxTimeoutMS     = 300000
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

type proxmoxMapResponse struct {
	Data map[string]any `json:"data"`
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

type proxmoxMapListResponse struct {
	Data []map[string]any `json:"data"`
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
	CPU          float64                   `json:"cpu"`
	MaxCPU       float64                   `json:"maxcpu"`
	Mem          float64                   `json:"mem"`
	MaxMem       float64                   `json:"maxmem"`
	Uptime       float64                   `json:"uptime"`
	RuntimeState map[string]any            `json:"runtime_status,omitempty"`
	Storage      []proxmoxStorage          `json:"storage,omitempty"`
	Network      []proxmoxNetworkInterface `json:"network,omitempty"`
	Disks        []proxmoxDisk             `json:"disks,omitempty"`
	Ceph         *proxmoxCeph              `json:"ceph,omitempty"`
}

type proxmoxStorage struct {
	Storage string  `json:"storage"`
	Type    string  `json:"type,omitempty"`
	Content string  `json:"content,omitempty"`
	Active  any     `json:"active,omitempty"`
	Enabled any     `json:"enabled,omitempty"`
	Shared  any     `json:"shared,omitempty"`
	Used    float64 `json:"used,omitempty"`
	Avail   float64 `json:"avail,omitempty"`
	Total   float64 `json:"total,omitempty"`
}

type proxmoxNetworkInterface struct {
	Iface           string   `json:"iface"`
	Type            string   `json:"type,omitempty"`
	Active          any      `json:"active,omitempty"`
	Exists          any      `json:"exists,omitempty"`
	Autostart       any      `json:"autostart,omitempty"`
	Method          string   `json:"method,omitempty"`
	Method6         string   `json:"method6,omitempty"`
	Address         string   `json:"address,omitempty"`
	Netmask         string   `json:"netmask,omitempty"`
	Gateway         string   `json:"gateway,omitempty"`
	CIDR            string   `json:"cidr,omitempty"`
	BridgePorts     string   `json:"bridge-ports,omitempty"`
	BridgeVlanAware any      `json:"bridge-vlan-aware,omitempty"`
	VLANID          any      `json:"vlan-id,omitempty"`
	Priority        any      `json:"priority,omitempty"`
	Families        []string `json:"families,omitempty"`
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
	Wearout any     `json:"wearout,omitempty"`
}

type proxmoxCeph struct {
	Health string           `json:"health,omitempty"`
	Status map[string]any   `json:"status,omitempty"`
	OSDs   []map[string]any `json:"osds,omitempty"`
	Pools  []map[string]any `json:"pools,omitempty"`
	FS     []map[string]any `json:"filesystems,omitempty"`
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
	RuntimeStatus map[string]any `json:"runtime_status,omitempty"`
	Config        map[string]any `json:"config,omitempty"`
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
	primeTinyGoJSON()

	_ = sdk.Execute(func() (*sdk.Result, error) {
		cfg, err := loadConfig()
		if err != nil {
			return sdk.Unknown("Proxmox configuration could not be loaded"), nil
		}

		result, err := runProxmoxCheck(cfg)
		if err != nil {
			return sdk.Critical(sanitizeError(err)), nil
		}

		return result, nil
	})
}

func loadConfig() (Config, error) {
	var raw map[string]any
	if err := sdk.LoadConfig(&raw); err != nil {
		return defaultConfig(), err
	}
	if len(raw) == 0 {
		return defaultConfig(), nil
	}

	return configFromMap(raw)
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

func runProxmoxCheck(cfg Config) (*sdk.Result, error) {
	cfg.applyDefaults()

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
	discovery := sdk.NewDeviceDiscovery(discoverySource)
	discovery.ObservedAt = now.Format(time.RFC3339Nano)
	discovery.CollectionID = "proxmox-" + strconv.FormatInt(now.Unix(), 10)

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
		addNodeDiscoveries(discovery, target, inventory.Nodes)
		addGuestDiscoveries(discovery, inventory.Guests)
	}

	if details.Summary.Targets == 0 {
		return nil, fmt.Errorf("all Proxmox targets failed: %s", joinErrors(details.Errors))
	}

	if len(details.Errors) == 0 {
		details.Errors = nil
	}

	body, err := json.Marshal(details)
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

	result := sdk.NewResult().
		WithStatus(status).
		WithSummary(summary).
		WithDetails(string(body)).
		WithObservedAt(now)
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
	emitResourceEvents(result, details)
	result.AddLabel("plugin_id", pluginID)
	result.WithDeviceDiscovery(*discovery)

	return result, nil
}

func defaultConfig() Config {
	return Config{TimeoutMS: defaultTimeoutMS}
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
	inventory.Nodes = enrichNodes(cfg, target, token, nodes, inventory.Warnings)

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
			node.RuntimeState = sanitizeMap(status)
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

func fetchNodeStatus(cfg Config, target Target, token, node string) (map[string]any, error) {
	var envelope proxmoxMapResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node status: %w", err)
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
		Status: sanitizeMap(status),
	}

	if osds, err := fetchNodeCephList(cfg, target, token, node, "osd"); err == nil {
		ceph.OSDs = sanitizeMapList(osds)
	}
	if pools, err := fetchNodeCephList(cfg, target, token, node, "pool"); err == nil {
		ceph.Pools = sanitizeMapList(pools)
	}
	if filesystems, err := fetchNodeCephList(cfg, target, token, node, "fs"); err == nil {
		ceph.FS = sanitizeMapList(filesystems)
	}

	return ceph, nil
}

func fetchNodeCephStatus(cfg Config, target Target, token, node string) (map[string]any, error) {
	var envelope proxmoxMapResponse
	path := "/api2/json/nodes/" + url.PathEscape(node) + "/ceph/status"
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node ceph status: %w", err)
	}

	return envelope.Data, nil
}

func fetchNodeCephList(cfg Config, target Target, token, node, family string) ([]map[string]any, error) {
	var envelope proxmoxMapListResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/ceph/%s", url.PathEscape(node), family)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch node ceph %s: %w", family, err)
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

		status, err := fetchGuestStatus(cfg, target, token, resource.Node, kind, resource.VMID)
		if err != nil {
			warnings[fmt.Sprintf("guest:%s:%d:status", kind, resource.VMID)] = sanitizeError(err)
		} else {
			guest.RuntimeStatus = sanitizeMap(status)
		}

		config, err := fetchGuestConfig(cfg, target, token, resource.Node, kind, resource.VMID)
		if err != nil {
			warnings[fmt.Sprintf("guest:%s:%d:config", kind, resource.VMID)] = sanitizeError(err)
		} else {
			guest.Config = sanitizeMap(config)
		}

		out = append(out, guest)
	}

	return out
}

func fetchGuestStatus(cfg Config, target Target, token, node, kind string, vmid int) (map[string]any, error) {
	var envelope proxmoxMapResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/%s/%d/status/current", url.PathEscape(node), kind, vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest status: %w", err)
	}

	return envelope.Data, nil
}

func fetchGuestConfig(cfg Config, target Target, token, node, kind string, vmid int) (map[string]any, error) {
	var envelope proxmoxMapResponse
	path := fmt.Sprintf("/api2/json/nodes/%s/%s/%d/config", url.PathEscape(node), kind, vmid)
	if err := getJSON(cfg, target, token, path, &envelope); err != nil {
		return nil, fmt.Errorf("fetch guest config: %w", err)
	}

	return envelope.Data, nil
}

func getJSON(cfg Config, target Target, token, path string, out any) error {
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
		return fmt.Errorf("HTTP %d", resp.Status)
	}
	if err := json.Unmarshal(resp.Body, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	return nil
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
			Metadata: map[string]any{
				"proxmox": map[string]any{
					"kind":    "node",
					"node":    node.Node,
					"cpu":     node.CPU,
					"max_cpu": node.MaxCPU,
					"mem":     node.Mem,
					"max_mem": node.MaxMem,
					"uptime":  node.Uptime,
				},
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
			Metadata: map[string]any{
				"proxmox": map[string]any{
					"kind":     kind,
					"node":     guest.Node,
					"vmid":     guest.VMID,
					"id":       guest.ID,
					"cpu":      guest.CPU,
					"max_cpu":  guest.MaxCPU,
					"mem":      guest.Mem,
					"max_mem":  guest.MaxMem,
					"disk":     guest.Disk,
					"max_disk": guest.MaxDisk,
					"uptime":   guest.Uptime,
				},
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
	return ceph.Health == "" && len(ceph.Status) == 0 && len(ceph.OSDs) == 0 && len(ceph.Pools) == 0 && len(ceph.FS) == 0
}

func cephHealth(status map[string]any) string {
	if status == nil {
		return ""
	}
	if health := stringAny(status["health"]); health != "" {
		return health
	}
	if health, ok := status["health"].(map[string]any); ok {
		return firstNonEmpty(
			stringAny(health["status"]),
			stringAny(health["overall_status"]),
		)
	}
	if health, ok := status["health"].(map[any]any); ok {
		return firstNonEmpty(
			stringAny(health["status"]),
			stringAny(health["overall_status"]),
		)
	}

	return firstNonEmpty(
		stringAny(status["overall_status"]),
		stringAny(status["status"]),
	)
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

func floatValue(values map[string]any, key string) float64 {
	if values == nil {
		return 0
	}
	switch value := values[key].(type) {
	case float64:
		return value
	case float32:
		return float64(value)
	case int:
		return float64(value)
	case int64:
		return float64(value)
	case json.Number:
		parsed, _ := value.Float64()
		return parsed
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
		return "REDACTED"
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
	if idx := strings.Index(msg, "PVEAPIToken="); idx >= 0 {
		msg = msg[:idx] + "PVEAPIToken=REDACTED"
	}

	return msg
}

func primeTinyGoJSON() {
	var cfg Config
	var inputs sdk.PluginInputsPayload
	var version proxmoxVersionResponse
	var nodes proxmoxNodesResponse
	var resources proxmoxResourcesResponse
	var cluster proxmoxClusterStatusResponse
	var data proxmoxMapResponse
	_ = json.Unmarshal([]byte(`{"targets":[]}`), &cfg)
	_ = json.Unmarshal([]byte(`{"schema":"serviceradar.plugin_inputs.v1","inputs":[]}`), &inputs)
	_ = json.Unmarshal([]byte(`{"data":{}}`), &version)
	_ = json.Unmarshal([]byte(`{"data":[]}`), &cluster)
	_ = json.Unmarshal([]byte(`{"data":[]}`), &nodes)
	_ = json.Unmarshal([]byte(`{"data":[]}`), &resources)
	_ = json.Unmarshal([]byte(`{"data":{}}`), &data)
}

func main() {}
