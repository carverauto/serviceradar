package mapper

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// UniFiSite represents a site from the UniFi API
type UniFiSite struct {
	ID                string `json:"id"`
	InternalReference string `json:"internalReference"`
	Name              string `json:"name"`
}

type UniFiDevice struct {
	ID        string   `json:"id"`
	IPAddress string   `json:"ipAddress"`
	Name      string   `json:"name"`
	MAC       string   `json:"macAddress"`
	Features  []string `json:"features"`
	Uplink    struct {
		DeviceID string `json:"deviceId"`
	} `json:"uplink"`
	Interfaces json.RawMessage `json:"interfaces"` // Use RawMessage to handle varying structures
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
	LLDPTable []struct {
		LocalPortIdx    int    `json:"local_port_idx"`
		LocalPortName   string `json:"local_port_name"`
		ChassisID       string `json:"chassis_id"`
		PortID          string `json:"port_id"`
		PortDescription string `json:"port_description"`
		SystemName      string `json:"system_name"`
		ManagementAddr  string `json:"management_address"`
	} `json:"lldp_table"`
	PortTable []struct {
		PortIdx         int    `json:"port_idx"`
		Name            string `json:"name"`
		ConnectedDevice struct {
			MAC  string `json:"mac"`
			Name string `json:"name"`
			IP   string `json:"ip"`
		} `json:"connected_device"`
	} `json:"port_table"`
}

// createUniFiClient initializes an HTTP client for UniFi API calls with configured timeout and TLS settings.
func (e *DiscoveryEngine) createUniFiClient(apiConfig UniFiAPIConfig) *http.Client {
	return &http.Client{
		Timeout: e.config.Timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: apiConfig.InsecureSkipVerify,
			},
		},
	}
}

func (e *DiscoveryEngine) fetchUniFiSites(ctx context.Context, job *DiscoveryJob, apiConfig UniFiAPIConfig) ([]UniFiSite, error) {
	log.Printf("Job %s: Fetching sites for UniFi API: %s", job.ID, apiConfig.Name)

	// Check cache
	job.mu.RLock()
	if sites, exists := job.uniFiSiteCache[apiConfig.BaseURL]; exists {
		job.mu.RUnlock()
		log.Printf("Job %s: Using cached sites for %s", job.ID, apiConfig.Name)
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
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("sites request for %s failed with status: %d", apiConfig.Name, resp.StatusCode)
	}

	var sitesResp struct {
		Data []UniFiSite `json:"data"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&sitesResp); err != nil {
		return nil, fmt.Errorf("failed to parse sites response from %s: %w", apiConfig.Name, err)
	}

	if len(sitesResp.Data) == 0 {
		return nil, fmt.Errorf("no sites found for %s", apiConfig.Name)
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
	ctx context.Context, job *DiscoveryJob, targetIP, agentID, pollerID string) ([]*TopologyLink, error) {
	log.Printf("Job %s: Querying UniFi APIs for %s", job.ID, targetIP)

	var allLinks []*TopologyLink

	seenLinks := make(map[string]struct{})

	for _, apiConfig := range e.config.UniFiAPIs {
		if apiConfig.BaseURL == "" || apiConfig.APIKey == "" {
			log.Printf("Job %s: Skipping incomplete UniFi API config: %s", job.ID, apiConfig.Name)
			continue
		}

		sites, err := e.fetchUniFiSites(ctx, job, apiConfig)
		if err != nil {
			log.Printf("Job %s: Failed to fetch sites for %s: %v", job.ID, apiConfig.Name, err)
			continue
		}

		for _, site := range sites {
			links, err := e.querySingleUniFiAPI(ctx, job, targetIP, agentID, pollerID, apiConfig, site)
			if err != nil {
				log.Printf("Job %s: Failed to query UniFi API %s, site %s: %v",
					job.ID, apiConfig.Name, site.Name, err)
				continue
			}

			for _, link := range links {
				linkKey := fmt.Sprintf("%s:%s:%s:%s",
					link.LocalDeviceIP, link.NeighborMgmtAddr, link.Protocol, site.ID)
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
	ErrNoUniFiNeighborsFound = errors.New("no UniFi neighbors found")
)

// fetchUniFiDevicesForSite fetches devices from a UniFi site and creates a device cache
func (e *DiscoveryEngine) fetchUniFiDevicesForSite(
	ctx context.Context,
	job *DiscoveryJob,
	client *http.Client,
	headers map[string]string,
	apiConfig UniFiAPIConfig,
	site UniFiSite,
	agentID, pollerID string) ([]UniFiDevice, map[string]struct {
	IP       string
	Name     string
	MAC      string
	DeviceID string
}, error) {
	devicesURL := fmt.Sprintf("%s/sites/%s/devices?limit=50", apiConfig.BaseURL, site.ID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, devicesURL, http.NoBody)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create devices request for %s, site %s: %w", apiConfig.Name, site.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to fetch devices from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("devices request for %s, site %s failed with status: %d",
			apiConfig.Name, site.Name, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to read devices response body from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	log.Printf("Job %s: Devices response from %s, site %s: %s",
		job.ID, apiConfig.Name, site.Name, string(body))

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
		deviceID := device.IPAddress

		if agentID != "" && pollerID != "" && device.IPAddress != "" {
			deviceID = fmt.Sprintf("%s:%s:%s", agentID, pollerID, device.IPAddress)
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
	_ *DiscoveryJob,
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
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("details request for device %s failed with status: %d",
			deviceID, resp.StatusCode)
	}

	var details UniFiDeviceDetails

	if err := json.NewDecoder(resp.Body).Decode(&details); err != nil {
		return nil, fmt.Errorf("failed to parse details for device %s: %w", deviceID, err)
	}

	return &details, nil
}

// processLLDPTable processes LLDP table entries and creates topology links
func (e *DiscoveryEngine) processLLDPTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	links := make([]*TopologyLink, 0, len(details.LLDPTable))

	for i := range details.LLDPTable {
		entry := &details.LLDPTable[i]
		link := &TopologyLink{
			Protocol:           "LLDP",
			LocalDeviceIP:      device.IPAddress,
			LocalDeviceID:      deviceID,
			LocalIfIndex:       entry.LocalPortIdx,
			LocalIfName:        entry.LocalPortName,
			NeighborChassisID:  entry.ChassisID,
			NeighborPortID:     entry.PortID,
			NeighborPortDescr:  entry.PortDescription,
			NeighborSystemName: entry.SystemName,
			NeighborMgmtAddr:   entry.ManagementAddr,
			Metadata: map[string]string{
				"discovery_id":    job.ID,
				"discovery_time":  time.Now().Format(time.RFC3339),
				"source":          "unifi-api",
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
func (e *DiscoveryEngine) processPortTable(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	details *UniFiDeviceDetails,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	for i := range details.PortTable {
		port := &details.PortTable[i]
		if port.ConnectedDevice.MAC != "" {
			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      device.IPAddress,
				LocalDeviceID:      deviceID,
				LocalIfIndex:       port.PortIdx,
				LocalIfName:        port.Name,
				NeighborChassisID:  port.ConnectedDevice.MAC,
				NeighborSystemName: port.ConnectedDevice.Name,
				NeighborMgmtAddr:   port.ConnectedDevice.IP,
				Metadata: map[string]string{
					"discovery_id":    job.ID,
					"discovery_time":  time.Now().Format(time.RFC3339),
					"source":          "unifi-api",
					"controller_url":  apiConfig.BaseURL,
					"site_id":         site.ID,
					"site_name":       site.Name,
					"controller_name": apiConfig.Name,
				},
			}

			links = append(links, link)
		}
	}

	return links
}

// processUplinkInfo processes uplink information and creates topology links
func (e *DiscoveryEngine) processUplinkInfo(
	job *DiscoveryJob,
	device *UniFiDevice,
	deviceCache map[string]struct {
	IP       string
	Name     string
	MAC      string
	DeviceID string
},
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*TopologyLink {
	var links []*TopologyLink

	if uplinkID := device.Uplink.DeviceID; uplinkID != "" {
		if uplink, exists := deviceCache[uplinkID]; exists {
			link := &TopologyLink{
				Protocol:           "UniFi-API",
				LocalDeviceIP:      uplink.IP,
				LocalDeviceID:      uplink.DeviceID,
				LocalIfIndex:       0,
				NeighborChassisID:  device.MAC,
				NeighborSystemName: device.Name,
				NeighborMgmtAddr:   device.IPAddress,
				Metadata: map[string]string{
					"discovery_id":       job.ID,
					"discovery_time":     time.Now().Format(time.RFC3339),
					"source":             "unifi-api",
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
	targetIP, agentID, pollerID string,
	apiConfig UniFiAPIConfig,
	site UniFiSite) ([]*TopologyLink, error) {
	client := e.createUniFiClient(apiConfig)
	headers := map[string]string{
		"X-API-Key":    apiConfig.APIKey,
		"Content-Type": "application/json",
	}

	// Fetch devices and create device cache
	devices, deviceCache, err :=
		e.fetchUniFiDevicesForSite(ctx, job, client, headers, apiConfig, site, agentID, pollerID)
	if err != nil {
		return nil, err
	}

	var links []*TopologyLink

	// Process each device
	for i := range devices {
		device := &devices[i]
		// Skip if IP doesn't match target (when specified) or not a switching device
		if targetIP != "" && device.IPAddress != targetIP {
			continue
		}

		if !contains(device.Features, "switching") && targetIP != "" {
			continue
		}

		// Generate DeviceID
		deviceID := device.IPAddress
		if agentID != "" && pollerID != "" && device.IPAddress != "" {
			deviceID = fmt.Sprintf("%s:%s:%s", agentID, pollerID, device.IPAddress)
		}

		// Fetch device details
		details, err := e.fetchDeviceDetails(ctx, job, client, headers, apiConfig, site, device.ID)
		if err != nil {
			log.Printf("Job %s: %v", job.ID, err)
			continue
		}

		// Process LLDP table
		lldpLinks := e.processLLDPTable(job, device, deviceID, details, apiConfig, site)
		links = append(links, lldpLinks...)

		// Process port table
		portLinks := e.processPortTable(job, device, deviceID, details, apiConfig, site)
		links = append(links, portLinks...)

		// Process uplink information
		uplinkLinks := e.processUplinkInfo(job, device, deviceCache, apiConfig, site)
		links = append(links, uplinkLinks...)
	}

	return links, nil
}

func (e *DiscoveryEngine) queryUniFiDevices(
	job *DiscoveryJob, targetIP, agentID, pollerID string) ([]*DiscoveredDevice, []*DiscoveredInterface, error) {
	log.Printf("Job %s: Querying UniFi devices for %s", job.ID, targetIP)

	var allDevices []*DiscoveredDevice

	var allInterfaces []*DiscoveredInterface

	seenDevices := make(map[string]struct{})

	for _, apiConfig := range e.config.UniFiAPIs {
		if apiConfig.BaseURL == "" || apiConfig.APIKey == "" {
			log.Printf("Job %s: Skipping incomplete UniFi API config: %s", job.ID, apiConfig.Name)
			continue
		}

		sites, err := e.fetchUniFiSites(job.ctx, job, apiConfig)
		if err != nil {
			log.Printf("Job %s: Failed to fetch sites for %s: %v", job.ID, apiConfig.Name, err)
			continue
		}

		for _, site := range sites {
			devices, interfaces, err := e.querySingleUniFiDevices(job, targetIP, apiConfig, site, agentID, pollerID)
			if err != nil {
				log.Printf("Job %s: Failed to query UniFi devices from %s, site %s: %v",
					job.ID, apiConfig.Name, site.Name, err)
				continue
			}

			for i := range devices {
				device := devices[i]
				deviceKey := fmt.Sprintf("%s:%s", device.IP, site.ID)

				if _, exists := seenDevices[deviceKey]; !exists {
					seenDevices[deviceKey] = struct{}{}

					allDevices = append(allDevices, device)
				}
			}

			allInterfaces = append(allInterfaces, interfaces...)
		}
	}

	if len(allDevices) == 0 {
		return nil, nil, fmt.Errorf("no UniFi devices found")
	}

	return allDevices, allInterfaces, nil
}

func (e *DiscoveryEngine) fetchUniFiDevices(
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

	req, err := http.NewRequest(http.MethodGet, devicesURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create devices request for %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch devices from %s, site %s: %w", apiConfig.Name, site.Name, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body) // Read body for error context
		return nil, fmt.Errorf("devices request for %s, site %s failed with status: %d, body: %s",
			apiConfig.Name, site.Name, resp.StatusCode, string(bodyBytes))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read devices response body from %s, site %s: %w",
			apiConfig.Name, site.Name, err)
	}

	log.Printf("Job %s: Devices response from %s, site %s (first 500 chars): %.500s",
		job.ID, apiConfig.Name, site.Name, string(body))

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
	site UniFiSite,
	agentID, pollerID string) *DiscoveredDevice {
	if device.IPAddress == "" {
		log.Printf("Job %s: UniFi device %s (ID: %s, MAC: %s) has no IP address, skipping.",
			job.ID, device.Name, device.ID, device.MAC)
		return nil
	}

	if agentID == "" || pollerID == "" {
		log.Printf("Job %s: Missing agentID (%s) or pollerID (%s) for UniFi device %s (%s), "+
			"cannot generate unique DeviceID, skipping.", job.ID, agentID, pollerID, device.Name, device.IPAddress)
		return nil
	}

	deviceID := fmt.Sprintf("%s:%s:%s", agentID, pollerID, device.IPAddress)

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
	site UniFiSite) []*DiscoveredInterface {
	if device.Interfaces == nil {
		return nil
	}

	var interfaces []*DiscoveredInterface

	var uniFiSwitchInterfaces UniFiInterfaces

	// Try to unmarshal as switch interfaces
	if err := json.Unmarshal(device.Interfaces, &uniFiSwitchInterfaces); err == nil && len(uniFiSwitchInterfaces.Ports) > 0 {
		interfaces = e.processSwitchInterfaces(job, device, deviceID, uniFiSwitchInterfaces, apiConfig, site)
	} else {
		// Handle non-standard interface structures
		rawInterfacesStr := string(device.Interfaces)
		// APs often report simple `["radios"]`. We don't create interfaces for these yet from UniFi.
		// SNMP polling should pick up WLAN interfaces if the AP responds to SNMP.
		if rawInterfacesStr != "" && rawInterfacesStr != `["radios"]` && rawInterfacesStr != `[]` { // also check for empty array
			log.Printf("Job %s: Device %s (%s) has non-standard UniFi interfaces structure: %s. Unmarshal error (if any): %v",
				job.ID, device.Name, device.ID, rawInterfacesStr, err)
		}
	}

	return interfaces
}

func (e *DiscoveryEngine) processSwitchInterfaces(
	_ *DiscoveryJob,
	device *UniFiDevice,
	deviceID string,
	switchInterfaces UniFiInterfaces,
	apiConfig UniFiAPIConfig,
	site UniFiSite) []*DiscoveredInterface {
	interfaces := make([]*DiscoveredInterface, 0, len(switchInterfaces.Ports))

	for i := range switchInterfaces.Ports {
		port := &switchInterfaces.Ports[i]
		adminStatus := 1 // Up by default
		operStatus := 1  // Up by default
		if strings.ToLower(port.State) == "down" || strings.ToLower(port.State) == "disabled" {
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

		e.addPoEMetadata(metadata, *port)

		iface := &DiscoveredInterface{
			DeviceIP:      device.IPAddress,
			DeviceID:      deviceID,
			IfIndex:       int32(port.Idx),
			IfName:        ifName,
			IfDescr:       ifDescr,
			IfSpeed:       uint64(port.SpeedMbps * 1000000), // Mbps to bps
			IfAdminStatus: int32(adminStatus),
			IfOperStatus:  int32(operStatus),
			Metadata:      metadata,
			// IfPhysAddress is not directly available here for switch ports from this endpoint
		}
		interfaces = append(interfaces, iface)
	}

	return interfaces
}

func (e *DiscoveryEngine) addPoEMetadata(metadata map[string]string, port struct {
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
		metadata["poe_enabled"] = fmt.Sprintf("%t", port.PoE.Enabled)
	}
}

func (e *DiscoveryEngine) querySingleUniFiDevices(
	job *DiscoveryJob,
	targetIP string, // Contextual IP, not used for filtering devices from controller here
	apiConfig UniFiAPIConfig,
	site UniFiSite,
	agentID, pollerID string) ([]*DiscoveredDevice, []*DiscoveredInterface, error) {
	log.Printf("Job %s: Querying UniFi devices from %s, site %s (context: %s)",
		job.ID, apiConfig.Name, site.Name, targetIP)

	unifiDevices, err := e.fetchUniFiDevices(job, apiConfig, site)
	if err != nil {
		return nil, nil, err
	}

	devices := make([]*DiscoveredDevice, 0, len(unifiDevices))

	// Pre-allocate allInterfaces with a reasonable estimate (at least one interface per device)
	allInterfaces := make([]*DiscoveredInterface, 0, len(unifiDevices))

	// Process each device
	for i := range unifiDevices {
		// Create discovered device
		device := e.createDiscoveredDevice(job, unifiDevices[i], apiConfig, site, agentID, pollerID)
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

// Helper function to check if a slice contains a string
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}

	return false
}
