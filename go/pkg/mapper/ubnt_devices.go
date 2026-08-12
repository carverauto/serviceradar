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
	"fmt"
	"net/url"
	"strings"
)

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

		sites, err := e.fetchUniFiSites(ctx, job, apiConfig)
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

	devicesURL := fmt.Sprintf("%s/sites/%s/devices", apiConfig.BaseURL, site.ID)
	devices, err := fetchUniFiPagedData[*UniFiDevice](
		ctx,
		client,
		headers,
		devicesURL,
		"devices",
		apiConfig.Name,
		site.Name,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUniFiDevicesRequestFailed, err)
	}

	e.logger.Debug().Str("job_id", job.ID).Str("api_name", apiConfig.Name).
		Str("site_name", site.Name).Int("device_count", len(devices)).
		Msg("Fetched devices from UniFi API")

	return devices, nil
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

	discovered := &DiscoveredDevice{
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

	// The UniFi gateway's reported management IP is often the WAN address
	// while the controller URL (and mapper seed) is a LAN address on the
	// same box. Stamp that host as an alternate IP so a later SNMP poll of
	// the seed attaches to this device instead of minting a sibling.
	if unifiDeviceIsController(device, apiConfig) {
		if host := unifiControllerHost(apiConfig.BaseURL); host != "" && host != device.IPAddress {
			discovered.Metadata = addAlternateIP(discovered.Metadata, host)
		}
	}

	return discovered
}

func unifiDeviceIsController(device *UniFiDevice, apiConfig UniFiAPIConfig) bool {
	if device == nil {
		return false
	}

	name := strings.TrimSpace(device.Name)
	controller := strings.TrimSpace(apiConfig.Name)
	return name != "" && controller != "" && strings.EqualFold(name, controller)
}

func unifiControllerHost(baseURL string) string {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" {
		return ""
	}

	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Hostname() == "" {
		if parsed, err = url.Parse("https://" + baseURL); err != nil {
			return ""
		}
	}

	return strings.TrimSpace(parsed.Hostname())
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
