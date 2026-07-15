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

package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/hashutil"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

type pluginAssignment struct {
	AssignmentID string
	PluginID     string
	PackageID    string
	Version      string
	Name         string
	Entrypoint   string
	Runtime      string
	Outputs      string
	Capabilities map[string]bool
	ParamsJSON   []byte
	Permissions  pluginPermissions
	Resources    pluginResources
	Interval     time.Duration
	Timeout      time.Duration
	WasmObject   string
	ContentHash  string
	// generation is the deterministic stable assignment fingerprint captured by
	// every execution. Volatile download and broker lease rotation does not
	// change it; any policy, host-authority, package, permission, or parameter
	// change does.
	generation string
	// DownloadURL/DownloadToken are the gateway-signed artifact download
	// request. The token is short-lived and re-minted by the control plane on
	// every config generation, so it can be refreshed in place (see
	// setDownloadCredentials) without restarting runners. Access through the
	// accessors below once the assignment is shared with runner goroutines.
	DownloadURL   string
	DownloadToken string

	// Scheduled AWX inventory credentials are retained only by the trusted host
	// runtime. ParamsJSON is scrubbed before it can back get_config.
	scheduledAWXInventorySync              bool
	awxInventoryHostCredentials            map[string]awxInventoryHostCredentialBinding
	awxInventoryHostCredentialsFingerprint string

	// Generic Proxmox host authority remains outside ParamsJSON and is guarded
	// independently because refreshed broker leases can arrive while scheduled
	// runners and streaming assignments are live.
	proxmoxHostAuthorityRequired   bool
	pluginHostAuthority            []pluginHostAuthorityBinding
	pluginHostAuthorityFingerprint string
	hostAuthorityMu                sync.RWMutex

	downloadMu sync.RWMutex
}

// downloadCredentials returns the current artifact download URL and signed
// token. Safe for concurrent use with setDownloadCredentials.
func (a *pluginAssignment) downloadCredentials() (downloadURL, downloadToken string) {
	if a == nil {
		return "", ""
	}

	a.downloadMu.RLock()
	defer a.downloadMu.RUnlock()

	return a.DownloadURL, a.DownloadToken
}

// setDownloadCredentials refreshes the artifact download request in place.
// Empty URLs are ignored so a degraded control plane cannot wipe a previously
// valid download location; tokens always follow the supplied URL so freshly
// minted (rotating) tokens replace stale ones.
func (a *pluginAssignment) setDownloadCredentials(downloadURL, downloadToken string) {
	if a == nil || strings.TrimSpace(downloadURL) == "" {
		return
	}

	a.downloadMu.Lock()
	defer a.downloadMu.Unlock()

	a.DownloadURL = downloadURL
	a.DownloadToken = downloadToken
}

func (a *pluginAssignment) isStreaming() bool {
	if a == nil || a.Capabilities == nil {
		return false
	}
	return a.Capabilities[pluginCapabilityCameraMediaStream] || a.Capabilities[pluginCapabilityProxmoxConsole]
}

func (a *pluginAssignment) isActionOnly() bool {
	return a != nil && a.Capabilities != nil && a.Capabilities[pluginCapabilityActionOnly]
}

func (a *pluginAssignment) ingestsActionResults() bool {
	return a != nil && a.Capabilities != nil && a.Capabilities[pluginCapabilityActionResultIngest]
}

func (a *pluginAssignment) streamingSnapshot() StreamingPluginAssignment {
	if a == nil {
		return StreamingPluginAssignment{}
	}

	capabilities := make([]string, 0, len(a.Capabilities))
	for capability := range a.Capabilities {
		capabilities = append(capabilities, capability)
	}
	sort.Strings(capabilities)

	return StreamingPluginAssignment{
		AssignmentID: a.AssignmentID,
		PluginID:     a.PluginID,
		Name:         a.Name,
		Entrypoint:   a.Entrypoint,
		Runtime:      a.Runtime,
		Capabilities: capabilities,
	}
}

type pluginPermissions struct {
	AllowedDomains  []string `json:"allowed_domains"`
	AllowedNetworks []string `json:"allowed_networks"`
	AllowedPorts    []int    `json:"allowed_ports"`

	allowedDomainSet map[string]struct{}
	allowedPrefixes  []netip.Prefix
	allowedPortSet   map[int]struct{}
}

type pluginResources struct {
	RequestedMemoryMB  int `json:"requested_memory_mb"`
	RequestedCPUMS     int `json:"requested_cpu_ms"`
	MaxOpenConnections int `json:"max_open_connections"`
}

type pluginEngineLimits struct {
	MaxMemoryMB        int
	MaxCPUMS           int
	MaxConcurrent      int
	MaxOpenConnections int
}

type pluginConfigFingerprint struct {
	Limits      pluginEngineLimits            `json:"limits"`
	Assignments []pluginAssignmentFingerprint `json:"assignments"`
}

type pluginAssignmentFingerprint struct {
	AssignmentID     string                       `json:"assignment_id"`
	PluginID         string                       `json:"plugin_id"`
	PackageID        string                       `json:"package_id"`
	Version          string                       `json:"version"`
	Name             string                       `json:"name"`
	Entrypoint       string                       `json:"entrypoint"`
	Runtime          string                       `json:"runtime"`
	Outputs          string                       `json:"outputs"`
	Capabilities     []string                     `json:"capabilities"`
	ParamsBase64     string                       `json:"params_base64"`
	Permissions      pluginPermissionsFingerprint `json:"permissions"`
	Resources        pluginResources              `json:"resources"`
	IntervalSec      int64                        `json:"interval_sec"`
	TimeoutSec       int64                        `json:"timeout_sec"`
	WasmObject       string                       `json:"wasm_object"`
	ContentHash      string                       `json:"content_hash"`
	HostBindingsHash string                       `json:"host_bindings_hash,omitempty"`
}

type pluginPermissionsFingerprint struct {
	AllowedDomains  []string `json:"allowed_domains"`
	AllowedNetworks []string `json:"allowed_networks"`
	AllowedPorts    []int    `json:"allowed_ports"`
}

func engineLimitsFromProto(cfg *proto.PluginConfig) pluginEngineLimits {
	if cfg == nil || cfg.EngineLimits == nil {
		return pluginEngineLimits{}
	}

	limits := cfg.EngineLimits
	return pluginEngineLimits{
		MaxMemoryMB:        int(limits.MaxMemoryMb),
		MaxCPUMS:           int(limits.MaxCpuMs),
		MaxConcurrent:      int(limits.MaxConcurrent),
		MaxOpenConnections: int(limits.MaxOpenConnections),
	}
}

func buildPluginConfigHash(limits pluginEngineLimits, assignments []*pluginAssignment) string {
	fingerprint := pluginConfigFingerprint{
		Limits:      limits,
		Assignments: make([]pluginAssignmentFingerprint, 0, len(assignments)),
	}

	for _, assignment := range assignments {
		if assignment == nil {
			continue
		}
		fingerprint.Assignments = append(
			fingerprint.Assignments,
			buildAssignmentFingerprint(assignment),
		)
	}

	sort.Slice(fingerprint.Assignments, func(i, j int) bool {
		return fingerprint.Assignments[i].AssignmentID < fingerprint.Assignments[j].AssignmentID
	})

	data, err := json.Marshal(fingerprint)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func buildAssignmentFingerprint(assignment *pluginAssignment) pluginAssignmentFingerprint {
	capabilities := make([]string, 0, len(assignment.Capabilities))
	for cap := range assignment.Capabilities {
		capabilities = append(capabilities, cap)
	}
	sort.Strings(capabilities)

	allowedDomains := append([]string(nil), assignment.Permissions.AllowedDomains...)
	allowedNetworks := append([]string(nil), assignment.Permissions.AllowedNetworks...)
	allowedPorts := append([]int(nil), assignment.Permissions.AllowedPorts...)
	sort.Strings(allowedDomains)
	sort.Strings(allowedNetworks)
	sort.Ints(allowedPorts)

	params := ""
	if len(assignment.ParamsJSON) > 0 {
		params = base64.StdEncoding.EncodeToString(assignment.ParamsJSON)
	}

	return pluginAssignmentFingerprint{
		AssignmentID: assignment.AssignmentID,
		PluginID:     assignment.PluginID,
		PackageID:    assignment.PackageID,
		Version:      assignment.Version,
		Name:         assignment.Name,
		Entrypoint:   assignment.Entrypoint,
		Runtime:      assignment.Runtime,
		Outputs:      assignment.Outputs,
		Capabilities: capabilities,
		ParamsBase64: params,
		Permissions: pluginPermissionsFingerprint{
			AllowedDomains:  allowedDomains,
			AllowedNetworks: allowedNetworks,
			AllowedPorts:    allowedPorts,
		},
		Resources:        assignment.Resources,
		IntervalSec:      int64(assignment.Interval / time.Second),
		TimeoutSec:       int64(assignment.Timeout / time.Second),
		WasmObject:       assignment.WasmObject,
		ContentHash:      assignment.ContentHash,
		HostBindingsHash: assignment.hostBindingsFingerprint(),
	}
}

func buildPluginAssignmentGeneration(assignment *pluginAssignment) string {
	if assignment == nil {
		return ""
	}

	data, err := json.Marshal(buildAssignmentFingerprint(assignment))
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func (a *pluginAssignment) hostBindingsFingerprint() string {
	if a == nil {
		return ""
	}
	_, hostAuthorityFingerprint := a.pluginHostAuthoritySnapshot()
	if hostAuthorityFingerprint != "" {
		return hostAuthorityFingerprint
	}
	return a.awxInventoryHostCredentialsFingerprint
}

func buildStreamingPluginConfig(baseParams []byte, spec cameraRelaySessionSpec) ([]byte, error) {
	relay := map[string]interface{}{
		"relay_session_id":     spec.RelaySessionID,
		"agent_id":             spec.AgentID,
		"gateway_id":           spec.GatewayID,
		"camera_source_id":     spec.CameraSourceID,
		"stream_profile_id":    spec.StreamProfileID,
		"lease_token":          spec.LeaseToken,
		"source_url":           spec.SourceURL,
		"rtsp_transport":       spec.RTSPTransport,
		"codec_hint":           spec.CodecHint,
		"container_hint":       spec.ContainerHint,
		"plugin_assignment_id": spec.PluginAssignmentID,
	}

	if len(bytes.TrimSpace(baseParams)) == 0 {
		return json.Marshal(map[string]interface{}{"relay": relay})
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(baseParams, &parsed); err == nil {
		parsed["relay"] = relay
		return json.Marshal(parsed)
	}

	return json.Marshal(map[string]interface{}{
		"relay":                    relay,
		"plugin_config_raw_base64": base64.StdEncoding.EncodeToString(baseParams),
	})
}

func newPluginAssignment(cfg *proto.PluginAssignmentConfig, log logger.Logger) *pluginAssignment {
	assignment := &pluginAssignment{
		AssignmentID:  cfg.AssignmentId,
		PluginID:      cfg.PluginId,
		PackageID:     cfg.PackageId,
		Version:       cfg.Version,
		Name:          cfg.Name,
		Entrypoint:    cfg.Entrypoint,
		Runtime:       cfg.Runtime,
		Outputs:       cfg.Outputs,
		Capabilities:  make(map[string]bool),
		ParamsJSON:    cfg.ParamsJson,
		Interval:      time.Duration(cfg.IntervalSec) * time.Second,
		Timeout:       time.Duration(cfg.TimeoutSec) * time.Second,
		WasmObject:    strings.TrimSpace(cfg.WasmObjectKey),
		ContentHash:   strings.TrimSpace(cfg.ContentHash),
		DownloadURL:   strings.TrimSpace(cfg.DownloadUrl),
		DownloadToken: strings.TrimSpace(cfg.DownloadToken),
	}

	for _, cap := range cfg.Capabilities {
		clean := strings.TrimSpace(cap)
		if clean == "" {
			continue
		}
		assignment.Capabilities[clean] = true
	}

	if len(cfg.PermissionsJson) > 0 {
		if err := json.Unmarshal(cfg.PermissionsJson, &assignment.Permissions); err != nil {
			log.Warn().Err(err).Str("assignment_id", assignment.AssignmentID).Msg("Invalid plugin permissions JSON")
		}
	}

	if len(cfg.ResourcesJson) > 0 {
		if err := json.Unmarshal(cfg.ResourcesJson, &assignment.Resources); err != nil {
			log.Warn().Err(err).Str("assignment_id", assignment.AssignmentID).Msg("Invalid plugin resources JSON")
		}
	}

	assignment.Permissions.normalize()
	assignment.ContentHash = normalizeContentHash(assignment.ContentHash, log, assignment.AssignmentID)
	if err := assignment.prepareAWXInventoryHostCredentials(cfg.GetHostParamsJson()); err != nil {
		// The parser returns structural static errors only; never include raw
		// params, controller URLs, headers, or bearer material in this log.
		log.Warn().Err(err).
			Str("assignment_id", assignment.AssignmentID).
			Msg("Rejected scheduled AWX inventory host credential configuration")
	}
	if err := assignment.preparePluginHostAuthority(cfg.GetHostParamsJson()); err != nil {
		// Never include host params, origins, grant identifiers, or secret refs in
		// this log. A rejected assignment remains present but unusable and exposes
		// only an empty object through get_config.
		log.Warn().Err(err).
			Str("assignment_id", assignment.AssignmentID).
			Msg("Rejected Proxmox plugin host authority configuration")
	}

	if assignment.Interval <= 0 {
		assignment.Interval = pluginDefaultInterval
	}
	if assignment.Timeout <= 0 {
		assignment.Timeout = pluginDefaultTimeout
	}
	assignment.generation = buildPluginAssignmentGeneration(assignment)

	return assignment
}

func normalizeContentHash(hash string, log logger.Logger, assignmentID string) string {
	if hash == "" {
		return ""
	}
	canonical, err := hashutil.CanonicalHexSHA256(hash)
	if err != nil {
		log.Warn().Err(err).Str("assignment_id", assignmentID).Msg("Invalid content hash")
		return ""
	}
	return canonical
}

func (p *pluginPermissions) normalize() {
	p.allowedDomainSet = make(map[string]struct{})
	for _, domain := range p.AllowedDomains {
		trimmed := strings.ToLower(strings.TrimSpace(domain))
		if trimmed == "" {
			continue
		}
		p.allowedDomainSet[trimmed] = struct{}{}
	}

	p.allowedPortSet = make(map[int]struct{})
	for _, port := range p.AllowedPorts {
		if port <= 0 {
			continue
		}
		p.allowedPortSet[port] = struct{}{}
	}

	p.allowedPrefixes = p.allowedPrefixes[:0]
	for _, network := range p.AllowedNetworks {
		trimmed := strings.TrimSpace(network)
		if trimmed == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(trimmed)
		if err != nil {
			continue
		}
		p.allowedPrefixes = append(p.allowedPrefixes, prefix)
	}
}

func (p *pluginPermissions) allowsDomain(host string) bool {
	if len(p.allowedDomainSet) == 0 {
		return false
	}

	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "" {
		return false
	}

	if _, ok := p.allowedDomainSet["*"]; ok {
		return true
	}

	if _, ok := p.allowedDomainSet[host]; ok {
		return true
	}

	for entry := range p.allowedDomainSet {
		if strings.HasPrefix(entry, "*.") {
			base := strings.TrimPrefix(entry, "*.")
			if host == base || strings.HasSuffix(host, "."+base) {
				return true
			}
		}
	}

	return false
}

func (p *pluginPermissions) allowsHTTPHost(host string) bool {
	host = strings.TrimSuffix(strings.TrimSpace(host), ".")
	if host == "" {
		return false
	}

	addr, err := netip.ParseAddr(host)
	if err != nil {
		return p.allowsDomain(host)
	}

	// Literal IP destinations are network-scoped. Retain compatibility for
	// manifests that listed one exact IP in allowed_domains, but never let a
	// domain wildcard expand into an arbitrary IP/network permission.
	if p.allowsAddress(addr) {
		return true
	}
	if unmapped := addr.Unmap(); unmapped != addr && p.allowsAddress(unmapped) {
		return true
	}

	for domain := range p.allowedDomainSet {
		allowedAddr, parseErr := netip.ParseAddr(strings.TrimSuffix(domain, "."))
		if parseErr == nil && allowedAddr.Unmap() == addr.Unmap() {
			return true
		}
	}

	return false
}

func (p *pluginPermissions) allowsPort(port int) bool {
	if len(p.allowedPortSet) == 0 {
		return true
	}
	_, ok := p.allowedPortSet[port]
	return ok
}

func (p *pluginPermissions) allowsHTTPPort(port int) bool {
	if len(p.allowedPortSet) == 0 {
		return false
	}
	_, ok := p.allowedPortSet[port]
	return ok
}

func (p *pluginPermissions) allowsAddress(addr netip.Addr) bool {
	if len(p.allowedPrefixes) == 0 {
		return false
	}
	for _, prefix := range p.allowedPrefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}
