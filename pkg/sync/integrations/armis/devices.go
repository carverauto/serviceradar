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

// Package armis pkkg/sync/integrations/armis/devices.go
package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// fetchDevicesForQuery fetches all devices for a single query.
func (a *ArmisIntegration) fetchDevicesForQuery(ctx context.Context, accessToken string, query models.QueryConfig) ([]Device, error) {
	log.Printf("Fetching devices for query '%s': %s", query.Label, query.Query)

	var devices []Device

	nextPage := 0

	for nextPage >= 0 {
		page, err := a.DeviceFetcher.FetchDevicesPage(ctx, accessToken, query.Query, nextPage, a.PageSize)
		if err != nil {
			log.Printf("Failed query '%s': %v", query.Label, err)
			return nil, fmt.Errorf("failed query '%s': %w", query.Label, err)
		}

		// Append devices even if page is empty
		devices = append(devices, page.Data.Results...)

		if page.Data.Next != 0 {
			nextPage = page.Data.Next
		} else {
			nextPage = -1
		}

		log.Printf("Fetched %d devices for '%s', total so far: %d", page.Data.Count, query.Label, len(devices))
	}

	return devices, nil
}

// writeSweepConfigWithIPs creates and writes a sweep configuration with the provided IPs.
func (a *ArmisIntegration) writeSweepConfigWithIPs(ctx context.Context, ips []string) error {
	// Build sweep config using the base SweeperConfig from the integration instance
	var finalSweepConfig *models.SweepConfig

	if a.SweeperConfig != nil {
		// If we have a base config, clone it and update networks
		clonedConfig := *a.SweeperConfig // Shallow copy is generally fine for models.SweepConfig
		clonedConfig.Networks = ips      // Update with dynamically fetched IPs
		finalSweepConfig = &clonedConfig
	} else {
		// If no base config exists, create a new one with just the networks
		finalSweepConfig = &models.SweepConfig{
			Networks: ips,
		}
	}

	err := a.KVWriter.WriteSweepConfig(ctx, finalSweepConfig)
	if err != nil {
		// Log as warning, as per existing behavior for KV write errors during sweep config.
		log.Printf("Warning: Failed to write full sweep config: %v", err)
	}

	return err
}

// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	// Check for empty queries first before making any API calls
	if len(a.Config.Queries) == 0 {
		return nil, errNoQueriesProvided
	}

	accessToken, err := a.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get access token: %w", err)
	}

	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	allDevices := make([]Device, 0)

	for _, q := range a.Config.Queries {
		devices, err := a.fetchDevicesForQuery(ctx, accessToken, q)
		if err != nil {
			return nil, err
		}

		allDevices = append(allDevices, devices...)
	}

	// Process devices
	data, ips := a.processDevices(allDevices)

	log.Printf("Fetched total of %d devices from Armis", len(allDevices))

	// Write sweep config but don't fail if it errors
	if err := a.writeSweepConfigWithIPs(ctx, ips); err != nil {
		log.Printf("Warning: Failed to write sweep config with IPs: %v", err)

		return nil, err
	}

	return data, nil
}

// FetchDevicesPage fetches a single page of devices from the Armis API.
func (d *DefaultArmisIntegration) FetchDevicesPage(
	ctx context.Context, accessToken, query string, from, length int) (*SearchResponse, error) {
	// Build request URL with query parameters
	reqURL := fmt.Sprintf("%s/api/v1/search/?aql=%s&length=%d",
		d.Config.Endpoint, url.QueryEscape(query), length)

	if from > 0 {
		reqURL += fmt.Sprintf("&from=%d", from)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, http.NoBody)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", accessToken)
	req.Header.Set("Accept", "application/json")

	resp, err := d.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Log full response
	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	log.Printf("API response for query '%s': %s", query, string(bodyBytes))

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: %d, response: %s", errUnexpectedStatusCode,
			resp.StatusCode, string(bodyBytes))
	}

	var searchResp SearchResponse

	if err := json.Unmarshal(bodyBytes, &searchResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if !searchResp.Success {
		return nil, fmt.Errorf("%w: %s", errSearchRequestFailed, string(bodyBytes))
	}

	// Handle empty results gracefully
	if searchResp.Data.Count == 0 {
		log.Printf("No devices found for query '%s'", query)
	}

	return &searchResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (*ArmisIntegration) processDevices(devices []Device) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))

	for i := range devices {
		device := &devices[i] // Use a pointer to avoid copying the struct

		// Marshal the device to JSON
		value, err := json.Marshal(device)
		if err != nil {
			log.Printf("Failed to marshal device %d: %v", device.ID, err)
			continue
		}

		// Store device in KV with device ID as key
		data[fmt.Sprintf("%d", device.ID)] = value

		// Process IP addresses - handle comma-separated list of IPs
		if device.IPAddress != "" {
			// Split by comma to handle multiple IPs
			ipList := strings.Split(device.IPAddress, ",")
			for _, ipRaw := range ipList {
				// Trim spaces and validate each IP
				ip := strings.TrimSpace(ipRaw)
				if ip != "" {
					// Add to sweep list with /32 suffix
					ips = append(ips, ip+"/32")
				}
			}
		}
	}

	return data, ips
}
