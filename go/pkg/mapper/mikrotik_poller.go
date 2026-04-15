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
	"math"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

var (
	errMikroTikUnsupportedEndpoint = errors.New("mikrotik endpoint unsupported")
	errMikroTikAllAttemptsFailed   = errors.New("all mikrotik API attempts failed")
	errMikroTikGetFailed           = errors.New("mikrotik GET failed")
)

type mikroTikSystemIdentity struct {
	Name string `json:"name"`
}

type mikroTikSystemResource struct {
	Version          string `json:"version"`
	ArchitectureName string `json:"architecture-name"`
	BoardName        string `json:"board-name"`
	Uptime           string `json:"uptime"`
}

type mikroTikRouterboard struct {
	Model        string `json:"model"`
	SerialNumber string `json:"serial-number"`
}

func (e *DiscoveryEngine) createMikroTikClient(apiConfig MikroTikAPIConfig) *http.Client {
	return &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify, //nolint:gosec // operator-controlled discovery setting
			},
		},
	}
}

func (e *DiscoveryEngine) mikrotikAPIsForJob(job *DiscoveryJob) []MikroTikAPIConfig {
	filtered, selectors := selectNamedBaseURLConfigs(
		job,
		e.config.MikroTikAPIs,
		"mikrotik_api_names",
		"mikrotik_api_urls",
		func(api MikroTikAPIConfig) string { return api.Name },
		func(api MikroTikAPIConfig) string { return api.BaseURL },
	)

	if len(filtered) == 0 && selectors != "" {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("job_name", job.Params.Options["mapper_job_name"]).
			Str("selectors", selectors).
			Msg("No MikroTik API matched job selectors")
	}

	return filtered
}

func (e *DiscoveryEngine) queryMikroTikDevices(
	ctx context.Context,
	job *DiscoveryJob,
) ([]*DiscoveredDevice, []*DiscoveredInterface, []*TopologyLink, error) {
	selectedAPIs := e.mikrotikAPIsForJob(job)
	if len(selectedAPIs) == 0 {
		return nil, nil, nil, nil
	}

	allDevices := make([]*DiscoveredDevice, 0, len(selectedAPIs))
	allInterfaces := make([]*DiscoveredInterface, 0, len(selectedAPIs)*4)
	allLinks := make([]*TopologyLink, 0, len(selectedAPIs)*2)
	errorsEncountered := 0

	for _, apiConfig := range selectedAPIs {
		device, interfaces, links, err := e.fetchMikroTikInventory(ctx, apiConfig)
		if err != nil {
			errorsEncountered++
			e.logger.Warn().
				Str("job_id", job.ID).
				Str("api_name", apiConfig.Name).
				Str("base_url", apiConfig.BaseURL).
				Err(err).
				Msg("MikroTik API discovery failed")
			continue
		}

		if device != nil {
			allDevices = append(allDevices, device)
		}
		allInterfaces = append(allInterfaces, interfaces...)
		allLinks = append(allLinks, links...)
	}

	if len(allDevices) == 0 && errorsEncountered == len(selectedAPIs) {
		return nil, nil, nil, fmt.Errorf("%w: attempts=%d", errMikroTikAllAttemptsFailed, errorsEncountered)
	}

	return allDevices, allInterfaces, allLinks, nil
}

func (e *DiscoveryEngine) fetchMikroTikInventory(
	ctx context.Context,
	apiConfig MikroTikAPIConfig,
) (*DiscoveredDevice, []*DiscoveredInterface, []*TopologyLink, error) {
	client := e.createMikroTikClient(apiConfig)

	var (
		identity    mikroTikSystemIdentity
		resource    mikroTikSystemResource
		routerboard mikroTikRouterboard
		interfaces  []map[string]any
		addresses   []map[string]any
		bridgePorts []map[string]any
		bridgeVLANs []map[string]any
		neighbors   []map[string]any
	)

	if err := e.mikrotikGET(ctx, client, apiConfig, "/system/identity", &identity); err != nil {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/system/resource", &resource); err != nil {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/system/routerboard", &routerboard); err != nil &&
		!errors.Is(err, errMikroTikUnsupportedEndpoint) {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/interface", &interfaces); err != nil {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/ip/address", &addresses); err != nil &&
		!errors.Is(err, errMikroTikUnsupportedEndpoint) {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/interface/bridge/port", &bridgePorts); err != nil &&
		!errors.Is(err, errMikroTikUnsupportedEndpoint) {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/interface/bridge/vlan", &bridgeVLANs); err != nil &&
		!errors.Is(err, errMikroTikUnsupportedEndpoint) {
		return nil, nil, nil, err
	}

	if err := e.mikrotikGET(ctx, client, apiConfig, "/ip/neighbor", &neighbors); err != nil &&
		!errors.Is(err, errMikroTikUnsupportedEndpoint) {
		return nil, nil, nil, err
	}

	device, discoveredInterfaces := buildMikroTikInventory(
		apiConfig,
		identity,
		resource,
		routerboard,
		interfaces,
		addresses,
		bridgePorts,
		bridgeVLANs,
	)
	links := buildMikroTikTopologyLinks(device, discoveredInterfaces, neighbors)

	return device, discoveredInterfaces, links, nil
}

func (e *DiscoveryEngine) mikrotikGET(
	ctx context.Context,
	client *http.Client,
	apiConfig MikroTikAPIConfig,
	path string,
	out any,
) error {
	baseURL := strings.TrimRight(strings.TrimSpace(apiConfig.BaseURL), "/")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+path, nil)
	if err != nil {
		return err
	}

	req.SetBasicAuth(apiConfig.Username, apiConfig.Password)
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode == http.StatusNotFound {
		return errMikroTikUnsupportedEndpoint
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		if mikrotikUnsupportedEndpointStatus(resp.StatusCode, body) {
			return errMikroTikUnsupportedEndpoint
		}
		return fmt.Errorf("%w: path=%s status=%d body=%q", errMikroTikGetFailed, path, resp.StatusCode, string(body))
	}

	return json.NewDecoder(resp.Body).Decode(out)
}

func mikrotikUnsupportedEndpointStatus(statusCode int, body []byte) bool {
	if statusCode == http.StatusNotFound {
		return true
	}

	if statusCode != http.StatusBadRequest {
		return false
	}

	text := strings.ToLower(strings.TrimSpace(string(body)))
	return strings.Contains(text, "no such command or directory")
}

func buildMikroTikInventory(
	apiConfig MikroTikAPIConfig,
	identity mikroTikSystemIdentity,
	resource mikroTikSystemResource,
	routerboard mikroTikRouterboard,
	rawInterfaces []map[string]any,
	rawAddresses []map[string]any,
	rawBridgePorts []map[string]any,
	rawBridgeVLANs []map[string]any,
) (*DiscoveredDevice, []*DiscoveredInterface) {
	interfaceIPs := mapMikroTikInterfaceIPs(rawAddresses)
	bridgeMetadata := mapMikroTikBridgePorts(rawBridgePorts)
	vlanMetadata := mapMikroTikBridgeVLANs(rawBridgeVLANs)

	deviceIP := mikrotikDeviceIP(apiConfig.BaseURL, rawAddresses)
	deviceMAC := firstMikroTikMAC(rawInterfaces)
	deviceID := ""
	if deviceMAC != "" {
		deviceID = GenerateDeviceID(deviceMAC)
	}

	metadata := map[string]string{
		"source":      "mikrotik-api",
		"api_name":    apiConfig.Name,
		"api_url":     apiConfig.BaseURL,
		"vendor_name": "MikroTik",
		//nolint:misspell // RouterOS is the vendor product name.
		"routeros_version":  resource.Version,
		"architecture_name": resource.ArchitectureName,
	}

	if model := firstNonEmpty(routerboard.Model, resource.BoardName); model != "" {
		metadata["model"] = model
	}
	if routerboard.SerialNumber != "" {
		metadata["serial_number"] = routerboard.SerialNumber
	}

	device := &DiscoveredDevice{
		DeviceID:     deviceID,
		IP:           deviceIP,
		MAC:          deviceMAC,
		Hostname:     identity.Name,
		SysName:      identity.Name,
		SysDescr:     buildMikroTikSysDescr(resource, routerboard),
		Uptime:       parseMikroTikDurationSeconds(resource.Uptime),
		Metadata:     metadata,
		IPForwarding: 1,
	}

	discoveredInterfaces := make([]*DiscoveredInterface, 0, len(rawInterfaces))
	for idx, raw := range rawInterfaces {
		ifName := stringValue(raw, "name")
		if ifName == "" {
			continue
		}

		ifaceMetadata := map[string]string{
			"source":   "mikrotik-api",
			"api_name": apiConfig.Name,
			//nolint:misspell // RouterOS is the vendor product name.
			"routeros_type": stringValue(raw, "type"),
			"running":       stringValue(raw, "running"),
			"disabled":      stringValue(raw, "disabled"),
		}

		for key, value := range bridgeMetadata[ifName] {
			ifaceMetadata[key] = value
		}
		for key, value := range vlanMetadata[ifName] {
			ifaceMetadata[key] = value
		}

		ifIndex := mikrotikInterfaceIndex(raw, idx)

		discoveredInterfaces = append(discoveredInterfaces, &DiscoveredInterface{
			DeviceIP:      deviceIP,
			DeviceID:      deviceID,
			IfIndex:       ifIndex,
			IfName:        ifName,
			IfDescr:       firstNonEmpty(stringValue(raw, "comment"), ifName),
			IfAlias:       stringValue(raw, "comment"),
			IfSpeed:       0,
			IfPhysAddress: NormalizeMAC(stringValue(raw, "mac-address")),
			IPAddresses:   interfaceIPs[ifName],
			IfAdminStatus: mikrotikAdminStatus(raw),
			IfOperStatus:  mikrotikOperStatus(raw),
			IfType:        mikrotikIfType(stringValue(raw, "type")),
			Metadata:      ifaceMetadata,
		})
	}

	return device, discoveredInterfaces
}

func mikrotikInterfaceIndex(raw map[string]any, fallback int) int32 {
	if raw != nil {
		if id := stringValue(raw, ".id"); id != "" {
			trimmed := strings.TrimPrefix(strings.TrimSpace(id), "*")
			if parsed, err := strconv.ParseInt(trimmed, 10, 32); err == nil && parsed > 0 {
				return int32(parsed)
			}
		}
	}

	if fallback >= math.MaxInt32 {
		return math.MaxInt32
	}

	return int32(fallback + 1)
}

func buildMikroTikTopologyLinks(
	device *DiscoveredDevice,
	interfaces []*DiscoveredInterface,
	rawNeighbors []map[string]any,
) []*TopologyLink {
	if device == nil || len(rawNeighbors) == 0 {
		return nil
	}

	ifIndexByName := make(map[string]int32, len(interfaces))
	for _, iface := range interfaces {
		if iface == nil {
			continue
		}
		ifIndexByName[iface.IfName] = iface.IfIndex
	}

	links := make([]*TopologyLink, 0, len(rawNeighbors))
	for _, raw := range rawNeighbors {
		ifName := firstNonEmpty(stringValue(raw, "interface"), stringValue(raw, "local-interface"))
		link := &TopologyLink{
			Protocol:           "MikroTik-API",
			LocalDeviceIP:      device.IP,
			LocalDeviceID:      device.DeviceID,
			LocalIfIndex:       ifIndexByName[ifName],
			LocalIfName:        ifName,
			NeighborChassisID:  NormalizeMAC(stringValue(raw, "mac-address")),
			NeighborPortID:     stringValue(raw, "interface-name"),
			NeighborPortDescr:  stringValue(raw, "interface-name"),
			NeighborSystemName: firstNonEmpty(stringValue(raw, "identity"), stringValue(raw, "system-name")),
			NeighborMgmtAddr:   stringValue(raw, "address"),
			Metadata: map[string]string{
				"source":          "mikrotik-api-neighbor",
				"evidence_class":  evidenceClassDirectPhysical,
				"relation_family": "CONNECTS_TO",
				//nolint:misspell // RouterOS is the vendor product name.
				"evidence": "routeros-ip-neighbor",
			},
		}

		if strings.TrimSpace(link.LocalIfName) == "" &&
			strings.TrimSpace(link.NeighborMgmtAddr) == "" &&
			strings.TrimSpace(link.NeighborSystemName) == "" &&
			strings.TrimSpace(link.NeighborChassisID) == "" {
			continue
		}

		links = append(links, link)
	}

	return links
}

func mapMikroTikInterfaceIPs(rawAddresses []map[string]any) map[string][]string {
	result := make(map[string][]string)

	for _, raw := range rawAddresses {
		ifName := stringValue(raw, "interface")
		address := stringValue(raw, "address")
		if ifName == "" || address == "" {
			continue
		}

		ip := stripCIDR(address)
		if ip == "" {
			continue
		}

		result[ifName] = append(result[ifName], ip)
	}

	return result
}

func mapMikroTikBridgePorts(rawBridgePorts []map[string]any) map[string]map[string]string {
	result := make(map[string]map[string]string)

	for _, raw := range rawBridgePorts {
		ifName := stringValue(raw, "interface")
		if ifName == "" {
			continue
		}

		entry := result[ifName]
		if entry == nil {
			entry = make(map[string]string)
			result[ifName] = entry
		}

		if bridge := stringValue(raw, "bridge"); bridge != "" {
			entry["bridge_name"] = bridge
		}
		if pvid := stringValue(raw, "pvid"); pvid != "" {
			entry["bridge_pvid"] = pvid
		}
	}

	return result
}

func mapMikroTikBridgeVLANs(rawBridgeVLANs []map[string]any) map[string]map[string]string {
	result := make(map[string]map[string]string)

	for _, raw := range rawBridgeVLANs {
		vlanIDs := stringValue(raw, "vlan-ids")
		for _, field := range []string{"tagged", "untagged"} {
			interfaces := splitCSV(stringValue(raw, field))
			for _, ifName := range interfaces {
				entry := result[ifName]
				if entry == nil {
					entry = make(map[string]string)
					result[ifName] = entry
				}

				entry["bridge_vlan_ids"] = appendCSV(entry["bridge_vlan_ids"], vlanIDs)
				entry["bridge_vlan_membership"] = appendCSV(entry["bridge_vlan_membership"], field)
			}
		}
	}

	return result
}

func mikrotikDeviceIP(baseURL string, rawAddresses []map[string]any) string {
	if ip := hostFromURL(baseURL); ip != "" {
		return ip
	}

	for _, raw := range rawAddresses {
		if ip := stripCIDR(stringValue(raw, "address")); ip != "" {
			return ip
		}
	}

	return ""
}

func firstMikroTikMAC(rawInterfaces []map[string]any) string {
	for _, raw := range rawInterfaces {
		mac := NormalizeMAC(stringValue(raw, "mac-address"))
		if mac != "" && !isAllZeroMAC(mac) {
			return mac
		}
	}

	return ""
}

func isAllZeroMAC(mac string) bool {
	return mac == "000000000000"
}

func buildMikroTikSysDescr(resource mikroTikSystemResource, routerboard mikroTikRouterboard) string {
	model := firstNonEmpty(routerboard.Model, resource.BoardName)
	parts := []string{"MikroTik RouterOS"}
	if model != "" {
		parts = append(parts, model)
	}
	if resource.Version != "" {
		parts = append(parts, resource.Version)
	}

	return strings.Join(parts, " ")
}

func parseMikroTikDurationSeconds(raw string) int64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}

	total := int64(0)
	value := 0

	for _, r := range raw {
		if r >= '0' && r <= '9' {
			value = value*10 + int(r-'0')
			continue
		}

		switch r {
		case 'w':
			total += int64(value) * 7 * 24 * 3600
		case 'd':
			total += int64(value) * 24 * 3600
		case 'h':
			total += int64(value) * 3600
		case 'm':
			total += int64(value) * 60
		case 's':
			total += int64(value)
		default:
			value = 0
			continue
		}

		value = 0
	}

	return total
}

func mikrotikAdminStatus(raw map[string]any) int32 {
	if boolValue(raw, "disabled") {
		return 2
	}

	return 1
}

func mikrotikOperStatus(raw map[string]any) int32 {
	if boolValue(raw, "running") {
		return 1
	}

	return 2
}

func mikrotikIfType(rawType string) int32 {
	switch strings.ToLower(strings.TrimSpace(rawType)) {
	case "ether", "ethernet", "veth", "sfp", "qsfp":
		return 6
	case "wlan", "wifi":
		return 71
	case "bridge":
		return 209
	case "vlan", "bond", "bonding", "eoip", "gre", "vxlan", "wireguard":
		return 53
	default:
		return 1
	}
}

func stringValue(raw map[string]any, key string) string {
	if raw == nil {
		return ""
	}

	value, ok := raw[key]
	if !ok || value == nil {
		return ""
	}

	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case json.Number:
		return typed.String()
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(typed)
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func boolValue(raw map[string]any, key string) bool {
	switch strings.ToLower(stringValue(raw, key)) {
	case stringTrueValue, stringYesValue, "on", "enabled", "running":
		return true
	default:
		return false
	}
}

func stripCIDR(value string) string {
	host := strings.TrimSpace(value)
	if host == "" {
		return ""
	}

	if idx := strings.Index(host, "/"); idx >= 0 {
		host = host[:idx]
	}

	return strings.TrimSpace(host)
}

func hostFromURL(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}

	host := parsed.Hostname()
	if ip := net.ParseIP(host); ip != nil {
		return ip.String()
	}

	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}

	return ""
}

func splitCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		value := strings.TrimSpace(part)
		if value == "" {
			continue
		}
		out = append(out, value)
	}

	return out
}

func appendCSV(existing, value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return existing
	}
	if existing == "" {
		return value
	}

	seen := make(map[string]struct{})
	out := make([]string, 0, 4)
	for _, part := range splitCSV(existing) {
		seen[part] = struct{}{}
		out = append(out, part)
	}
	for _, part := range splitCSV(value) {
		if _, ok := seen[part]; ok {
			continue
		}
		seen[part] = struct{}{}
		out = append(out, part)
	}

	return strings.Join(out, ",")
}
