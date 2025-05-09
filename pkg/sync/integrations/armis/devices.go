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

// Package armis pkg/sync/integrations/armis/devices.go provides functions to fetch devices from the Armis API.
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

// Fetch retrieves devices from Armis and generates sweep config.
// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	accessToken, err := a.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get access token: %w", err)
	}

	if len(a.Config.Queries) == 0 {
		return nil, fmt.Errorf("no queries provided in config; at least one query is required")
	}

	allDevices := make([]Device, 0)
	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	for _, q := range a.Config.Queries {
		log.Printf("Fetching devices for query '%s': %s", q.Label, q.Query)

		nextPage := 0
		for {
			if nextPage < 0 {
				break
			}

			page, err := a.DeviceFetcher.FetchDevicesPage(ctx, accessToken, q.Query, nextPage, a.PageSize)
			if err != nil {
				log.Printf("Failed query '%s': %v", q.Label, err)
				return nil, fmt.Errorf("failed query '%s': %w", q.Label, err)
			}

			// Append devices even if page is empty
			allDevices = append(allDevices, page.Data.Results...)

			if page.Data.Next != 0 {
				nextPage = page.Data.Next
			} else {
				nextPage = -1
			}

			log.Printf("Fetched %d devices for '%s', total so far: %d", page.Data.Count, q.Label, len(allDevices))
		}
	}

	// Process devices
	data, ips := a.processDevices(allDevices)

	log.Printf("Fetched total of %d devices from Armis", len(allDevices))

	// Build and write sweep config
	sweepConfig := &models.SweepConfig{
		Networks: ips,
	}

	log.Println("Sweep config:", sweepConfig)

	err = a.KVWriter.WriteSweepConfig(ctx, sweepConfig)
	if err != nil {
		log.Printf("Warning: Failed to write sweep config: %v", err)
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

		// Process IP addresses - take only the first IP from comma-separated list
		if device.IPAddress != "" {
			// Split by comma and take the first IP
			ipList := strings.Split(device.IPAddress, ",")
			if len(ipList) > 0 {
				// Trim spaces and validate the first IP
				ip := strings.TrimSpace(ipList[0])
				if ip != "" {
					// Add to sweep list with /32 suffix
					ips = append(ips, ip+"/32")
				}
			}
		}
	}

	return data, ips
}
