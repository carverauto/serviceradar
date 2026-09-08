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
	"strings"
)

type deviceGroup struct {
	DeviceIDs map[string]struct{}
	MACs      map[string]struct{}
	IPs       map[string]struct{}
	SysName   string
}

func (e *DiscoveryEngine) deduplicateDevices(job *DiscoveryJob) {
	e.seedDeviceMapAlternateIPs(job)

	// Step 1: Group devices by shared identity attributes (MAC, IP, SysName)
	deviceGroups := e.buildDeviceGroups(job)

	// NOTE: We intentionally do NOT merge groups based on topology links.
	// Topology links represent adjacency (a cable between two devices), not
	// identity (proof that two discoveries are the same device). Merging on
	// adjacency causes "identity collapse" where distinct devices (gateway,
	// core switch, access points) get fused into a single mega-node, producing
	// the classic hairball graph instead of a proper tree topology.

	// Step 2: Rebuild the device list
	newDevices := e.rebuildDeviceList(job, deviceGroups)

	// Step 3: Update interfaces to point to the primary DeviceID
	e.updateInterfaceDeviceIDs(job, deviceGroups)

	// Update the results
	job.Results.Devices = newDevices
}

func (e *DiscoveryEngine) seedDeviceMapAlternateIPs(job *DiscoveryJob) {
	for _, device := range job.Results.Devices {
		if device == nil || device.DeviceID == "" {
			continue
		}

		entry, ok := job.deviceMap[device.DeviceID]
		if !ok || entry == nil {
			continue
		}

		for _, ip := range alternateIPsFromMetadata(device.Metadata) {
			if ip == "" {
				continue
			}
			entry.IPs[ip] = struct{}{}
		}
	}
}

func alternateIPsFromMetadata(metadata map[string]string) []string {
	if len(metadata) == 0 {
		return nil
	}

	ips := make([]string, 0, len(metadata))
	for key := range metadata {
		if strings.HasPrefix(key, "alt_ip:") {
			ip := strings.TrimPrefix(key, "alt_ip:")
			if ip != "" {
				ips = append(ips, ip)
			}
			continue
		}
		if strings.HasPrefix(key, "ip_alias:") {
			ip := strings.TrimPrefix(key, "ip_alias:")
			if ip != "" {
				ips = append(ips, ip)
			}
		}
	}

	return ips
}

// buildDeviceGroups groups devices by shared attributes (IPs, MACs, system names)
func (e *DiscoveryEngine) buildDeviceGroups(job *DiscoveryJob) map[string]*deviceGroup {
	deviceGroups := make(map[string]*deviceGroup) // Primary DeviceID -> group

	for deviceID, deviceEntry := range job.deviceMap {
		matchedGroupID := e.findMatchingGroup(deviceGroups, deviceEntry)

		if matchedGroupID == "" {
			// Create a new group
			deviceGroups[deviceID] = e.createNewDeviceGroup(deviceID, deviceEntry)
		} else {
			// Merge into existing group
			e.mergeIntoExistingGroup(deviceGroups[matchedGroupID], deviceID, deviceEntry)
		}
	}

	return deviceGroups
}

// findMatchingGroup finds a matching device group based on shared attributes
func (*DiscoveryEngine) findMatchingGroup(deviceGroups map[string]*deviceGroup, deviceEntry *DeviceInterfaceMap) string {
	for groupID, group := range deviceGroups {
		// Match by shared IP only when it does not collide two distinct
		// hardware MACs. A stale ARP/alias IP shared by a MikroTik CHR and a
		// vJunos chassis is adjacency noise, not proof they are one device.
		for ip := range deviceEntry.IPs {
			if ip == "" {
				continue
			}
			if _, exists := group.IPs[ip]; exists {
				if distinctHardwareMACSets(group.MACs, deviceEntry.MACs) {
					continue
				}

				return groupID
			}
		}

		// Match by shared MAC
		for mac := range deviceEntry.MACs {
			if mac == "" {
				continue
			}
			if _, exists := group.MACs[mac]; exists {
				return groupID
			}
		}
	}

	return ""
}

// createNewDeviceGroup creates a new device group for a device
func (*DiscoveryEngine) createNewDeviceGroup(deviceID string, deviceEntry *DeviceInterfaceMap) *deviceGroup {
	group := &deviceGroup{
		DeviceIDs: map[string]struct{}{deviceID: {}},
		MACs:      make(map[string]struct{}),
		IPs:       make(map[string]struct{}),
		SysName:   deviceEntry.SysName,
	}

	for mac := range deviceEntry.MACs {
		if mac == "" {
			continue
		}
		group.MACs[mac] = struct{}{}
	}

	for ip := range deviceEntry.IPs {
		if ip == "" {
			continue
		}
		group.IPs[ip] = struct{}{}
	}

	return group
}

// mergeIntoExistingGroup merges a device into an existing group
func (*DiscoveryEngine) mergeIntoExistingGroup(group *deviceGroup, deviceID string, deviceEntry *DeviceInterfaceMap) {
	group.DeviceIDs[deviceID] = struct{}{}

	for mac := range deviceEntry.MACs {
		if mac == "" {
			continue
		}
		group.MACs[mac] = struct{}{}
	}

	for ip := range deviceEntry.IPs {
		if ip == "" {
			continue
		}
		group.IPs[ip] = struct{}{}
	}

	if group.SysName == "" && deviceEntry.SysName != "" {
		group.SysName = deviceEntry.SysName
	}
}

// rebuildDeviceList rebuilds the device list with merged metadata
func (e *DiscoveryEngine) rebuildDeviceList(job *DiscoveryJob, deviceGroups map[string]*deviceGroup) []*DiscoveredDevice {
	newDevices := make([]*DiscoveredDevice, 0)

	for primaryDeviceID, group := range deviceGroups {
		primaryDevice := e.findPrimaryDevice(job, primaryDeviceID)

		if primaryDevice == nil {
			continue
		}

		e.mergeDeviceMetadata(job, primaryDevice, group)
		newDevices = append(newDevices, primaryDevice)
	}

	return newDevices
}

// findPrimaryDevice finds the primary device by its ID
func (*DiscoveryEngine) findPrimaryDevice(job *DiscoveryJob, primaryDeviceID string) *DiscoveredDevice {
	for _, device := range job.Results.Devices {
		if device.DeviceID == primaryDeviceID {
			return device
		}
	}

	return nil
}

// mergeDeviceMetadata merges metadata from other devices in the group
func (e *DiscoveryEngine) mergeDeviceMetadata(job *DiscoveryJob, primaryDevice *DiscoveredDevice, group *deviceGroup) {
	for deviceID := range group.DeviceIDs {
		if deviceID == primaryDevice.DeviceID {
			continue
		}

		for _, device := range job.Results.Devices {
			if device.DeviceID == deviceID {
				e.copyMetadataToDevice(primaryDevice, device)
				e.addAlternateIPs(primaryDevice, group.IPs)
			}
		}
	}
}

// copyMetadataToDevice copies metadata from source device to target device
func (*DiscoveryEngine) copyMetadataToDevice(targetDevice, sourceDevice *DiscoveredDevice) {
	for k, v := range sourceDevice.Metadata {
		if _, exists := targetDevice.Metadata[k]; !exists {
			if targetDevice.Metadata == nil {
				targetDevice.Metadata = make(map[string]string)
			}

			targetDevice.Metadata[k] = v
		}
	}
}

// addAlternateIPs adds alternate IPs to device metadata
func (*DiscoveryEngine) addAlternateIPs(device *DiscoveredDevice, ips map[string]struct{}) {
	for ip := range ips {
		if ip != device.IP {
			device.Metadata = addAlternateIP(device.Metadata, ip)
		}
	}
}

// updateInterfaceDeviceIDs updates interfaces to point to the primary DeviceID
func (*DiscoveryEngine) updateInterfaceDeviceIDs(job *DiscoveryJob, deviceGroups map[string]*deviceGroup) {
	for _, iface := range job.Results.Interfaces {
		for groupID, group := range deviceGroups {
			if _, exists := group.IPs[iface.DeviceIP]; exists {
				iface.DeviceID = groupID
				break
			}
		}
	}
}
