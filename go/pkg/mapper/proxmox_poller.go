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
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/tlsclient"
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
	// A PVE node certificate lists a handful of names and addresses; the cap only
	// bounds what an arbitrary host answering on 8006 can push into metadata.
	proxmoxMaxCertificateSANs = 32
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
			TLSClientConfig: tlsclient.Config(tlsclient.Policy{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify,
				OptIn:              "mapper.proxmox_apis.insecure_skip_verify",
				Target:             apiConfig.Name,
				Logger:             e.logger,
			}),
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
			// The probe only fingerprints the PVE web UI of an unknown host,
			// which serves a self-signed certificate; it sends no credentials.
			TLSClientConfig: tlsclient.Config(tlsclient.Policy{
				InsecureSkipVerify: true,
				OptIn:              proxmoxCandidateProbeOption,
				Target:             "proxmox candidate probe",
				Logger:             e.logger,
			}),
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

// probeProxmoxCandidatesAfterIdentity fingerprints the seeds and the addresses
// of devices the job found, once identity and enrichment are done.
//
// A candidate carries only the probed address and the node's name. Probed
// before SNMP, a node that answers on several addresses was published once per
// address, and each address became a device of its own. Probed now, a
// candidate at an address the job already holds as a device's IP or alternate
// IP folds onto that device.
func (e *DiscoveryEngine) probeProxmoxCandidatesAfterIdentity(
	ctx context.Context, job *DiscoveryJob, initialSeeds []string) {
	seeds := proxmoxCandidateSeeds(job, initialSeeds)
	if len(seeds) == 0 {
		return
	}

	devices := e.probeProxmoxCandidates(ctx, job, seeds)
	if len(devices) == 0 {
		return
	}

	job.mu.Lock()
	defer job.mu.Unlock()

	e.addProxmoxCandidatesUnlocked(job, devices)
}

// addProxmoxCandidatesUnlocked groups the candidates per node and adds them to
// the job's results. The caller holds job.mu.
func (e *DiscoveryEngine) addProxmoxCandidatesUnlocked(job *DiscoveryJob, devices []*DiscoveredDevice) {
	known := func(ip string) bool {
		existingID, _ := e.resolveExistingDeviceIdentityByIPUnlocked(job, ip)
		return existingID != ""
	}

	for _, device := range groupProxmoxCandidatesByNode(devices, known) {
		e.addOrUpdateDeviceToResults(job, device)
	}
}

// groupProxmoxCandidatesByNode merges candidates that are one node answering at
// several addresses: the same PVE title and the same recorded certificate IP
// SANs. Two nodes that share a name present certificates for different
// addresses, so they stay apart.
//
// The merged candidate's IP is the address the job already resolves to a
// device, so it folds onto that device; otherwise an address the certificate
// lists, or else the lowest, so the same node yields the same device across
// runs. Its other addresses become alternate IPs. A candidate without recorded
// SANs is left as it is.
func groupProxmoxCandidatesByNode(devices []*DiscoveredDevice, known func(ip string) bool) []*DiscoveredDevice {
	groups := make(map[string][]*DiscoveredDevice)
	order := make([]string, 0, len(devices))
	grouped := make([]*DiscoveredDevice, 0, len(devices))

	for _, device := range devices {
		key := proxmoxCandidateNodeKey(device)
		if key == "" {
			grouped = append(grouped, device)
			continue
		}
		if _, ok := groups[key]; !ok {
			order = append(order, key)
		}
		groups[key] = append(groups[key], device)
	}

	for _, key := range order {
		grouped = append(grouped, mergeProxmoxNodeCandidates(groups[key], known))
	}

	return grouped
}

func proxmoxCandidateNodeKey(device *DiscoveredDevice) string {
	if device == nil || device.Metadata["proxmox_tls_sans_recorded"] != stringTrueValue {
		return ""
	}

	title := strings.ToLower(strings.TrimSpace(device.Hostname))
	sans := strings.TrimSpace(device.Metadata["proxmox_tls_san_ips"])
	if title == "" || sans == "" {
		return ""
	}

	return title + "|" + sans
}

func mergeProxmoxNodeCandidates(candidates []*DiscoveredDevice, known func(ip string) bool) *DiscoveredDevice {
	if len(candidates) == 1 {
		return candidates[0]
	}

	listed := make(map[string]struct{})
	for _, ip := range strings.Split(candidates[0].Metadata["proxmox_tls_san_ips"], ",") {
		listed[strings.TrimSpace(ip)] = struct{}{}
	}

	sorted := append([]*DiscoveredDevice(nil), candidates...)
	sort.SliceStable(sorted, func(i, j int) bool {
		iKnown, jKnown := known(sorted[i].IP), known(sorted[j].IP)
		if iKnown != jKnown {
			return iKnown
		}

		_, iListed := listed[sorted[i].IP]
		_, jListed := listed[sorted[j].IP]
		if iListed != jListed {
			return iListed
		}

		return compareIPStrings(sorted[i].IP, sorted[j].IP) < 0
	})

	merged := sorted[0]
	for _, other := range sorted[1:] {
		if other.IP != merged.IP {
			merged.Metadata = addAlternateIP(merged.Metadata, other.IP)
		}
	}

	return merged
}

func compareIPStrings(a, b string) int {
	addrA, errA := netip.ParseAddr(a)
	addrB, errB := netip.ParseAddr(b)
	if errA == nil && errB == nil {
		return addrA.Compare(addrB)
	}

	return strings.Compare(a, b)
}

// proxmoxCandidateSeeds returns the primary IPs of the devices the job found,
// then its seeds, each address once. The probes share one deadline and run in
// turn, so the job's known devices go first: a seed range full of unreachable
// addresses must not use up the budget before them.
func proxmoxCandidateSeeds(job *DiscoveryJob, initialSeeds []string) []string {
	seen := make(map[string]struct{})
	seeds := make([]string, 0, len(initialSeeds))

	add := func(ip string) {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			return
		}
		if _, ok := seen[ip]; ok {
			return
		}
		seen[ip] = struct{}{}
		seeds = append(seeds, ip)
	}

	if job != nil && job.Results != nil {
		for _, device := range job.Results.Devices {
			if device != nil {
				add(device.IP)
			}
		}
	}

	for _, seed := range initialSeeds {
		add(seed)
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

	device := buildProxmoxCandidateDevice(host, nodeName)
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		recordProxmoxCertificateSANs(device, resp.TLS.PeerCertificates[0])
	}

	return device, nil
}

// recordProxmoxCertificateSANs keeps the addresses the node certificate is valid
// for. The agent verifies a Proxmox target's certificate against the exact
// address it dials, so core uses these to avoid targeting an address the
// certificate cannot match. They are recorded, not trusted: the probe skips
// verification, so core only ever chooses among the device's own addresses.
func recordProxmoxCertificateSANs(device *DiscoveredDevice, cert *x509.Certificate) {
	if device == nil || cert == nil {
		return
	}

	ips := make([]string, 0, len(cert.IPAddresses))
	for _, ip := range cert.IPAddresses {
		if len(ips) == proxmoxMaxCertificateSANs {
			break
		}
		ips = append(ips, ip.String())
	}

	names := make([]string, 0, len(cert.DNSNames))
	for _, name := range cert.DNSNames {
		if len(names) == proxmoxMaxCertificateSANs {
			break
		}
		names = append(names, strings.ToLower(strings.TrimSpace(name)))
	}

	// Recorded even when empty: a certificate with no IP SANs can match no IP
	// origin, which is different from a probe that saw no certificate at all.
	device.Metadata["proxmox_tls_sans_recorded"] = stringTrueValue
	device.Metadata["proxmox_tls_san_ips"] = strings.Join(ips, ",")
	device.Metadata["proxmox_tls_san_dns"] = strings.Join(names, ",")
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
