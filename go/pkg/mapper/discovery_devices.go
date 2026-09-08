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
	"time"
)

// initializeDevice creates and initializes a new DiscoveredDevice
func (*DiscoveryEngine) initializeDevice(target string) *DiscoveredDevice {
	return &DiscoveredDevice{
		IP:        target,
		FirstSeen: time.Now(),
		LastSeen:  time.Now(),
		Metadata:  make(map[string]string),
	}
}

// addOrUpdateDeviceToResults adds or updates a device in the job's results.
func (e *DiscoveryEngine) addOrUpdateDeviceToResults(job *DiscoveryJob, newDevice *DiscoveredDevice) {
	e.applyCanonicalIdentityFromIP(job, newDevice)
	e.ensureDeviceID(newDevice)

	// Look for an existing device to merge with
	for i, existingDevice := range job.Results.Devices {
		if e.isDeviceMatch(existingDevice, newDevice) {
			if existingDevice.IP != newDevice.IP {
				existingDevice.Metadata = addAlternateIP(existingDevice.Metadata, newDevice.IP)

				e.logger.Info().Str("job_id", job.ID).
					Str("hostname", existingDevice.Hostname).
					Str("mac", existingDevice.MAC).
					Str("device_id", existingDevice.DeviceID).
					Str("alternate_ip", newDevice.IP).
					Str("primary_ip", existingDevice.IP).
					Str("source", newDevice.Metadata["source"]).
					Msg("Device updated with alternate IP")
			}

			e.updateExistingDevice(job, i, newDevice)
			return
		}
	}

	// Add to device map
	if deviceEntry, exists := job.deviceMap[newDevice.DeviceID]; exists {
		if newDevice.MAC != "" {
			deviceEntry.MACs[newDevice.MAC] = struct{}{}
		}
		if newDevice.IP != "" {
			deviceEntry.IPs[newDevice.IP] = struct{}{}
		}

		if newDevice.Hostname != "" {
			deviceEntry.SysName = newDevice.Hostname
		}
	} else {
		macs := make(map[string]struct{})
		if newDevice.MAC != "" {
			macs[newDevice.MAC] = struct{}{}
		}

		ips := make(map[string]struct{})
		if newDevice.IP != "" {
			ips[newDevice.IP] = struct{}{}
		}

		job.deviceMap[newDevice.DeviceID] = &DeviceInterfaceMap{
			DeviceID:   newDevice.DeviceID,
			MACs:       macs,
			IPs:        ips,
			SysName:    newDevice.Hostname,
			Interfaces: []*DiscoveredInterface{},
		}
	}

	e.logger.Info().Str("job_id", job.ID).Str("hostname", newDevice.Hostname).
		Str("ip", newDevice.IP).Str("mac", newDevice.MAC).
		Str("device_id", newDevice.DeviceID).
		Str("source", newDevice.Metadata["source"]).
		Msg("Adding new device")

	e.addNewDevice(job, newDevice)
}

// ensureDeviceID ensures the DeviceID is populated if possible.
// SNMP devices with no chassis MAC (Linux/FRR loopback as ifIndex 1) must
// still get an ip-* ID so core ingest does not drop every interface row.
func (*DiscoveryEngine) ensureDeviceID(device *DiscoveredDevice) {
	if device == nil || device.DeviceID != "" {
		return
	}

	if id := GenerateDeviceID(device.MAC); id != "" {
		device.DeviceID = id
		return
	}

	device.DeviceID = GenerateDeviceIDFromIP(device.IP)
}

func (e *DiscoveryEngine) applyCanonicalIdentityFromIP(job *DiscoveryJob, device *DiscoveredDevice) {
	if job == nil || device == nil || strings.TrimSpace(device.IP) == "" {
		return
	}

	existingID, existingMAC := e.resolveExistingDeviceIdentityByIPUnlocked(job, device.IP)
	if existingID == "" {
		return
	}

	// A recycled IP (DHCP, VIP, stale ARP) that now answers for different
	// hardware must not inherit the previous occupant's identity. UniFi
	// UAA/LAA siblings of the same NIC still canonicalize; disjoint MACs
	// stay two devices.
	if distinctHardwareMACs(device.MAC, existingMAC) {
		return
	}

	currentID := strings.TrimSpace(device.DeviceID)
	if currentID == "" || strings.HasPrefix(currentID, "ip-") || currentID == existingID {
		device.DeviceID = existingID
	}

	if existingMAC == "" {
		return
	}

	if device.MAC == "" {
		device.MAC = existingMAC
		return
	}

	if NormalizeMAC(device.MAC) != NormalizeMAC(existingMAC) {
		device.Metadata = addAlternateMAC(device.Metadata, device.MAC)
		device.MAC = existingMAC
	}
}

func (e *DiscoveryEngine) resolveExistingDeviceIdentityByIP(job *DiscoveryJob, ip string) (string, string) {
	if job == nil {
		return "", ""
	}

	job.mu.RLock()
	defer job.mu.RUnlock()

	return e.resolveExistingDeviceIdentityByIPUnlocked(job, ip)
}

func (*DiscoveryEngine) resolveExistingDeviceIdentityByIPUnlocked(job *DiscoveryJob, ip string) (string, string) {
	if job == nil {
		return "", ""
	}

	targetIP := strings.TrimSpace(ip)
	if targetIP == "" {
		return "", ""
	}

	for _, existing := range job.Results.Devices {
		if existing == nil {
			continue
		}

		if strings.TrimSpace(existing.IP) == targetIP {
			return existing.DeviceID, existing.MAC
		}
	}

	for _, existing := range job.Results.Devices {
		if existing == nil {
			continue
		}

		if _, ok := existing.Metadata["alt_ip:"+targetIP]; ok {
			return existing.DeviceID, existing.MAC
		}
		if _, ok := existing.Metadata["ip_alias:"+targetIP]; ok {
			return existing.DeviceID, existing.MAC
		}
	}

	for deviceID, entry := range job.deviceMap {
		if entry == nil {
			continue
		}
		if _, ok := entry.IPs[targetIP]; !ok {
			continue
		}

		for mac := range entry.MACs {
			if norm := NormalizeMAC(mac); norm != "" {
				return deviceID, mac
			}
		}

		return deviceID, ""
	}

	return "", ""
}

func (*DiscoveryEngine) isDeviceMatch(existingDevice, newDevice *DiscoveredDevice) bool {
	// First check by DeviceID if both have it
	if newDevice.DeviceID != "" && existingDevice.DeviceID != "" && newDevice.DeviceID == existingDevice.DeviceID {
		return true
	}

	// Fallback by normalized MAC identity.
	if newDevice.MAC != "" && existingDevice.MAC != "" {
		return NormalizeMAC(newDevice.MAC) == NormalizeMAC(existingDevice.MAC)
	}

	return false
}

// updateExistingDevice updates an existing device with information from a new device
func (e *DiscoveryEngine) updateExistingDevice(job *DiscoveryJob, index int, newDevice *DiscoveredDevice) {
	// Update non-empty fields
	if newDevice.Hostname != "" {
		job.Results.Devices[index].Hostname = newDevice.Hostname
	}

	if newDevice.MAC != "" {
		existingMAC := job.Results.Devices[index].MAC
		if existingMAC == "" {
			job.Results.Devices[index].MAC = newDevice.MAC
		} else if NormalizeMAC(existingMAC) != NormalizeMAC(newDevice.MAC) {
			job.Results.Devices[index].Metadata = addAlternateMAC(job.Results.Devices[index].Metadata, newDevice.MAC)
		}
	}

	if newDevice.SysDescr != "" {
		job.Results.Devices[index].SysDescr = newDevice.SysDescr
	}

	if newDevice.SysObjectID != "" {
		job.Results.Devices[index].SysObjectID = newDevice.SysObjectID
	}

	if newDevice.SysContact != "" {
		job.Results.Devices[index].SysContact = newDevice.SysContact
	}

	if newDevice.SysLocation != "" {
		job.Results.Devices[index].SysLocation = newDevice.SysLocation
	}

	if newDevice.Uptime != 0 {
		job.Results.Devices[index].Uptime = newDevice.Uptime
	}

	job.Results.Devices[index].LastSeen = time.Now()

	// Update metadata
	e.updateDeviceMetadata(job, index, newDevice)

	// Publish updated device
	e.publishDevice(job, job.Results.Devices[index])
}

// updateDeviceMetadata updates the metadata of an existing device
func (*DiscoveryEngine) updateDeviceMetadata(job *DiscoveryJob, index int, newDevice *DiscoveredDevice) {
	if job.Results.Devices[index].Metadata == nil {
		job.Results.Devices[index].Metadata = make(map[string]string)
	}

	for k, v := range newDevice.Metadata {
		job.Results.Devices[index].Metadata[k] = v
	}
}

// addNewDevice adds a new device to the results
func (e *DiscoveryEngine) addNewDevice(job *DiscoveryJob, newDevice *DiscoveredDevice) {
	newDevice.FirstSeen = time.Now()
	newDevice.LastSeen = time.Now()
	job.Results.Devices = append(job.Results.Devices, newDevice)

	// Publish new device
	e.publishDevice(job, newDevice)
}

// publishDevice publishes a device via the publisher if available
func (e *DiscoveryEngine) publishDevice(job *DiscoveryJob, device *DiscoveredDevice) {
	if e.publisher != nil {
		if err := e.publisher.PublishDevice(job.ctx, device); err != nil {
			e.logger.Error().Str("job_id", job.ID).Str("device_ip", device.IP).
				Err(err).Msg("Failed to publish device")
		}
	}
}
