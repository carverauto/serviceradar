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
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

var (
	errProxmoxAuthenticationRequired = errors.New("proxmox authentication required")
	errProxmoxAllAttemptsFailed      = errors.New("all proxmox API attempts failed")
	errProxmoxRequestFailed          = errors.New("proxmox request failed")
)

const (
	proxmoxCandidateProbeOption = "proxmox_candidate_probe_enabled"
	proxmoxDefaultAPIPort       = "8006"
	proxmoxFingerprintMaxBytes  = 64 * 1024
)

type proxmoxEnvelope[T any] struct {
	Data T `json:"data"`
}

type proxmoxAuthTicket struct {
	Ticket string `json:"ticket"`
}

type proxmoxNode struct {
	Node string `json:"node"`
}

type proxmoxVMResource struct {
	Type     string `json:"type"`
	VMID     int    `json:"vmid"`
	Name     string `json:"name"`
	Node     string `json:"node"`
	Status   string `json:"status"`
	Template int    `json:"template"`
}

type proxmoxSession struct {
	authHeader string
	authCookie string
}

func (e *DiscoveryEngine) createProxmoxClient(apiConfig ProxmoxAPIConfig) *http.Client {
	return &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify, //nolint:gosec // operator-controlled discovery setting
			},
		},
	}
}

func (e *DiscoveryEngine) proxmoxAPIsForJob(job *DiscoveryJob) []ProxmoxAPIConfig {
	filtered, selectors := selectNamedBaseURLConfigs(
		job,
		e.config.ProxmoxAPIs,
		"proxmox_api_names",
		"proxmox_api_urls",
		func(api ProxmoxAPIConfig) string { return api.Name },
		func(api ProxmoxAPIConfig) string { return api.BaseURL },
	)

	if len(filtered) == 0 && selectors != "" {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("job_name", job.Params.Options["mapper_job_name"]).
			Str("selectors", selectors).
			Msg("No Proxmox API matched job selectors")
	}

	return filtered
}

func (e *DiscoveryEngine) queryProxmoxDevices(
	ctx context.Context,
	job *DiscoveryJob,
) ([]*DiscoveredDevice, []*TopologyLink, error) {
	selectedAPIs := e.proxmoxAPIsForJob(job)
	if len(selectedAPIs) == 0 {
		return nil, nil, nil
	}

	allDevices := make([]*DiscoveredDevice, 0, len(selectedAPIs)*2)
	allLinks := make([]*TopologyLink, 0, len(selectedAPIs)*4)
	errorsEncountered := 0

	for _, apiConfig := range selectedAPIs {
		devices, links, err := e.fetchProxmoxInventory(ctx, apiConfig)
		if err != nil {
			errorsEncountered++
			e.logger.Warn().
				Str("job_id", job.ID).
				Str("api_name", apiConfig.Name).
				Str("base_url", apiConfig.BaseURL).
				Err(err).
				Msg("Proxmox API discovery failed")
			continue
		}

		allDevices = append(allDevices, devices...)
		allLinks = append(allLinks, links...)
	}

	if len(allDevices) == 0 && errorsEncountered == len(selectedAPIs) {
		return nil, nil, fmt.Errorf("%w: attempts=%d", errProxmoxAllAttemptsFailed, errorsEncountered)
	}

	return allDevices, allLinks, nil
}

func (e *DiscoveryEngine) fetchProxmoxInventory(
	ctx context.Context,
	apiConfig ProxmoxAPIConfig,
) ([]*DiscoveredDevice, []*TopologyLink, error) {
	client := e.createProxmoxClient(apiConfig)

	session, err := e.proxmoxSession(ctx, client, apiConfig)
	if err != nil {
		return nil, nil, err
	}

	var nodes []proxmoxNode
	if err := e.proxmoxGET(ctx, client, apiConfig, session, "/nodes", &nodes); err != nil {
		return nil, nil, err
	}

	var resources []proxmoxVMResource
	if err := e.proxmoxGET(ctx, client, apiConfig, session, "/cluster/resources?type=vm", &resources); err != nil {
		return nil, nil, err
	}

	return buildProxmoxInventory(apiConfig, nodes, resources), buildProxmoxHostedLinks(apiConfig, nodes, resources), nil
}

func shouldProbeProxmoxCandidates(job *DiscoveryJob) bool {
	if job == nil || job.Params == nil || job.Params.Options == nil {
		return false
	}

	return isTruthyOption(job.Params.Options[proxmoxCandidateProbeOption])
}

func (e *DiscoveryEngine) probeProxmoxCandidates(
	ctx context.Context,
	job *DiscoveryJob,
	seeds []string,
) []*DiscoveredDevice {
	if !shouldProbeProxmoxCandidates(job) {
		return nil
	}

	client := &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true, //nolint:gosec // unauthenticated fingerprinting of self-signed PVE UI
			},
		},
	}

	devices := make([]*DiscoveredDevice, 0)
	for _, seed := range seeds {
		baseURL := proxmoxCandidateBaseURL(seed)
		if baseURL == "" {
			continue
		}

		device, err := e.probeProxmoxCandidate(ctx, client, baseURL)
		if err != nil {
			e.logger.Debug().
				Str("job_id", job.ID).
				Str("base_url", baseURL).
				Err(err).
				Msg("Proxmox candidate fingerprint failed")
			continue
		}

		devices = append(devices, device)
	}

	return devices
}

func (e *DiscoveryEngine) probeProxmoxKnownDeviceCandidates(ctx context.Context, job *DiscoveryJob) {
	seeds := proxmoxCandidateSeedsFromJob(job)
	if len(seeds) == 0 {
		return
	}

	devices := e.probeProxmoxCandidates(ctx, job, seeds)
	if len(devices) == 0 {
		return
	}

	job.mu.Lock()
	defer job.mu.Unlock()

	e.processDevicesForSNMPTargets(job, devices, map[string]bool{}, map[string]string{})
}

func proxmoxCandidateSeedsFromJob(job *DiscoveryJob) []string {
	if job == nil || job.Results == nil {
		return nil
	}

	seen := make(map[string]struct{})
	seeds := make([]string, 0, len(job.Results.Devices))

	for _, device := range job.Results.Devices {
		if device == nil {
			continue
		}
		ip := strings.TrimSpace(device.IP)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		seeds = append(seeds, ip)
	}

	return seeds
}

func (e *DiscoveryEngine) probeProxmoxCandidate(
	ctx context.Context,
	client *http.Client,
	baseURL string,
) (*DiscoveredDevice, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "text/html,application/xhtml+xml")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: status=%d", errProxmoxRequestFailed, resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, proxmoxFingerprintMaxBytes))
	if err != nil {
		return nil, err
	}

	host := proxmoxBaseHostname(baseURL)
	nodeName, ok := proxmoxFingerprintFromHTML(string(body))
	if !ok {
		return nil, fmt.Errorf("%w: missing PVE web fingerprint", errProxmoxRequestFailed)
	}

	return buildProxmoxCandidateDevice(host, nodeName), nil
}

func proxmoxCandidateBaseURL(seed string) string {
	seed = strings.TrimSpace(seed)
	if seed == "" {
		return ""
	}

	if strings.Contains(seed, "://") {
		parsed, err := url.Parse(seed)
		if err != nil {
			return ""
		}
		seed = parsed.Host
	}

	host := seed
	if splitHost, _, err := net.SplitHostPort(seed); err == nil {
		host = splitHost
	}
	host = strings.Trim(host, "[]")
	if host == "" {
		return ""
	}

	return "https://" + net.JoinHostPort(host, proxmoxDefaultAPIPort)
}

func proxmoxFingerprintFromHTML(body string) (string, bool) {
	lower := strings.ToLower(body)
	if !strings.Contains(lower, "proxmox virtual environment") &&
		!strings.Contains(lower, "pve.stdworkspace") {
		return "", false
	}

	const suffix = " - Proxmox Virtual Environment"
	if start := strings.Index(strings.ToLower(body), "<title>"); start >= 0 {
		titleStart := start + len("<title>")
		if end := strings.Index(strings.ToLower(body[titleStart:]), "</title>"); end >= 0 {
			title := strings.TrimSpace(body[titleStart : titleStart+end])
			if strings.HasSuffix(title, suffix) {
				return strings.TrimSpace(strings.TrimSuffix(title, suffix)), true
			}
			if title != "" {
				return title, true
			}
		}
	}

	return "", true
}

func buildProxmoxCandidateDevice(host, nodeName string) *DiscoveredDevice {
	hostname := strings.TrimSpace(nodeName)
	if hostname == "" {
		hostname = host
	}

	return &DiscoveredDevice{
		DeviceID: GenerateDeviceIDFromIP(host),
		IP:       host,
		Hostname: hostname,
		Metadata: map[string]string{
			"source":                        "proxmox-candidate",
			"identity_source":               "proxmox_unauthenticated_https_8006",
			"device_role":                   "hypervisor",
			"proxmox_candidate":             "true",
			"proxmox_candidate_source":      "unauthenticated_https_8006",
			"proxmox_candidate_evidence":    "pve_web_fingerprint",
			"proxmox_candidate_observed_at": time.Now().UTC().Format(time.RFC3339),
			"proxmox_candidate_port":        proxmoxDefaultAPIPort,
			"proxmox_candidate_service":     "pve-web-ui",
			"proxmox_candidate_title":       hostname,
			"snmp_target_eligible":          "false",
		},
	}
}

func (e *DiscoveryEngine) proxmoxSession(
	ctx context.Context,
	client *http.Client,
	apiConfig ProxmoxAPIConfig,
) (*proxmoxSession, error) {
	tokenID := strings.TrimSpace(apiConfig.TokenID)
	tokenSecret := strings.TrimSpace(apiConfig.TokenSecret)
	if tokenID != "" && tokenSecret != "" {
		return &proxmoxSession{
			authHeader: "PVEAPIToken=" + tokenID + "=" + tokenSecret,
		}, nil
	}

	username := strings.TrimSpace(apiConfig.Username)
	password := strings.TrimSpace(apiConfig.Password)
	if username == "" || password == "" {
		return nil, errProxmoxAuthenticationRequired
	}

	if realm := strings.TrimSpace(apiConfig.Realm); realm != "" && !strings.Contains(username, "@") {
		username += "@" + realm
	}

	form := url.Values{}
	form.Set("username", username)
	form.Set("password", password)

	baseURL := proxmoxAPIBaseURL(apiConfig)
	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		baseURL+"/access/ticket",
		strings.NewReader(form.Encode()),
	)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("%w: status=%d body=%s", errProxmoxRequestFailed, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var ticketResp proxmoxEnvelope[proxmoxAuthTicket]
	if err := json.NewDecoder(resp.Body).Decode(&ticketResp); err != nil {
		return nil, err
	}

	if strings.TrimSpace(ticketResp.Data.Ticket) == "" {
		return nil, errProxmoxAuthenticationRequired
	}

	return &proxmoxSession{
		authCookie: "PVEAuthCookie=" + ticketResp.Data.Ticket,
	}, nil
}

func (e *DiscoveryEngine) proxmoxGET(
	ctx context.Context,
	client *http.Client,
	apiConfig ProxmoxAPIConfig,
	session *proxmoxSession,
	path string,
	out any,
) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, proxmoxAPIBaseURL(apiConfig)+path, nil)
	if err != nil {
		return err
	}

	req.Header.Set("Accept", "application/json")
	if session != nil {
		if strings.TrimSpace(session.authHeader) != "" {
			req.Header.Set("Authorization", session.authHeader)
		}
		if strings.TrimSpace(session.authCookie) != "" {
			req.Header.Set("Cookie", session.authCookie)
		}
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%w: status=%d body=%s", errProxmoxRequestFailed, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var envelope proxmoxEnvelope[json.RawMessage]
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return err
	}

	return json.Unmarshal(envelope.Data, out)
}

func proxmoxAPIBaseURL(apiConfig ProxmoxAPIConfig) string {
	return strings.TrimRight(strings.TrimSpace(apiConfig.BaseURL), "/") + "/api2/json"
}

func buildProxmoxInventory(
	apiConfig ProxmoxAPIConfig,
	nodes []proxmoxNode,
	resources []proxmoxVMResource,
) []*DiscoveredDevice {
	devices := make([]*DiscoveredDevice, 0, len(nodes)+len(resources))
	nodeHints := proxmoxNodeAddressHints(apiConfig, nodes)

	for _, node := range nodes {
		nodeName := strings.TrimSpace(node.Node)
		if nodeName == "" {
			continue
		}

		hostHint := nodeHints[nodeName]
		deviceID := proxmoxNodeDeviceID(apiConfig, nodeName, hostHint)

		metadata := map[string]string{
			"source":              "proxmox-api",
			"identity_source":     "proxmox-api",
			"device_role":         "hypervisor",
			"virtualization_node": nodeName,
		}
		if hostHint == "" {
			metadata["snmp_target_eligible"] = "false"
		}

		devices = append(devices, &DiscoveredDevice{
			DeviceID:  deviceID,
			IP:        hostHint,
			Hostname:  nodeName,
			SysName:   nodeName,
			SysDescr:  "Proxmox VE node",
			Metadata:  metadata,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		})
	}

	for _, resource := range resources {
		guestName := strings.TrimSpace(resource.Name)
		nodeName := strings.TrimSpace(resource.Node)
		if guestName == "" || nodeName == "" || strings.EqualFold(strings.TrimSpace(resource.Type), "storage") {
			continue
		}
		if resource.Template != 0 {
			continue
		}

		deviceID := proxmoxGuestDeviceID(apiConfig, nodeName, resource.VMID, guestName)
		metadata := map[string]string{
			"source":                    "proxmox-api",
			"identity_source":           "proxmox-api",
			"identity_state":            "provisional",
			"device_role":               "virtual-guest",
			"virtualization_host_node":  nodeName,
			"virtualization_guest_type": strings.TrimSpace(resource.Type),
			"virtualization_guest_vmid": strconv.Itoa(resource.VMID),
			"virtualization_status":     strings.TrimSpace(resource.Status),
			"snmp_target_eligible":      "false",
		}

		devices = append(devices, &DiscoveredDevice{
			DeviceID:  deviceID,
			Hostname:  guestName,
			SysName:   guestName,
			SysDescr:  "Proxmox virtual guest",
			Metadata:  metadata,
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		})
	}

	return devices
}

func buildProxmoxHostedLinks(
	apiConfig ProxmoxAPIConfig,
	nodes []proxmoxNode,
	resources []proxmoxVMResource,
) []*TopologyLink {
	links := make([]*TopologyLink, 0, len(resources))
	nodeHints := proxmoxNodeAddressHints(apiConfig, nodes)

	for _, resource := range resources {
		guestName := strings.TrimSpace(resource.Name)
		nodeName := strings.TrimSpace(resource.Node)
		if guestName == "" || nodeName == "" {
			continue
		}
		if resource.Template != 0 {
			continue
		}

		hostHint := nodeHints[nodeName]
		hostID := proxmoxNodeDeviceID(apiConfig, nodeName, hostHint)
		guestID := proxmoxGuestDeviceID(apiConfig, nodeName, resource.VMID, guestName)

		links = append(links, &TopologyLink{
			Protocol:      "Proxmox-API",
			LocalDeviceIP: hostHint,
			LocalDeviceID: hostID,
			LocalIfName:   "hosted-guests",
			NeighborPortID: fmt.Sprintf(
				"vmid:%d",
				resource.VMID,
			),
			NeighborSystemName: guestName,
			NeighborIdentity: &TopologyNeighborIdentity{
				DeviceID:   guestID,
				SystemName: guestName,
			},
			Metadata: map[string]string{
				"source":                    "proxmox-api",
				"confidence_reason":         "authoritative_host_inventory",
				"virtualization_node":       nodeName,
				"virtualization_guest_type": strings.TrimSpace(resource.Type),
				"virtualization_guest_vmid": strconv.Itoa(resource.VMID),
				"virtualization_status":     strings.TrimSpace(resource.Status),
			},
		})
	}

	return links
}

func proxmoxNodeAddressHints(apiConfig ProxmoxAPIConfig, nodes []proxmoxNode) map[string]string {
	hints := make(map[string]string, len(nodes))
	baseHost := proxmoxBaseHostname(apiConfig.BaseURL)
	assignableHost := ""
	if ip := net.ParseIP(baseHost); ip != nil {
		assignableHost = ip.String()
	}

	if assignableHost == "" {
		return hints
	}

	if len(nodes) == 1 {
		nodeName := strings.TrimSpace(nodes[0].Node)
		if nodeName != "" {
			hints[nodeName] = assignableHost
		}
		return hints
	}

	for _, node := range nodes {
		nodeName := strings.TrimSpace(node.Node)
		if nodeName == "" {
			continue
		}
		if proxmoxNodeMatchesHost(nodeName, baseHost) {
			hints[nodeName] = assignableHost
		}
	}

	return hints
}

func proxmoxNodeMatchesHost(nodeName, host string) bool {
	normalizedNode := strings.ToLower(strings.TrimSpace(nodeName))
	normalizedHost := strings.ToLower(strings.TrimSpace(host))
	if normalizedNode == "" || normalizedHost == "" {
		return false
	}
	if normalizedNode == normalizedHost {
		return true
	}

	nodeShort := strings.Split(normalizedNode, ".")[0]
	hostShort := strings.Split(normalizedHost, ".")[0]
	return nodeShort != "" && nodeShort == hostShort
}

func proxmoxBaseHostname(rawBaseURL string) string {
	parsed, err := url.Parse(strings.TrimSpace(rawBaseURL))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(parsed.Hostname())
}

func proxmoxNodeDeviceID(apiConfig ProxmoxAPIConfig, nodeName, hostHint string) string {
	if ip := strings.TrimSpace(hostHint); ip != "" {
		return GenerateDeviceIDFromIP(ip)
	}

	return "proxmox-node-" + normalizeProxmoxIDComponent(apiConfig.Name) + "-" + normalizeProxmoxIDComponent(nodeName)
}

func proxmoxGuestDeviceID(apiConfig ProxmoxAPIConfig, nodeName string, vmid int, guestName string) string {
	return "proxmox-vm-" + normalizeProxmoxIDComponent(apiConfig.Name) + "-" +
		normalizeProxmoxIDComponent(nodeName) + "-" + strconv.Itoa(vmid) + "-" +
		normalizeProxmoxIDComponent(guestName)
}

func normalizeProxmoxIDComponent(value string) string {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return fallbackUnknown
	}

	var b strings.Builder
	lastDash := false
	for _, r := range normalized {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
			lastDash = false
		case r >= '0' && r <= '9':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}

	out := strings.Trim(b.String(), "-")
	if out == "" {
		return fallbackUnknown
	}
	return out
}
