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

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// fetchDevicesForQuery fetches all devices for a single query.
func (a *ArmisIntegration) fetchDevicesForQuery(
	ctx context.Context,
	accessToken string,
	query models.QueryConfig,
) ([]Device, error) {
	a.Logger.Info().
		Str("query_label", query.Label).
		Str("query", query.Query).
		Msg("Fetching devices for query")

	devices := make([]Device, 0)

	nextPage := 0

	for nextPage >= 0 {
		page, err := a.DeviceFetcher.FetchDevicesPage(ctx, accessToken, query.Query, nextPage, a.PageSize)
		if err != nil {
			// Check if this is a 401 error and retry with a fresh token
			if !(strings.Contains(err.Error(), "401") && strings.Contains(err.Error(), "Invalid access token")) {
				a.Logger.Error().
					Err(err).
					Str("query_label", query.Label).
					Msg("Failed to fetch devices page")

				return nil, fmt.Errorf("failed query '%s': %w", query.Label, err)
			}

			a.Logger.Warn().
				Str("query_label", query.Label).
				Msg("Got 401 error, invalidating token and retrying with fresh token")

			// Invalidate the cached token if we have a CachedTokenProvider
			if cachedProvider, ok := a.TokenProvider.(*CachedTokenProvider); ok {
				cachedProvider.InvalidateToken()
			}

			// Get a fresh token
			newAccessToken, tokenErr := a.TokenProvider.GetAccessToken(ctx)
			if tokenErr != nil {
				a.Logger.Error().
					Err(tokenErr).
					Str("query_label", query.Label).
					Msg("Failed to get fresh access token after 401")

				return nil, fmt.Errorf("failed query '%s': %w", query.Label, err)
			}

			// Retry with the fresh token
			page, err = a.DeviceFetcher.FetchDevicesPage(ctx, newAccessToken, query.Query, nextPage, a.PageSize)
			if err != nil {
				a.Logger.Error().
					Err(err).
					Str("query_label", query.Label).
					Msg("Failed to fetch devices page after token refresh")

				return nil, fmt.Errorf("failed query '%s' after token refresh: %w", query.Label, err)
			}
			// Update the accessToken for subsequent pages
			accessToken = newAccessToken
		}

		// Append devices even if page is empty
		devices = append(devices, page.Data.Results...)

		if page.Data.Next != 0 {
			nextPage = page.Data.Next
		} else {
			nextPage = -1
		}

		a.Logger.Info().
			Int("page_device_count", page.Data.Count).
			Str("query_label", query.Label).
			Int("total_devices", len(devices)).
			Msg("Fetched devices page")
	}

	return devices, nil
}

// createAndWriteSweepConfig creates a sweep config from the given IPs and writes it to the KV store.
func (a *ArmisIntegration) createAndWriteSweepConfig(ctx context.Context, ips []string) error {
	// Apply blacklist filtering to IPs before creating sweep config
	if len(a.Config.NetworkBlacklist) > 0 {
		a.Logger.Info().
			Int("original_ip_count", len(ips)).
			Strs("blacklist_cidrs", a.Config.NetworkBlacklist).
			Msg("Applying network blacklist filtering to Armis IPs")

		filteredIPs, err := models.FilterIPsWithBlacklist(ips, a.Config.NetworkBlacklist)
		if err != nil {
			a.Logger.Error().
				Err(err).
				Msg("Failed to apply network blacklist filtering, using original IPs")
		} else {
			ips = filteredIPs
		}

		a.Logger.Info().
			Int("filtered_ip_count", len(ips)).
			Msg("Applied network blacklist filtering")
	}
	// Try to read existing sweep config from KV store first
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", a.Config.AgentID)

	var finalSweepConfig *models.SweepConfig

	if a.KVClient != nil {
		// Clean up old sweep config to remove any stale data before writing new config
		a.Logger.Info().
			Str("config_key", configKey).
			Msg("Cleaning up old sweep config from KV store")

		if _, delErr := a.KVClient.Delete(ctx, &proto.DeleteRequest{
			Key: configKey,
		}); delErr != nil {
			a.Logger.Debug().
				Err(delErr).
				Str("config_key", configKey).
				Msg("Failed to delete old sweep config (may not exist)")
		} else {
			a.Logger.Info().
				Str("config_key", configKey).
				Msg("Successfully cleaned up old sweep config")
		}

		// Create minimal sweep config with only networks (file config is authoritative for everything else)
		a.Logger.Info().Msg("Creating networks-only sweep config for KV")

		finalSweepConfig = &models.SweepConfig{
			Networks: ips,
		}
	} else {
		// No KV client available, create minimal config
		finalSweepConfig = &models.SweepConfig{
			Networks: ips,
		}
	}

	a.Logger.Info().
		Interface("sweep_config", finalSweepConfig).
		Msg("Sweep config to be written")

	if a.KVWriter == nil {
		a.Logger.Warn().Msg("KVWriter not configured, skipping sweep config write")
		return nil
	}

	err := a.KVWriter.WriteSweepConfig(ctx, finalSweepConfig)
	if err != nil {
		// Log as warning, as per existing behavior for KV write errors during sweep config.
		a.Logger.Warn().
			Err(err).
			Msg("Failed to write full sweep config")
	}

	return err
}

// fetchAndProcessDevices is an unexported method that handles the core logic of fetching devices from Armis,
// processing them, and writing a sweep config. It returns the processed data map, events, and the raw device slice.
func (a *ArmisIntegration) fetchAndProcessDevices(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, []Device, error) {
	accessToken, err := a.TokenProvider.GetAccessToken(ctx)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to get access token: %w", err)
	}

	if len(a.Config.Queries) == 0 {
		return nil, nil, nil, errNoQueriesConfigured
	}

	if a.PageSize <= 0 {
		a.PageSize = 100
	}

	allDevices := make([]Device, 0)

	// Fetch devices for each query
	for _, q := range a.Config.Queries {
		devices, queryErr := a.fetchDevicesForQuery(ctx, accessToken, q)
		if queryErr != nil {
			return nil, nil, nil, queryErr
		}

		allDevices = append(allDevices, devices...)
	}

	// Process devices
	data, ips, events := a.processDevices(allDevices)

	a.Logger.Info().
		Int("total_devices", len(allDevices)).
		Msg("Fetched total devices from Armis")

	// Create and write sweep config
	_ = a.createAndWriteSweepConfig(ctx, ips)

	return data, events, allDevices, nil
}

// Fetch retrieves devices from Armis for discovery purposes only.
// This method focuses purely on data discovery and does not perform state reconciliation.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, error) {
	// Discovery: Fetch devices from Armis and create sweep configs
	data, events, devices, err := a.fetchAndProcessDevices(ctx)
	if err != nil {
		return nil, nil, err
	}

	a.Logger.Info().
		Int("devices_discovered", len(devices)).
		Int("sweep_results_generated", len(events)).
		Msg("Completed Armis discovery operation")

	return data, events, nil
}

// Reconcile performs state reconciliation operations with Armis.
// This method queries ServiceRadar for current device states and updates Armis accordingly.
// It should only be called after sweep operations have completed and real availability data is available.
func (a *ArmisIntegration) Reconcile(ctx context.Context) error {
	if a.Updater == nil || a.SweepQuerier == nil {
		a.Logger.Info().Msg("Armis updater not configured, skipping reconciliation")
		return nil
	}

	a.Logger.Info().Msg("Starting Armis reconciliation operation")

	// Get current device states from ServiceRadar
	deviceStates, err := a.SweepQuerier.GetDeviceStatesBySource(ctx, string(models.DiscoverySourceArmis))
	if err != nil {
		a.Logger.Error().
			Err(err).
			Msg("Failed to query device states from ServiceRadar during reconciliation")

		return err
	}

	if len(deviceStates) == 0 {
		a.Logger.Info().Msg("No device states found for Armis source, skipping reconciliation")
		return nil
	}

	a.Logger.Info().
		Int("device_states_count", len(deviceStates)).
		Msg("Successfully queried device states from ServiceRadar for reconciliation")

	// Fetch current devices from Armis to check for retractions
	// We need this to identify devices that no longer exist in Armis but are still in ServiceRadar
	_, _, currentDevices, err := a.fetchAndProcessDevices(ctx)
	if err != nil {
		a.Logger.Error().
			Err(err).
			Msg("Failed to fetch current devices from Armis during reconciliation")

		return err
	}

	// Generate retraction events for devices no longer found in Armis
	retractionEvents := a.generateRetractionEvents(currentDevices, deviceStates)
	if len(retractionEvents) > 0 {
		a.Logger.Info().
			Int("retraction_events_count", len(retractionEvents)).
			Str("source", string(models.DiscoverySourceArmis)).
			Msg("Generated retraction events during reconciliation")

		// Send retraction events to the core service
		if a.ResultSubmitter != nil {
			if err := a.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents); err != nil {
				a.Logger.Error().
					Err(err).
					Int("retraction_events_count", len(retractionEvents)).
					Msg("Failed to submit retraction events to core service")

				return err
			}

			a.Logger.Info().
				Int("retraction_events_count", len(retractionEvents)).
				Msg("Successfully submitted retraction events to core service")
		} else {
			a.Logger.Warn().
				Int("retraction_events_count", len(retractionEvents)).
				Msg("ResultSubmitter not configured, retraction events not sent")
		}
	}

	// Prepare status updates for Armis
	updates := a.prepareArmisUpdateFromDeviceStates(deviceStates)

	a.Logger.Debug().
		Interface("updates", updates).
		Msg("Prepared updates for Armis reconciliation")

	if len(updates) > 0 {
		a.Logger.Info().
			Int("updates_count", len(updates)).
			Msg("Sending status updates to Armis")

		if err := a.Updater.UpdateDeviceStatus(ctx, updates); err != nil {
			a.Logger.Error().
				Err(err).
				Msg("Failed to update device status in Armis during reconciliation")

			return err
		}

		a.Logger.Info().Msg("Successfully completed Armis reconciliation")
	} else {
		a.Logger.Info().Msg("No device status updates needed for Armis reconciliation")
	}

	return nil
}

// generateRetractionEvents checks for devices that exist in ServiceRadar but not in the current Armis fetch.
func (a *ArmisIntegration) generateRetractionEvents(
	currentDevices []Device, existingDeviceStates []DeviceState) []*models.DeviceUpdate {
	// Create a map of current device IDs from the Armis API for efficient lookup.
	currentDeviceIDs := make(map[string]struct{}, len(currentDevices))
	for i := range currentDevices {
		currentDeviceIDs[strconv.Itoa(currentDevices[i].ID)] = struct{}{}
	}

	var retractionEvents []*models.DeviceUpdate

	now := time.Now()

	for _, state := range existingDeviceStates {
		// Extract the original armis_device_id from the metadata of the device stored in ServiceRadar.
		armisID, ok := state.Metadata["armis_device_id"].(string)
		if !ok {
			continue // Cannot determine retraction status without the original ID.
		}

		// If a device that was previously discovered is not in the current list, it's considered retracted.
		if _, found := currentDeviceIDs[armisID]; !found {
			a.Logger.Info().
				Str("armis_id", armisID).
				Str("ip", state.IP).
				Msg("Device no longer detected, generating retraction event")

			retractionEvent := &models.DeviceUpdate{
				DeviceID:    state.DeviceID,
				Source:      models.DiscoverySourceArmis,
				IP:          state.IP,
				IsAvailable: false,
				Timestamp:   now,
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

	d.Logger.Debug().
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

	d.Logger.Debug().
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
		d.Logger.Info().
			Str("query", query).
			Msg("No devices found for query")
	}

	return &searchResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (a *ArmisIntegration) processDevices(devices []Device) (data map[string][]byte, ips []string, events []*models.DeviceUpdate) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))
	events = make([]*models.DeviceUpdate, 0, len(devices))

	agentID := a.Config.AgentID
	pollerID := a.Config.PollerID
	partition := a.Config.Partition

	now := time.Now()

	for i := range devices {
		var err error

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
			a.Logger.Error().
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

		kvKey := fmt.Sprintf("%s/%s", a.Config.AgentID, ip)

		// create discovery event (sweep result style)
		metadata := map[string]interface{}{
			"armis_device_id": fmt.Sprintf("%d", d.ID),
			"tag":             tag,
		}

		hostname := d.Name
		mac := d.MacAddress
		deviceID := fmt.Sprintf("%s:%s", partition, ip)

		event := &models.DeviceUpdate{
			AgentID:   agentID,
			PollerID:  pollerID,
			Source:    models.DiscoverySourceArmis,
			DeviceID:  deviceID,
			Partition: partition,
			IP:        ip,
			MAC:       &mac,
			Hostname:  &hostname,
			Timestamp: now,
			Metadata: map[string]string{
				"integration_type": "armis",
				"integration_id":   fmt.Sprintf("%d", d.ID),
			},
		}

		for k, v := range metadata {
			if str, ok := v.(string); ok {
				event.Metadata[k] = str
			} else {
				event.Metadata[k] = fmt.Sprintf("%v", v)
			}
		}

		value, err = json.Marshal(event)
		if err != nil {
			a.Logger.Error().
				Err(err).
				Int("device_id", d.ID).
				Msg("Failed to marshal device event")

			continue
		}

		data[kvKey] = value

		events = append(events, event)

		ips = append(ips, ip+"/32")
	}

	return data, ips, events
}
