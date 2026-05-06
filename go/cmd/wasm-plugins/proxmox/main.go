// Package main implements the Proxmox inventory WASM plugin for ServiceRadar.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
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
	BaseURL            string   `json:"base_url"`
	APIToken           string   `json:"api_token"`
	APITokenSecretRef  string   `json:"api_token_secret_ref"`
	Targets            []Target `json:"targets"`
	TimeoutMS          int      `json:"timeout_ms"`
	IncludeGuests      *bool    `json:"include_guests"`
	InsecureSkipVerify bool     `json:"insecure_skip_verify"`
}

type Target struct {
	BaseURL   string `json:"base_url"`
	APIToken  string `json:"api_token"`
	DeviceID  string `json:"device_id"`
	Hostname  string `json:"hostname"`
	Partition string `json:"partition"`
}

type checkSummary struct {
	Targets int `json:"targets"`
	Nodes   int `json:"nodes"`
	Guests  int `json:"guests"`
}

type proxmoxNodesResponse struct {
	Data []proxmoxNode `json:"data"`
}

type proxmoxResourcesResponse struct {
	Data []proxmoxResource `json:"data"`
}

type proxmoxNode struct {
	Node   string  `json:"node"`
	Status string  `json:"status"`
	CPU    float64 `json:"cpu"`
	MaxCPU float64 `json:"maxcpu"`
	Mem    float64 `json:"mem"`
	MaxMem float64 `json:"maxmem"`
	Uptime float64 `json:"uptime"`
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

type proxmoxDetails struct {
	Schema  string            `json:"schema"`
	Targets []proxmoxTarget   `json:"targets"`
	Summary checkSummary      `json:"summary"`
	Errors  map[string]string `json:"errors,omitempty"`
}

type proxmoxTarget struct {
	BaseURL string            `json:"base_url"`
	Nodes   []proxmoxNode     `json:"nodes"`
	Guests  []proxmoxResource `json:"guests,omitempty"`
	Meta    map[string]string `json:"metadata,omitempty"`
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
		nodes, guests, err := fetchTargetInventory(cfg, target)
		if err != nil {
			details.Errors[target.safeName()] = sanitizeError(err)
			continue
		}

		details.Targets = append(details.Targets, proxmoxTarget{
			BaseURL: target.redactedBaseURL(),
			Nodes:   nodes,
			Guests:  guests,
			Meta:    targetMetadata(target),
		})
		details.Summary.Targets++
		details.Summary.Nodes += len(nodes)
		details.Summary.Guests += len(guests)
		addNodeDiscoveries(discovery, target, nodes)
		addGuestDiscoveries(discovery, guests)
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

	result := sdk.NewResult().
		WithStatus(status).
		WithSummary(summary).
		WithDetails(string(body)).
		WithObservedAt(now)
	result.AddMetric("proxmox_targets", float64(details.Summary.Targets), "count", nil)
	result.AddMetric("proxmox_nodes", float64(details.Summary.Nodes), "count", nil)
	result.AddMetric("proxmox_guests", float64(details.Summary.Guests), "count", nil)
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

func fetchTargetInventory(cfg Config, target Target) ([]proxmoxNode, []proxmoxResource, error) {
	token := strings.TrimSpace(firstNonEmpty(target.APIToken, cfg.APIToken))
	if token == "" {
		return nil, nil, errMissingToken
	}

	nodes, err := fetchNodes(cfg, target, token)
	if err != nil {
		return nil, nil, err
	}

	if !cfg.includeGuests() {
		return nodes, nil, nil
	}

	guests, err := fetchGuests(cfg, target, token)
	if err != nil {
		return nil, nil, err
	}

	return nodes, guests, nil
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

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    firstNonEmpty(target.DeviceID, "proxmox:pve:"+node.Node),
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

func addGuestDiscoveries(discovery *sdk.DeviceDiscovery, guests []proxmoxResource) {
	for _, guest := range guests {
		kind := normalizeGuestKind(guest.Type)
		available := strings.EqualFold(guest.Status, "running")

		discovery.AddDevice(sdk.DiscoveredDevice{
			DeviceID:    proxmoxGuestID(guest),
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
		BaseURL: baseURLForItem(item, cfg),
		APIToken: firstNonEmpty(
			stringValue(item, "api_token"),
			stringValue(item, "proxmox_api_token"),
			cfg.APIToken,
		),
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
	var nodes proxmoxNodesResponse
	var resources proxmoxResourcesResponse
	_ = json.Unmarshal([]byte(`{"base_url":"https://pve.example:8006","api_token":"x","targets":[]}`), &cfg)
	_ = json.Unmarshal([]byte(`{"schema":"serviceradar.plugin_inputs.v1","policy_id":"p","policy_version":1,"agent_id":"a","generated_at":"2026-05-06T00:00:00Z","inputs":[{"name":"targets","entity":"devices","query":"in:devices","chunk_index":0,"chunk_total":1,"chunk_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","items":[{"uid":"d","ip":"192.0.2.10"}]}]}`), &inputs)
	_ = json.Unmarshal([]byte(`{"data":[{"node":"pve","status":"online"}]}`), &nodes)
	_ = json.Unmarshal([]byte(`{"data":[{"id":"qemu/100","node":"pve","type":"qemu","vmid":100}]}`), &resources)
}

func main() {}
