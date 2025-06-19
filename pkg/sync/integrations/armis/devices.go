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
func (a *ArmisIntegration) fetchDevicesForQuery(
	ctx context.Context,
	accessToken string,
	query models.QueryConfig,
) ([]Device, error) {
	log.Printf("Fetching devices for query '%s': %s", query.Label, query.Query)

	devices := make([]Device, 0)

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

// createAndWriteSweepConfig creates a sweep config from the given IPs and writes it to the KV store.
func (a *ArmisIntegration) createAndWriteSweepConfig(ctx context.Context, ips []string) error {
	// Build sweep config using the base SweeperConfig from the integration instance
	var finalSweepConfig *models.SweepConfig

	if a.SweeperConfig != nil {
		clonedConfig := *a.SweeperConfig // Shallow copy is generally fine for models.SweepConfig
		clonedConfig.Networks = ips      // Update with dynamically fetched IPs
		finalSweepConfig = &clonedConfig
	} else {
		// If SweeperConfig is nil, create a new one with just the networks
		finalSweepConfig = &models.SweepConfig{
			Networks: ips,
		}
	}

	log.Printf("Sweep config to be written: %+v", finalSweepConfig)

	err := a.KVWriter.WriteSweepConfig(ctx, finalSweepConfig)
	if err != nil {
		// Log as warning, as per existing behavior for KV write errors during sweep config.
		log.Printf("Warning: Failed to write full sweep config: %v", err)
	}

	return err
}

// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	accessToken, err := a.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get access token: %w", err)
	}

	if len(a.Config.Queries) == 0 {
		return nil, errNoQueriesConfigured
	}

	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	allDevices := make([]Device, 0)

	// Fetch devices for each query
	for _, q := range a.Config.Queries {
		devices, queryErr := a.fetchDevicesForQuery(ctx, accessToken, q)
		if queryErr != nil {
			return nil, queryErr
		}

		allDevices = append(allDevices, devices...)
	}

	// Process devices
	data, ips := a.processDevices(allDevices)

	log.Printf("Fetched total of %d devices from Armis", len(allDevices))

	// Create and write sweep config
	// Errors from createAndWriteSweepConfig are logged but don't fail the Fetch operation
	_ = a.createAndWriteSweepConfig(ctx, ips)

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

	log.Printf("Sending request to: %s", reqURL)

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
func (a *ArmisIntegration) processDevices(devices []Device) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))

	agentID := a.Config.AgentID
	pollerID := a.Config.PollerID

	for i := range devices {
		d := &devices[i] // Use a pointer to avoid copying the struct

		if d.IPAddress == "" {
			continue
		}

		ipList := strings.Split(d.IPAddress, ",")
		for _, ipRaw := range ipList {
			ip := strings.TrimSpace(ipRaw)
			if ip == "" {
				continue
			}

			deviceID := fmt.Sprintf("%s:%s:%s", ip, agentID, pollerID)

			metadata := map[string]interface{}{
				"armis_id":     fmt.Sprintf("%d", d.ID),
				"type":         d.Type,
				"category":     d.Category,
				"manufacturer": d.Manufacturer,
				"model":        d.Model,
			}

			modelDevice := &models.Device{
				DeviceID:        deviceID,
				PollerID:        pollerID,
				DiscoverySource: "armis",
				IP:              ip,
				MAC:             d.MacAddress,
				Hostname:        d.Name,
				FirstSeen:       d.FirstSeen,
				LastSeen:        d.LastSeen,
				IsAvailable:     true,
				Metadata:        metadata,
			}

			value, err := json.Marshal(modelDevice)
			if err != nil {
				log.Printf("Failed to marshal device %d: %v", d.ID, err)
				continue
			}

			data[deviceID] = value
			ips = append(ips, ip+"/32")
		}
	}

	return data, ips
}
