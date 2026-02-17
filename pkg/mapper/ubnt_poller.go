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
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gosnmp/gosnmp"
)

// UniFiSite represents a site from the UniFi API
type UniFiSite struct {
	ID                string `json:"id"`
	InternalReference string `json:"internalReference"`
	Name              string `json:"name"`
}

// UniFiDevice represents a network device managed by a UniFi controller.
type UniFiDevice struct {
	ID         string          `json:"id"`
	IPAddress  string          `json:"ipAddress"`
	Name       string          `json:"name"`
	MAC        string          `json:"macAddress"`
	Features   []string        `json:"features"`
	Uplink     UniFiUplink     `json:"uplink"`
	Interfaces json.RawMessage `json:"interfaces"` // Use RawMessage to handle varying structures
}

// UniFiUplink captures multiple schema variants for uplink metadata.
type UniFiUplink struct {
	DeviceID      string `json:"deviceId"`
	DeviceIDSnake string `json:"device_id"`
	UpstreamID    string `json:"upstreamDeviceId"`
	UpstreamSnake string `json:"upstream_device_id"`

	LocalPortIdx      int32 `json:"localPortIdx"`
	LocalPortIdxSnake int32 `json:"local_port_idx"`
	PortIdx           int32 `json:"portIdx"`
	PortIdxSnake      int32 `json:"port_idx"`
	ParentPortIdx     int32 `json:"parentPortIdx"`
	ParentPortSnake   int32 `json:"parent_port_idx"`

	LocalPortName      string `json:"localPortName"`
	LocalPortNameSnake string `json:"local_port_name"`
	PortName           string `json:"portName"`
	PortNameSnake      string `json:"port_name"`
	ParentPortName     string `json:"parentPortName"`
	ParentPortNameSnk  string `json:"parent_port_name"`
}

func (u UniFiUplink) upstreamDeviceID() string {
	if u.DeviceID != "" {
		return u.DeviceID
	}
	if u.DeviceIDSnake != "" {
		return u.DeviceIDSnake
	}
	if u.UpstreamID != "" {
		return u.UpstreamID
	}
	return u.UpstreamSnake
}

func (u UniFiUplink) parentPortIndex() int32 {
	switch {
	case u.LocalPortIdx > 0:
		return u.LocalPortIdx
	case u.LocalPortIdxSnake > 0:
		return u.LocalPortIdxSnake
	case u.PortIdx > 0:
		return u.PortIdx
	case u.PortIdxSnake > 0:
		return u.PortIdxSnake
	case u.ParentPortIdx > 0:
		return u.ParentPortIdx
	case u.ParentPortSnake > 0:
		return u.ParentPortSnake
	default:
		return 0
	}
}

func (u UniFiUplink) parentPortName() string {
	switch {
	case strings.TrimSpace(u.LocalPortName) != "":
		return strings.TrimSpace(u.LocalPortName)
	case strings.TrimSpace(u.LocalPortNameSnake) != "":
		return strings.TrimSpace(u.LocalPortNameSnake)
	case strings.TrimSpace(u.PortName) != "":
		return strings.TrimSpace(u.PortName)
	case strings.TrimSpace(u.PortNameSnake) != "":
		return strings.TrimSpace(u.PortNameSnake)
	case strings.TrimSpace(u.ParentPortName) != "":
		return strings.TrimSpace(u.ParentPortName)
	case strings.TrimSpace(u.ParentPortNameSnk) != "":
		return strings.TrimSpace(u.ParentPortNameSnk)
	default:
		return ""
	}
}

// UniFiInterfaces represents the interfaces object for devices with ports
type UniFiInterfaces struct {
	Ports []struct {
		Idx          int    `json:"idx"`
		State        string `json:"state"`
		Connector    string `json:"connector"`
		MaxSpeedMbps int    `json:"maxSpeedMbps"`
		SpeedMbps    int    `json:"speedMbps"`
		PoE          struct {
			Standard string `json:"standard"`
			Type     int    `json:"type"`
			Enabled  bool   `json:"enabled"`
			State    string `json:"state"`
		} `json:"poe,omitempty"`
	} `json:"ports"`
}

// UniFiDeviceDetails represents detailed device information
type UniFiDeviceDetails struct {
	LLDPTable      []UniFiLLDPEntry `json:"lldp_table"`
	LLDPTableCamel []UniFiLLDPEntry `json:"lldpTable"`

	PortTable      []UniFiPortEntry `json:"port_table"`
	PortTableCamel []UniFiPortEntry `json:"portTable"`

	Uplink UniFiUplink `json:"uplink"`
}

type UniFiLLDPEntry struct {
	LocalPortIdx        int32  `json:"local_port_idx"`
	LocalPortIdxCamel   int32  `json:"localPortIdx"`
	LocalPortName       string `json:"local_port_name"`
	LocalPortNameCamel  string `json:"localPortName"`
	ChassisID           string `json:"chassis_id"`
	ChassisIDCamel      string `json:"chassisId"`
	PortID              string `json:"port_id"`
	PortIDCamel         string `json:"portId"`
	PortDescription     string `json:"port_description"`
	PortDescrCamel      string `json:"portDescription"`
	SystemName          string `json:"system_name"`
	SystemNameCamel     string `json:"systemName"`
	ManagementAddr      string `json:"management_address"`
	ManagementAddrCamel string `json:"managementAddr"`
}

type UniFiPortEntry struct {
	PortIdx        int32                  `json:"port_idx"`
	PortIdxCamel   int32                  `json:"portIdx"`
	Name           string                 `json:"name"`
	Connected      UniFiPortConnectedPeer `json:"connected_device"`
	ConnectedCamel UniFiPortConnectedPeer `json:"connectedDevice"`
}

type UniFiPortConnectedPeer struct {
	MAC      string `json:"mac"`
	MACCamel string `json:"macAddress"`
	Name     string `json:"name"`
	IP       string `json:"ip"`
	IPCamel  string `json:"ipAddress"`

	DeviceID      string `json:"deviceId"`
	DeviceIDSnake string `json:"device_id"`
	RemoteID      string `json:"remoteDeviceId"`
	RemoteIDSnake string `json:"remote_device_id"`
	ID            string `json:"id"`
}

func (d *UniFiDeviceDetails) normalizedLLDPTable() []UniFiLLDPEntry {
	if len(d.LLDPTableCamel) > 0 {
		return d.LLDPTableCamel
	}

	return d.LLDPTable
}

func (d *UniFiDeviceDetails) normalizedPortTable() []UniFiPortEntry {
	if len(d.PortTableCamel) > 0 {
		return d.PortTableCamel
	}

	return d.PortTable
}

func (e UniFiLLDPEntry) ifIndex() int32 {
	if e.LocalPortIdxCamel > 0 {
		return e.LocalPortIdxCamel
	}

	return e.LocalPortIdx
}

func (e UniFiLLDPEntry) ifName() string {
	if strings.TrimSpace(e.LocalPortNameCamel) != "" {
		return strings.TrimSpace(e.LocalPortNameCamel)
	}

	return strings.TrimSpace(e.LocalPortName)
}

func (e UniFiLLDPEntry) chassisID() string {
	if strings.TrimSpace(e.ChassisIDCamel) != "" {
		return strings.TrimSpace(e.ChassisIDCamel)
	}

	return strings.TrimSpace(e.ChassisID)
}

func (e UniFiLLDPEntry) portID() string {
	if strings.TrimSpace(e.PortIDCamel) != "" {
		return strings.TrimSpace(e.PortIDCamel)
	}

	return strings.TrimSpace(e.PortID)
}

func (e UniFiLLDPEntry) portDescr() string {
	if strings.TrimSpace(e.PortDescrCamel) != "" {
		return strings.TrimSpace(e.PortDescrCamel)
	}

	return strings.TrimSpace(e.PortDescription)
}

func (e UniFiLLDPEntry) systemName() string {
	if strings.TrimSpace(e.SystemNameCamel) != "" {
		return strings.TrimSpace(e.SystemNameCamel)
	}

	return strings.TrimSpace(e.SystemName)
}

func (e UniFiLLDPEntry) mgmtAddr() string {
	if strings.TrimSpace(e.ManagementAddrCamel) != "" {
		return strings.TrimSpace(e.ManagementAddrCamel)
	}

	return strings.TrimSpace(e.ManagementAddr)
}

func (e UniFiPortEntry) ifIndex() int32 {
	if e.PortIdxCamel > 0 {
		return e.PortIdxCamel
	}

	return e.PortIdx
}

func (e UniFiPortEntry) connected() UniFiPortConnectedPeer {
	if strings.TrimSpace(e.ConnectedCamel.MAC) != "" ||
		strings.TrimSpace(e.ConnectedCamel.MACCamel) != "" ||
		strings.TrimSpace(e.ConnectedCamel.IP) != "" ||
		strings.TrimSpace(e.ConnectedCamel.IPCamel) != "" {
		return e.ConnectedCamel
	}

	return e.Connected
}

func (p UniFiPortConnectedPeer) mac() string {
	if strings.TrimSpace(p.MACCamel) != "" {
		return strings.TrimSpace(p.MACCamel)
	}

	return strings.TrimSpace(p.MAC)
}

func (p UniFiPortConnectedPeer) ip() string {
	if strings.TrimSpace(p.IPCamel) != "" {
		return strings.TrimSpace(p.IPCamel)
	}

	return strings.TrimSpace(p.IP)
}

func (p UniFiPortConnectedPeer) deviceID() string {
	switch {
	case strings.TrimSpace(p.DeviceID) != "":
		return strings.TrimSpace(p.DeviceID)
	case strings.TrimSpace(p.DeviceIDSnake) != "":
		return strings.TrimSpace(p.DeviceIDSnake)
	case strings.TrimSpace(p.RemoteID) != "":
		return strings.TrimSpace(p.RemoteID)
	case strings.TrimSpace(p.RemoteIDSnake) != "":
		return strings.TrimSpace(p.RemoteIDSnake)
	default:
		return strings.TrimSpace(p.ID)
	}
}

// createUniFiClient initializes an HTTP client for UniFi API calls with configured timeout and TLS settings.
func (e *DiscoveryEngine) createUniFiClient(apiConfig UniFiAPIConfig) *http.Client {
	return &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify, //nolint:gosec // G402: Allow insecure connections to Ubiquti devices
			},
		},
	}
}

func (e *DiscoveryEngine) fetchUniFiSites(ctx context.Context, job *DiscoveryJob, apiConfig UniFiAPIConfig) ([]UniFiSite, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Msg("Fetching sites for UniFi API")

	// Check cache
	job.mu.RLock()

	if sites, exists := job.uniFiSiteCache[apiConfig.BaseURL]; exists {
		job.mu.RUnlock()
		e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Msg("Using cached sites")

		return sites, nil
	}

	job.mu.RUnlock()

	client := e.createUniFiClient(apiConfig)

	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	sitesURL := fmt.Sprintf("%s/sites", apiConfig.BaseURL)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, sitesURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create sites request for %s: %w", apiConfig.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch sites from %s: %w", apiConfig.Name, err)
	}
	defer func() {
		_ = resp.Body.Close() // Ignore close error in defer
	}()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w for %s with status: %d", ErrUniFiSitesRequestFailed, apiConfig.Name, resp.StatusCode)
	}

	var sitesResp struct {
		Data []UniFiSite `json:"data"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&sitesResp); err != nil {
		return nil, fmt.Errorf("failed to parse sites response from %s: %w", apiConfig.Name, err)
	}

	if len(sitesResp.Data) == 0 {
		return nil, fmt.Errorf("%w for %s", ErrNoUniFiSitesFound, apiConfig.Name)
	}

	// Cache sites
	job.mu.Lock()

	if job.uniFiSiteCache == nil {
		job.uniFiSiteCache = make(map[string][]UniFiSite)
	}

	job.uniFiSiteCache[apiConfig.BaseURL] = sitesResp.Data
	job.mu.Unlock()

	return sitesResp.Data, nil
}

func (e *DiscoveryEngine) queryUniFiAPI(
	ctx context.Context, job *DiscoveryJob, targetIP string) ([]*TopologyLink, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Msg("Querying UniFi APIs")

	var allLinks []*TopologyLink

	seenLinks := make(map[string]struct{})
	selectedAPIs := e.unifiAPIsForJob(job)

	for _, apiConfig := range selectedAPIs {
		if apiConfig.BaseURL == "" || apiConfig.APIKey == "" {
			e.logger.Warn().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
				Msg("Skipping incomplete UniFi API config")

			continue
		}

		sites, err := e.fetchUniFiSites(ctx, job, apiConfig)
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Err(err).
				Msg("Failed to fetch sites")

			continue
		}

		for _, site := range sites {
			links, err := e.querySingleUniFiAPI(ctx, job, targetIP, apiConfig, site)
			if err != nil {
				e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
					Str("site_name", site.Name).Err(err).Msg("Failed to query UniFi API")

				continue
			}

			for _, link := range links {
				linkKey := uniFiLinkDedupKey(link, site.ID)
				if _, exists := seenLinks[linkKey]; !exists {
					seenLinks[linkKey] = struct{}{}

					allLinks = append(allLinks, link)
				}
			}
		}
	}

	if len(allLinks) == 0 {
		return nil, ErrNoUniFiNeighborsFound
	}

	return allLinks, nil
}

var (
	// ErrNoUniFiNeighborsFound indicates that no neighboring devices were found during UniFi discovery.
	ErrNoUniFiNeighborsFound = errors.New("no UniFi neighbors found")
)

// fetchUniFiDevicesForSite fetches devices from a UniFi site and creates a device cache
func (e *DiscoveryEngine) fetchUniFiDevicesForSite(
	ctx context.Context,
	job *DiscoveryJob,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]UniFiDevice, map[string]struct {
	IP       string
	Name     string
	MAC      string
	DeviceID string
}, error) {
	devicesURL := fmt.Sprintf("%s/sites/%s/devices?limit=500", apiConfig.BaseURL, site.ID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, devicesURL, http.NoBody)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create devices request for %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to fetch devices from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("%w for %s, site %s with status: %d",
			ErrUniFiDevicesRequestFailed, apiConfig.Name, site.Name, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to read devices response body from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).Str("response", string(body)).
		Msg("Devices response from UniFi API")

	var deviceResp struct {
		Data []UniFiDevice `json:"data"`
	}

	if err := json.Unmarshal(body, &deviceResp); err != nil {
		return nil, nil, fmt.Errorf("failed to parse devices response from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	deviceCache := make(map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	})

	for i := range deviceResp.Data {
		device := &deviceResp.Data[i]

		deviceID := GenerateDeviceID(device.MAC)
		if deviceID == "" {
			deviceID = GenerateDeviceIDFromIP(device.IPAddress)
		}

		deviceCache[device.ID] = struct {
			IP       string
			Name     string
			MAC      string
			DeviceID string
		}{device.IPAddress, device.Name, device.MAC, deviceID}
	}

	return deviceResp.Data, deviceCache, nil
}

// fetchDeviceDetails fetches detailed information for a specific device
func (e *DiscoveryEngine) fetchDeviceDetails(
	ctx context.Context,
	job *DiscoveryJob,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite,
	deviceID string) (*UniFiDeviceDetails, error) {
	detailsURL := fmt.Sprintf("%s/sites/%s/devices/%s", apiConfig.BaseURL, site.ID, deviceID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, detailsURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create details request for device %s: %w",
			deviceID, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch details for device %s: %w", deviceID, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w for device %s with status: %d",
			ErrUniFiDeviceDetailsFailed, deviceID, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read details for device %s: %w", deviceID, err)
	}

	var details UniFiDeviceDetails
	if err := json.Unmarshal(body, &details); err == nil {
		if len(details.normalizedLLDPTable()) > 0 || len(details.normalizedPortTable()) > 0 ||
			details.Uplink.upstreamDeviceID() != "" {
			return &details, nil
		}
	}

	var wrapped struct {
		Data   UniFiDeviceDetails `json:"data"`
		Device UniFiDeviceDetails `json:"device"`
	}
	if err := json.Unmarshal(body, &wrapped); err == nil {
		if len(wrapped.Data.normalizedLLDPTable()) > 0 || len(wrapped.Data.normalizedPortTable()) > 0 ||
			wrapped.Data.Uplink.upstreamDeviceID() != "" {
			return &wrapped.Data, nil
		}
		if len(wrapped.Device.normalizedLLDPTable()) > 0 || len(wrapped.Device.normalizedPortTable()) > 0 ||
			wrapped.Device.Uplink.upstreamDeviceID() != "" {
			return &wrapped.Device, nil
		}
	}

	topKeys := extractTopLevelJSONKeys(body)
	preview := string(body)
	if len(preview) > 1500 {
		preview = preview[:1500]
	}
	e.logger.Warn().
		Str("job_id", job.ID).
		Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).
		Str("device_id", deviceID).
		Int("payload_bytes", len(body)).
		Strs("top_level_keys", topKeys).
		Str("payload_preview", preview).
		Msg("UniFi detail payload parsed but yielded no topology fields")

	return &UniFiDeviceDetails{}, nil
}

func extractTopLevelJSONKeys(body []byte) []string {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(body, &m); err != nil {
		return nil
	}

	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// processLLDPTable processes LLDP table entries and creates topology links
func (*DiscoveryEngine) processLLDPTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	lldpEntries := details.normalizedLLDPTable()
	links := make([]*TopologyLink, 0, len(lldpEntries))

	for i := range lldpEntries {
		entry := &lldpEntries[i]
		link := &TopologyLink{
			Protocol:           "LLDP",
			LocalDeviceIP:      device.IPAddress,
			LocalDeviceID:      deviceID,
			LocalIfIndex:       entry.ifIndex(),
			LocalIfName:        entry.ifName(),
			NeighborChassisID:  entry.chassisID(),
			NeighborPortID:     entry.portID(),
			NeighborPortDescr:  entry.portDescr(),
			NeighborSystemName: entry.systemName(),
			NeighborMgmtAddr:   entry.mgmtAddr(),
			Metadata: map[string]string{
				"discovery_id":    job.ID,
				"discovery_time":  time.Now().Format(time.RFC3339),
				"source":          "unifi-api-lldp",
				"evidence_class":  "direct",
				"controller_url":  apiConfig.BaseURL,
				"site_id":         site.ID,
				"site_name":       site.Name,
				"controller_name": apiConfig.Name,
			},
		}

		links = append(links, link)
	}

	return links
}

// processPortTable processes port table entries and creates topology links
func (*DiscoveryEngine) processPortTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	portEntries := details.normalizedPortTable()
	for i := range portEntries {
		port := &portEntries[i]
		peer := port.connected()
		peerMAC := peer.mac()
		peerIP := peer.ip()
		peerName := peer.Name
		peerDeviceID := peer.deviceID()
		if peerDeviceID != "" && (peerMAC == "" || peerIP == "" || strings.TrimSpace(peerName) == "") {
			if cached, exists := deviceCache[peerDeviceID]; exists {
				if peerMAC == "" {
					peerMAC = cached.MAC
				}
				if peerIP == "" {
					peerIP = cached.IP
				}
				if strings.TrimSpace(peerName) == "" {
					peerName = cached.Name
				}
			}
		}

		if peerMAC != "" || peerIP != "" {
			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      device.IPAddress,
				LocalDeviceID:      deviceID,
				LocalIfIndex:       port.ifIndex(),
				LocalIfName:        port.Name,
				NeighborChassisID:  peerMAC,
				NeighborSystemName: peerName,
				NeighborMgmtAddr:   peerIP,
				Metadata: map[string]string{
					"discovery_id":    job.ID,
					"discovery_time":  time.Now().Format(time.RFC3339),
					"source":          "unifi-api-port-table",
					"evidence_class":  "endpoint-attachment",
					"controller_url":  apiConfig.BaseURL,
					"site_id":         site.ID,
					"site_name":       site.Name,
					"controller_name": apiConfig.Name,
					"neighbor_id":     peerDeviceID,
				},
			}

			links = append(links, link)
		}
	}

	return links
}

// processUplinkInfo processes uplink information and creates topology links
func (*DiscoveryEngine) processUplinkInfo(
	job *DiscoveryJob,
	device *UniFiDevice,
	details *UniFiDeviceDetails,
	deviceCache map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	uplinkInfo := device.Uplink
	if uplinkInfo.upstreamDeviceID() == "" && details != nil {
		uplinkInfo = details.Uplink
	}

	if uplinkID := uplinkInfo.upstreamDeviceID(); uplinkID != "" {
		if uplink, exists := deviceCache[uplinkID]; exists {
			localIfIndex := uplinkInfo.parentPortIndex()
			localIfName := uplinkInfo.parentPortName()
			if localIfName == "" && localIfIndex > 0 {
				localIfName = fmt.Sprintf("Port %d", localIfIndex)
			}

			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      uplink.IP,
				LocalDeviceID:      uplink.DeviceID,
				LocalIfIndex:       localIfIndex,
				LocalIfName:        localIfName,
				NeighborChassisID:  device.MAC,
				NeighborSystemName: device.Name,
				NeighborMgmtAddr:   device.IPAddress,
				Metadata: map[string]string{
					"discovery_id":       job.ID,
					"discovery_time":     time.Now().Format(time.RFC3339),
					"source":             "unifi-api-uplink",
					"evidence_class":     "direct",
					"controller_url":     apiConfig.BaseURL,
					"site_id":            site.ID,
					"site_name":          site.Name,
					"controller_name":    apiConfig.Name,
					"uplink_device_id":   uplinkID,
					"uplink_device_name": uplink.Name,
				},
			}
			links = append(links, link)
		}
	}

	return links
}

func (e *DiscoveryEngine) querySingleUniFiAPI(
	ctx context.Context,
	job *DiscoveryJob,
	targetIP string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]*TopologyLink, error) {
	client := e.createUniFiClient(apiConfig)
	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	// Fetch devices and create device cache
	devices, deviceCache, err :=
		e.fetchUniFiDevicesForSite(ctx, job, client, headers, apiConfig, site)
	if err != nil {
		return nil, err
	}

	var links []*TopologyLink
	lldpCount := 0
	portCount := 0
	uplinkCount := 0
	if targetIP != "" {
		e.logger.Debug().
			Str("job_id", job.ID).
			Str("target_ip", targetIP).
			Str("api_name", apiConfig.Name).
			Str("site_name", site.Name).
			Msg("Building UniFi topology from full site inventory")
	}

	// Process each device
	for i := range devices {
		device := &devices[i]

		deviceID := GenerateDeviceID(device.MAC)
		if deviceID == "" {
			deviceID = GenerateDeviceIDFromIP(device.IPAddress)
		}

		// Fetch device details
		details, err := e.fetchDeviceDetails(ctx, job, client, headers, apiConfig, site, device.ID)
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Err(err).Msg("UniFi device processing error")
			continue
		}

		// Process LLDP table
		lldpLinks := e.processLLDPTable(job, device, deviceID, details, apiConfig, site)
		links = append(links, lldpLinks...)
		lldpCount += len(lldpLinks)

		// Process port table
		portLinks := e.processPortTable(job, device, deviceID, details, deviceCache, apiConfig, site)
		links = append(links, portLinks...)
		portCount += len(portLinks)

		// Process uplink information
		uplinkLinks := e.processUplinkInfo(job, device, details, deviceCache, apiConfig, site)
		links = append(links, uplinkLinks...)
		uplinkCount += len(uplinkLinks)
	}

	e.logger.Info().
		Str("job_id", job.ID).
		Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).
		Int("devices", len(devices)).
		Int("lldp_links", lldpCount).
		Int("port_links", portCount).
		Int("uplink_links", uplinkCount).
		Int("total_links", len(links)).
		Msg("UniFi topology extraction summary")

	return links, nil
}

func (e *DiscoveryEngine) queryUniFiDevices(
	ctx context.Context,
	job *DiscoveryJob,
	targetIP string,
) ([]*DiscoveredDevice, []*DiscoveredInterface, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("target_ip", targetIP).Msg("Querying UniFi devices")

	var allDevices []*DiscoveredDevice

	var allInterfaces []*DiscoveredInterface

	seenMACs := make(map[string]string) // MAC -> primary IP
	errorsEncountered := 0
	selectedAPIs := e.unifiAPIsForJob(job)

	for _, apiConfig := range selectedAPIs {
		if apiConfig.BaseURL == "" || apiConfig.APIKey == "" {
			e.logger.Warn().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
				Msg("Skipping incomplete UniFi API config")

			continue
		}

		sites, err := e.fetchUniFiSites(job.ctx, job, apiConfig)
		if err != nil {
			e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).Err(err).
				Msg("Failed to fetch sites")

			errorsEncountered++

			continue
		}

		for _, site := range sites {
			devices, interfaces, err := e.querySingleUniFiDevices(ctx, job, targetIP, apiConfig, site)
			if err != nil {
				e.logger.Error().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
					Str("site_name", site.Name).Err(err).Msg("Failed to query UniFi devices")

				errorsEncountered++

				continue
			}

			for _, device := range devices {
				if device.IP == "" {
					continue
				}

				if primaryIP, seen := seenMACs[device.MAC]; seen {
					e.logger.Debug().Str("job_id", job.ID).Str("mac", device.MAC).
						Str("primary_ip", primaryIP).Str("skipped_ip", device.IP).
						Msg("Device with MAC already seen, skipping IP")

					device.Metadata = addAlternateIP(device.Metadata, device.IP)

					continue
				}

				seenMACs[device.MAC] = device.IP
				allDevices = append(allDevices, device)
			}

			allInterfaces = append(allInterfaces, interfaces...)

			e.logger.Debug().Str("job_id", job.ID).Int("devices_count", len(devices)).
				Int("interfaces_count", len(interfaces)).Str("api_name", apiConfig.Name).
				Str("site_name", site.Name).Msg("Fetched devices and interfaces")
		}
	}

	if len(allDevices) == 0 {
		if len(selectedAPIs) > 0 && errorsEncountered == len(selectedAPIs) {
			return nil, nil, fmt.Errorf("%w: all %d API attempts failed", ErrNoUniFiDevicesFound, errorsEncountered)
		}

		e.logger.Info().Str("job_id", job.ID).Str("target_ip", targetIP).
			Msg("No UniFi devices found, but some APIs succeeded")
	}

	return allDevices, allInterfaces, nil
}

func (e *DiscoveryEngine) unifiAPIsForJob(job *DiscoveryJob) []UniFiAPIConfig {
	all := e.config.UniFiAPIs
	if len(all) == 0 || job == nil || job.Params == nil {
		return all
	}

	opts := job.Params.Options
	if len(opts) == 0 {
		return all
	}

	allowedNames := parseCSVSet(opts["unifi_api_names"], true)
	allowedURLs := parseCSVSet(opts["unifi_api_urls"], false)

	// Backward compatibility: older configs won't have scoped selectors.
	if len(allowedNames) == 0 && len(allowedURLs) == 0 {
		return all
	}

	filtered := make([]UniFiAPIConfig, 0, len(all))
	for _, api := range all {
		nameKey := strings.ToLower(strings.TrimSpace(api.Name))
		urlKey := normalizeURLKey(api.BaseURL)

		if allowedNames[nameKey] || allowedURLs[urlKey] {
			filtered = append(filtered, api)
		}
	}

	if len(filtered) == 0 {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("job_name", opts["mapper_job_name"]).
			Str("selectors", opts["unifi_api_names"]+"|"+opts["unifi_api_urls"]).
			Msg("No UniFi API matched job selectors")
	}

	return filtered
}

func parseCSVSet(raw string, lower bool) map[string]bool {
	result := make(map[string]bool)

	for _, part := range strings.Split(raw, ",") {
		v := strings.TrimSpace(part)
		if v == "" {
			continue
		}

		if lower {
			v = strings.ToLower(v)
		}

		result[v] = true
	}

	return result
}

func normalizeURLKey(raw string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), "/")
}

func uniFiLinkDedupKey(link *TopologyLink, siteID string) string {
	if link == nil {
		return siteID + ":nil"
	}

	return fmt.Sprintf(
		"%s:%s:%s:%d:%s:%s:%s:%s:%s",
		siteID,
		link.Protocol,
		link.LocalDeviceID,
		link.LocalIfIndex,
		link.LocalIfName,
		link.LocalDeviceIP,
		link.NeighborMgmtAddr,
		NormalizeMAC(link.NeighborChassisID),
		link.NeighborPortID,
	)
}

func (e *DiscoveryEngine) fetchUniFiDevices(
	ctx context.Context,
	job *DiscoveryJob,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]*UniFiDevice, error) {
	client := e.createUniFiClient(apiConfig)
	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	// Consider pagination if many devices per site: ?limit=X&offset=Y
	devicesURL := fmt.Sprintf("%s/sites/%s/devices?limit=100", apiConfig.BaseURL, site.ID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, devicesURL, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("failed to create devices request for %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch devices from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body) // Read body for error context

		return nil, fmt.Errorf("%w for %s, site %s with status: %d, body: %s",
			ErrUniFiDevicesRequestFailed, apiConfig.Name, site.Name, resp.StatusCode, string(bodyBytes))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read devices response body from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).Str("response_preview", fmt.Sprintf("%.500s", string(body))).
		Msg("Devices response from UniFi API (first 500 chars)")

	var deviceResp struct {
		Data []*UniFiDevice `json:"data"`
	}

	if err := json.Unmarshal(body, &deviceResp); err != nil {
		return nil, fmt.Errorf("failed to parse devices response from %s, site %s: %w. Body: %s",
			apiConfig.Name, site.Name, err, string(body))
	}

	return deviceResp.Data, nil
}

func (e *DiscoveryEngine) createDiscoveredDevice(
	job *DiscoveryJob,
	device *UniFiDevice,
	apiConfig UniFiAPIConfig,
	site UniFiSite) *DiscoveredDevice {
	if device.IPAddress == "" {
		e.logger.Debug().Str("job_id", job.ID).Str("device_name", device.Name).
			Str("device_id", device.ID).Str("mac", device.MAC).
			Msg("UniFi device has no IP address, skipping")

		return nil
	}

	// Generate standardized device ID
	deviceID := GenerateDeviceID(device.MAC)
	if deviceID == "" {
		deviceID = GenerateDeviceIDFromIP(device.IPAddress)
	}

	return &DiscoveredDevice{
		DeviceID: deviceID,
		IP:       device.IPAddress,
		MAC:      device.MAC,
		Hostname: device.Name,
		Metadata: map[string]string{
			"source":          "unifi-api",
			"controller_url":  apiConfig.BaseURL,
			"site_id":         site.ID,
			"site_name":       site.Name,
			"controller_name": apiConfig.Name,
			// "unifi_model":     device.Model,
			"unifi_device_id": device.ID, // Store the UniFi internal device ID
		},
	}
}

func (e *DiscoveryEngine) processDeviceInterfaces(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	apiConfig UniFiAPIConfig,
	site UniFiSite,
) []*DiscoveredInterface {
	if device.Interfaces == nil {
		return nil
	}

	var interfaces []*DiscoveredInterface

	var uniFiSwitchInterfaces UniFiInterfaces

	if err := json.Unmarshal(device.Interfaces, &uniFiSwitchInterfaces); err != nil {
		rawInterfacesStr := string(device.Interfaces)

		if rawInterfacesStr == `["ports"]` || rawInterfacesStr == `[]` || rawInterfacesStr == `["radios"]` {
			e.logger.Debug().Str("job_id", job.ID).Str("device_name", device.Name).
				Str("device_id", device.ID).Str("interfaces_field", rawInterfacesStr).
				Msg("Device has interfaces field, skipping interface discovery")

			return nil
		}

		e.logger.Warn().Str("job_id", job.ID).Str("device_name", device.Name).
			Str("device_id", device.ID).Str("interfaces_structure", rawInterfacesStr).
			Err(err).Msg("Device has non-standard UniFi interfaces structure")

		return nil
	}

	if len(uniFiSwitchInterfaces.Ports) > 0 {
		interfaces = e.processSwitchInterfaces(job, device, deviceID, uniFiSwitchInterfaces, apiConfig, site)
	}

	return interfaces
}

const (
	defaultMaxValueInt32 = 0x7FFFFFFF // Max value for int32
)

func (e *DiscoveryEngine) processSwitchInterfaces(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	switchInterfaces UniFiInterfaces,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*DiscoveredInterface {
	interfaces := make([]*DiscoveredInterface, 0, len(switchInterfaces.Ports))
	// Ensure we have a proper device ID
	if deviceID == "" {
		deviceID = GenerateDeviceID(device.MAC)
	}
	if deviceID == "" {
		deviceID = GenerateDeviceIDFromIP(device.IPAddress)
	}

	for i := range switchInterfaces.Ports {
		port := &switchInterfaces.Ports[i]

		adminStatus := 1 // Up by default
		operStatus := 1  // Up by default

		if strings.EqualFold(port.State, "down") || strings.EqualFold(port.State, "disabled") {
			adminStatus = 2 // Down
			operStatus = 2  // Down
		}

		// Correctly derive IfName and IfDescr
		ifName := fmt.Sprintf("Port-%d", port.Idx)
		ifDescr := fmt.Sprintf("%s Port %d", device.Name, port.Idx)

		if port.Connector != "" { // Add connector type if available
			ifDescr = fmt.Sprintf("%s Port %d (%s)", device.Name, port.Idx, port.Connector)
		}

		metadata := map[string]string{
			"source":          "unifi-api",
			"controller_url":  apiConfig.BaseURL,
			"site_id":         site.ID,
			"site_name":       site.Name,
			"controller_name": apiConfig.Name,
			"connector":       port.Connector,
			"port_state":      port.State,
			"max_speed_mbps":  fmt.Sprintf("%d", port.MaxSpeedMbps),
		}

		e.addPoEMetadata(metadata, port)

		// Safe conversion to prevent integer overflow
		var ifIndex int32

		if port.Idx <= defaultMaxValueInt32 { // Max value for int32
			//nolint:gosec // G115: This is a safe conversion since we check the value
			ifIndex = int32(port.Idx)
		} else {
			ifIndex = defaultMaxValueInt32 // Use max int32 value if overflow would occur
		}

		// Safe conversion for speed calculation
		var ifSpeed uint64

		if port.SpeedMbps >= 0 && port.SpeedMbps <= (1<<64-1)/1000000 { // Check if multiplication won't overflow uint64
			ifSpeed = uint64(port.SpeedMbps) * 1000000 // Convert to uint64 first, then multiply
		} else {
			ifSpeed = 0xFFFFFFFFFFFFFFFF // Use max uint64 value if overflow would occur
		}

		// Direct conversion for admin status
		var ifAdminStatus = int32(adminStatus) //nolint:gosec // G115: This is a safe conversion since adminStatus is 1 or 2

		iface := &DiscoveredInterface{
			DeviceIP:      device.IPAddress,
			DeviceID:      deviceID,
			IfIndex:       ifIndex,
			IfName:        ifName,
			IfDescr:       ifDescr,
			IfSpeed:       ifSpeed,
			IfAdminStatus: ifAdminStatus,
			IfOperStatus:  int32(operStatus), //nolint:gosec // G115: This is a safe conversion since operStatus is 1 or 2
			Metadata:      metadata,
		}

		interfaces = append(interfaces, iface)
	}

	return interfaces
}

func (*DiscoveryEngine) addPoEMetadata(metadata map[string]string, port *struct {
	Idx          int    `json:"idx"`
	State        string `json:"state"`
	Connector    string `json:"connector"`
	MaxSpeedMbps int    `json:"maxSpeedMbps"`
	SpeedMbps    int    `json:"speedMbps"`
	PoE          struct {
		Standard string `json:"standard"`
		Type     int    `json:"type"`
		Enabled  bool   `json:"enabled"`
		State    string `json:"state"`
	} `json:"poe,omitempty"`
}) {
	if port.PoE.Enabled || port.PoE.Standard != "" {
		metadata["poe_standard"] = port.PoE.Standard
		metadata["poe_type"] = fmt.Sprintf("%d", port.PoE.Type)
		metadata["poe_state"] = port.PoE.State
		metadata["poe_enabled"] = "true"
	}
}

func (e *DiscoveryEngine) querySingleUniFiDevices(
	ctx context.Context,
	job *DiscoveryJob,
	targetIP string, // Contextual IP, not used for filtering devices from controller here
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]*DiscoveredDevice, []*DiscoveredInterface, error) {
	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).Str("context", targetIP).Msg("Querying UniFi devices")

	unifiDevices, err := e.fetchUniFiDevices(ctx, job, apiConfig, site)
	if err != nil {
		return nil, nil, err
	}

	devices := make([]*DiscoveredDevice, 0, len(unifiDevices))

	// Pre-allocate allInterfaces with a reasonable estimate (at least one interface per device)
	allInterfaces := make([]*DiscoveredInterface, 0, len(unifiDevices))

	// Process each device
	for i := range unifiDevices {
		// Create discovered device
		device := e.createDiscoveredDevice(job, unifiDevices[i], apiConfig, site)

		if device == nil {
			continue // Skip this device if it was filtered out
		}

		devices = append(devices, device)

		// Process device interfaces
		interfaces := e.processDeviceInterfaces(job, unifiDevices[i], device.DeviceID, apiConfig, site)

		allInterfaces = append(allInterfaces, interfaces...)
	}

	return devices, allInterfaces, nil
}

func (e *DiscoveryEngine) querySysInfoWithTimeout(
	client *gosnmp.GoSNMP, job *DiscoveryJob, target string, timeout time.Duration) (*DiscoveredDevice, error) {
	done := make(chan struct {
		device *DiscoveredDevice
		err    error
	}, 1)

	go func() {
		device, err := e.querySysInfo(client, target, job)

		done <- struct {
			device *DiscoveredDevice
			err    error
		}{device, err}
	}()

	select {
	case result := <-done:
		return result.device, result.err
	case <-time.After(timeout):
		return nil, fmt.Errorf("%w for %s", ErrSNMPQueryTimeout, target)
	}
}
