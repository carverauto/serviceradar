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
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// fetchDevicesForQuery fetches all devices for a single query.
func (a *ArmisIntegration) fetchDevicesForQuery(
	ctx context.Context,
	accessToken string,
	query models.QueryConfig,
) ([]Device, error) {
	logger.Info().
		Str("query_label", query.Label).
		Str("query", query.Query).
		Msg("Fetching devices for query")

	devices := make([]Device, 0)

	nextPage := 0

	for nextPage >= 0 {
		page, err := a.DeviceFetcher.FetchDevicesPage(ctx, accessToken, query.Query, nextPage, a.PageSize)
		if err != nil {
			logger.Error().
				Err(err).
				Str("query_label", query.Label).
				Msg("Failed to fetch devices page")

			return nil, fmt.Errorf("failed query '%s': %w", query.Label, err)
		}

		// Append devices even if page is empty
		devices = append(devices, page.Data.Results...)

		if page.Data.Next != 0 {
			nextPage = page.Data.Next
		} else {
			nextPage = -1
		}

		logger.Info().
			Int("page_device_count", page.Data.Count).
			Str("query_label", query.Label).
			Int("total_devices", len(devices)).
			Msg("Fetched devices page")
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

	logger.Info().
		Interface("sweep_config", finalSweepConfig).
		Msg("Sweep config to be written")

	if a.KVWriter == nil {
		logger.Warn().Msg("KVWriter not configured, skipping sweep config write")
		return nil
	}

	err := a.KVWriter.WriteSweepConfig(ctx, finalSweepConfig)
	if err != nil {
		// Log as warning, as per existing behavior for KV write errors during sweep config.
		logger.Warn().
			Err(err).
			Msg("Failed to write full sweep config")
	}

	return err
}

// fetchAndProcessDevices is an unexported method that handles the core logic of fetching devices from Armis,
// processing them, and writing a sweep config. It returns the processed data map and the raw device slice.
func (a *ArmisIntegration) fetchAndProcessDevices(ctx context.Context) (map[string][]byte, []Device, error) {
	accessToken, err := a.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to get access token: %w", err)
	}

	if len(a.Config.Queries) == 0 {
		return nil, nil, errNoQueriesConfigured
	}

	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	allDevices := make([]Device, 0)

	// Fetch devices for each query
	for _, q := range a.Config.Queries {
		devices, queryErr := a.fetchDevicesForQuery(ctx, accessToken, q)
		if queryErr != nil {
			return nil, nil, queryErr
		}

		allDevices = append(allDevices, devices...)
	}

	// Process devices
	data, ips := a.processDevices(allDevices)

	logger.Info().
		Int("total_devices", len(allDevices)).
		Msg("Fetched total devices from Armis")

	// Create and write sweep config
	_ = a.createAndWriteSweepConfig(ctx, ips)

	return data, allDevices, nil
}

func (a *ArmisIntegration) convertToSweepResults(devices []Device) []*models.SweepResult {
	out := make([]*models.SweepResult, 0, len(devices))

	for i := range devices {
		dev := &devices[i]
		hostname := dev.Name
		mac := dev.MacAddress
		tag := ""

		if len(dev.Tags) > 0 {
			tag = strings.Join(dev.Tags, ",")
		}

		meta := map[string]string{
			"armis_device_id": fmt.Sprintf("%d", dev.ID),
			"tag":             tag,
		}

		ip := extractFirstIP(dev.IPAddress)

		out = append(out, &models.SweepResult{
			AgentID:         a.Config.AgentID,
			PollerID:        a.Config.PollerID,
			Partition:       a.Config.Partition,
			DiscoverySource: "armis",
			IP:              ip,
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       dev.FirstSeen,
			Available:       true,
			Metadata:        meta,
		})
	}

	return out
}

// Fetch retrieves devices from Armis. If the updater is configured, it also
// correlates sweep results and sends status updates back to Armis.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.SweepResult, error) {
	// Part 1: Discovery (Armis -> ServiceRadar)
	data, devices, err := a.fetchAndProcessDevices(ctx)
	if err != nil {
		return nil, nil, err
	}

	modelEvents := a.convertToSweepResults(devices)

	// Part 2: Update (ServiceRadar -> Armis)
	if a.Updater == nil || a.SweepQuerier == nil {
		logger.Info().Msg("Armis updater not configured, skipping status update")
		return data, modelEvents, nil
	}

	// Call the new dedicated function to get device states
	deviceStates, err := a.SweepQuerier.GetDeviceStatesBySource(ctx, "armis")
	if err != nil {
		logger.Error().
			Err(err).
			Msg("Failed to query device states from ServiceRadar, skipping update")

		return data, modelEvents, nil
	}

	logger.Info().
		Int("device_states_count", len(deviceStates)).
		Msg("Successfully queried device states from ServiceRadar")

	// Generate and append retraction events for devices no longer found in Armis
	retractionEvents := a.generateRetractionEvents(devices, deviceStates)
	if len(retractionEvents) > 0 {
		logger.Info().
			Int("retraction_events_count", len(retractionEvents)).
			Str("source", "armis").
			Msg("Generated retraction events")

		modelEvents = append(modelEvents, retractionEvents...)
	}

	// Prepare updates using the new typed slice
	updates := a.prepareArmisUpdateFromDeviceStates(deviceStates)

	logger.Debug().
		Interface("updates", updates).
		Msg("Prepared updates for Armis")

	if len(updates) > 0 {
		logger.Info().
			Int("updates_count", len(updates)).
			Msg("Prepared status updates to send to Armis")

		if err := a.Updater.UpdateDeviceStatus(ctx, updates); err != nil {
			logger.Error().
				Err(err).
				Msg("Failed to update device status in Armis")
		} else {
			logger.Info().Msg("Successfully invoked the Armis device status updater")
		}
	} else {
		logger.Info().Msg("No device status updates to send to Armis")
	}

	return data, modelEvents, nil
}

// generateRetractionEvents checks for devices that exist in ServiceRadar but not in the current Armis fetch.
func (a *ArmisIntegration) generateRetractionEvents(
	currentDevices []Device, existingDeviceStates []DeviceState) []*models.SweepResult {
	// Create a map of current device IDs from the Armis API for efficient lookup.
	currentDeviceIDs := make(map[string]struct{}, len(currentDevices))
	for i := range currentDevices {
		currentDeviceIDs[strconv.Itoa(currentDevices[i].ID)] = struct{}{}
	}

	var retractionEvents []*models.SweepResult

	now := time.Now()

	for _, state := range existingDeviceStates {
		// Extract the original armis_device_id from the metadata of the device stored in ServiceRadar.
		armisID, ok := state.Metadata["armis_device_id"].(string)
		if !ok {
			continue // Cannot determine retraction status without the original ID.
		}

		// If a device that was previously discovered is not in the current list, it's considered retracted.
		if _, found := currentDeviceIDs[armisID]; !found {
			logger.Info().
				Str("armis_id", armisID).
				Str("ip", state.IP).
				Msg("Device no longer detected, generating retraction event")

			retractionEvent := &models.SweepResult{
				DeviceID:        state.DeviceID,
				DiscoverySource: "armis",
				IP:              state.IP,
				Available:       false,
				Timestamp:       now,
				Metadata: map[string]string{
					"_deleted": "true",
				},
				AgentID:   a.Config.AgentID,
				PollerID:  a.Config.PollerID,
				Partition: a.Config.Partition,
			}

			retractionEvents = append(retractionEvents, retractionEvent)
		}
	}

	return retractionEvents
}

func (*ArmisIntegration) prepareArmisUpdateFromDeviceStates(states []DeviceState) []ArmisDeviceStatus {
	updates := make([]ArmisDeviceStatus, 0, len(states))

	for _, state := range states {
		var armisDeviceID int

		if state.Metadata != nil {
			// Extract the armis_device_id we stored during the initial discovery
			if idStr, ok := state.Metadata["armis_device_id"].(string); ok {
				id, err := strconv.Atoi(idStr)
				if err == nil {
					armisDeviceID = id
				}
			}
		}

		if state.IP == "" || armisDeviceID == 0 {
			continue // Cannot update Armis without the original device ID
		}

		updates = append(updates, ArmisDeviceStatus{
			DeviceID:  armisDeviceID,
			IP:        state.IP,
			Available: !state.IsAvailable,
		})
	}

	return updates
}

// prepareArmisUpdateFromDeviceQuery processes the results of a 'show devices'
// SRQL query and prepares them for an Armis status update.
func (*ArmisIntegration) prepareArmisUpdateFromDeviceQuery(results []map[string]interface{}) []ArmisDeviceStatus {
	updates := make([]ArmisDeviceStatus, 0, len(results))

	for _, deviceData := range results {
		ip, _ := deviceData["ip"].(string)
		isAvailable, _ := deviceData["is_available"].(bool)

		var armisDeviceID int

		if metadata, ok := deviceData["metadata"].(map[string]interface{}); ok {
			if idStr, ok := metadata["armis_device_id"].(string); ok {
				id, err := strconv.Atoi(idStr)
				if err == nil {
					armisDeviceID = id
				}
			}
		}

		// To update Armis, we must have the device's original ID.
		if ip == "" || armisDeviceID == 0 {
			continue
		}

		updates = append(updates, ArmisDeviceStatus{
			DeviceID:  armisDeviceID,
			IP:        ip,
			Available: isAvailable,
		})
	}

	return updates
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

	logger.Debug().
		Str("request_url", reqURL).
		Msg("Sending request to Armis API")

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

	logger.Debug().
		Str("query", query).
		Str("response_body", string(bodyBytes)).
		Msg("API response from Armis")

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
		logger.Info().
			Str("query", query).
			Msg("No devices found for query")
	}

	return &searchResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (a *ArmisIntegration) processDevices(devices []Device) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))

	pollerID := a.Config.PollerID

	for i := range devices {
		d := &devices[i] // Use a pointer to avoid copying the struct

		tag := ""
		if len(d.Tags) > 0 {
			tag = strings.Join(d.Tags, ",")
		}

		enriched := DeviceWithMetadata{
			Device:   *d,
			Metadata: map[string]string{"armis_device_id": fmt.Sprintf("%d", d.ID), "tag": tag},
		}

		// Marshal the device with metadata to JSON
		value, err := json.Marshal(enriched)
		if err != nil {
			logger.Error().
				Err(err).
				Int("device_id", d.ID).
				Msg("Failed to marshal enriched device")

			continue
		}

		// Store device in KV with device ID as key
		data[fmt.Sprintf("%d", d.ID)] = value

		// Only consider the first IP address returned by Armis
		ip := extractFirstIP(d.IPAddress)
		if ip == "" {
			continue
		}

		deviceID := fmt.Sprintf("%s:%s", a.Config.Partition, ip)

		metadata := map[string]interface{}{
			"armis_id": fmt.Sprintf("%d", d.ID),
			"tag":      tag,
		}

		modelDevice := &models.Device{
			DeviceID:         deviceID,
			PollerID:         pollerID,
			DiscoverySources: []string{"armis"},
			IP:               ip,
			MAC:              d.MacAddress,
			Hostname:         d.Name,
			FirstSeen:        d.FirstSeen,
			LastSeen:         d.LastSeen,
			IsAvailable:      true,
			Metadata:         metadata,
		}

		value, err = json.Marshal(modelDevice)
		if err != nil {
			logger.Error().
				Err(err).
				Int("device_id", d.ID).
				Msg("Failed to marshal model device")

			continue
		}

		data[deviceID] = value

		ips = append(ips, ip+"/32")
	}

	return data, ips
}
