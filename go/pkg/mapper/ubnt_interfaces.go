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
	"encoding/json"
	"fmt"
	"strings"
)

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

const defaultMaxValueInt32 = 0x7FFFFFFF // Max value for int32

func (e *DiscoveryEngine) processSwitchInterfaces(
	_ *DiscoveryJob,
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
		metadata["poe_enabled"] = stringTrueValue
	}
}
