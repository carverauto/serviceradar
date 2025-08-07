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
	"net"
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
	// Note: IPs have already been filtered by the blacklist in fetchAndProcessDevices
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", a.Config.AgentID)

	a.Logger.Info().
		Str("config_key", configKey).
		Int("total_ips", len(ips)).
		Msg("Creating sweep config with ALL devices from ALL queries accumulated in memory")

	var finalSweepConfig *models.SweepConfig

	if a.KVClient != nil {
		// Clean up old sweep config to remove any stale data before writing new config
		a.Logger.Info().
			Str("config_key", configKey).
			Msg("Cleaning up old sweep config from KV store before writing complete config")

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
		a.Logger.Info().
			Int("network_count", len(ips)).
			Msg("Creating networks-only sweep config for KV with all accumulated devices")

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
		Int("network_count", len(finalSweepConfig.Networks)).
		Str("config_key", configKey).
		Msg("Writing complete sweep config with all devices from all ASQ queries")

	if a.KVWriter == nil {
		a.Logger.Warn().Msg("KVWriter not configured, skipping sweep config write")

		return nil
	}

	err := a.KVWriter.WriteSweepConfig(ctx, finalSweepConfig)
	if err != nil {
		// Log as warning, as per existing behavior for KV write errors during sweep config.
		a.Logger.Warn().
			Err(err).
			Int("network_count", len(finalSweepConfig.Networks)).
			Str("config_key", configKey).
			Msg("Failed to write complete sweep config")
	} else {
		a.Logger.Info().
			Int("network_count", len(finalSweepConfig.Networks)).
			Str("config_key", configKey).
			Msg("Successfully wrote complete sweep config with all devices from all ASQ queries")
	}

	return err
}

// applyBlacklistFiltering filters out devices, KV data, and IPs based on the network blacklist
func (a *ArmisIntegration) applyBlacklistFiltering(
	events []*models.DeviceUpdate,
	data map[string][]byte,
	ips []string,
) (filteredEvents []*models.DeviceUpdate, filteredData map[string][]byte, filteredIPs []string) {
	if len(a.Config.NetworkBlacklist) == 0 {
		return events, data, ips
	}

	a.Logger.Info().
		Int("original_device_count", len(events)).
		Strs("blacklist_cidrs", a.Config.NetworkBlacklist).
		Msg("Applying network blacklist filtering to Armis devices")

	// Parse blacklist CIDRs once
	blacklistNetworks := make([]*net.IPNet, 0, len(a.Config.NetworkBlacklist))

	for _, cidr := range a.Config.NetworkBlacklist {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			a.Logger.Error().
				Err(err).
				Str("cidr", cidr).
				Msg("Invalid CIDR in blacklist")

			continue
		}

		blacklistNetworks = append(blacklistNetworks, network)
	}

	// Initialize return values
	filteredEvents = make([]*models.DeviceUpdate, 0, len(events))
	filteredData = make(map[string][]byte)
	filteredIPs = make([]string, 0, len(ips))

	for _, event := range events {
		// Check if device IP is blacklisted
		isBlacklisted := false

		ip := net.ParseIP(event.IP)

		if ip != nil {
			for _, network := range blacklistNetworks {
				if network.Contains(ip) {
					isBlacklisted = true
					break
				}
			}
		}

		if !isBlacklisted {
			filteredEvents = append(filteredEvents, event)

			// Keep corresponding KV data entries
			// Device data by ID - the integration_id contains the numeric Armis device ID
			if integrationID, ok := event.Metadata["integration_id"]; ok {
				if val, ok := data[integrationID]; ok {
					filteredData[integrationID] = val
				}
			}
			// Device data by agent/IP
			agentKey := fmt.Sprintf("%s/%s", a.Config.AgentID, event.IP)
			if val, ok := data[agentKey]; ok {
				filteredData[agentKey] = val
			}

			// Keep IP for sweep config
			filteredIPs = append(filteredIPs, event.IP+"/32")
		}
	}

	a.Logger.Info().
		Int("filtered_device_count", len(filteredEvents)).
		Int("filtered_out", len(events)-len(filteredEvents)).
		Msg("Applied network blacklist filtering to devices")

	return filteredEvents, filteredData, filteredIPs
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

	a.Logger.Info().
		Int("query_count", len(a.Config.Queries)).
		Msg("Starting device fetch for all queries - accumulating in memory before writing sweep config")

	allDevices := make([]Device, 0)
	deviceLabels := make(map[int]string) // Map device ID to query label

	// Fetch devices for each query and accumulate them in memory
	// This ensures we collect ALL devices from ALL queries before writing the sweep config
	for queryIndex, q := range a.Config.Queries {
		a.Logger.Info().
			Int("query_index", queryIndex).
			Int("total_queries", len(a.Config.Queries)).
			Str("query_label", q.Label).
			Msg("Fetching devices for query")

		devices, queryErr := a.fetchDevicesForQuery(ctx, accessToken, q)
		if queryErr != nil {
			return nil, nil, nil, queryErr
		}

		a.Logger.Info().
			Int("query_index", queryIndex).
			Str("query_label", q.Label).
			Int("query_device_count", len(devices)).
			Int("accumulated_device_count", len(allDevices)).
			Msg("Query completed, accumulating devices in memory")

		// Track which query discovered each device
		for i := range devices {
			deviceLabels[devices[i].ID] = q.Label
		}

		allDevices = append(allDevices, devices...)

		a.Logger.Info().
			Int("query_index", queryIndex).
			Str("query_label", q.Label).
			Int("total_accumulated_devices", len(allDevices)).
			Msg("Devices accumulated from query")
	}

	a.Logger.Info().
		Int("total_devices_from_all_queries", len(allDevices)).
		Int("total_queries_processed", len(a.Config.Queries)).
		Msg("All queries completed - processing accumulated devices")

	// Process devices with query labels
	data, ips, events := a.processDevices(allDevices, deviceLabels)

	a.Logger.Info().
		Int("total_devices", len(allDevices)).
		Int("total_ips", len(ips)).
		Int("total_events", len(events)).
		Msg("Device processing completed - applying blacklist filtering")

	// Apply blacklist filtering to devices before returning
	events, data, ips = a.applyBlacklistFiltering(events, data, ips)

	a.Logger.Info().
		Int("filtered_ips", len(ips)).
		Int("filtered_events", len(events)).
		Msg("Blacklist filtering completed - writing sweep config with all accumulated devices")

	// Create and write sweep config with ALL devices from ALL queries
	// Note: We continue processing even if sweep config write fails to ensure device data is still written to KV
	if err := a.createAndWriteSweepConfig(ctx, ips); err != nil {
		a.Logger.Warn().Err(err).Msg("Failed to write sweep config, continuing with device processing")
	}

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

	// Prepare status updates for Armis directly from the device states
	// No need to query Armis again - we trust our database as the source of truth
	updates := a.prepareArmisUpdateFromDeviceStates(deviceStates)

	a.Logger.Debug().
		Interface("updates", updates).
		Msg("Prepared updates for Armis reconciliation")

	if len(updates) > 0 {
		a.Logger.Info().
			Int("total_updates_to_send", len(updates)).
			Msg("Starting to send status updates to Armis")

		// Process updates in batches to avoid overwhelming the API
		const batchSize = 1000

		totalUpdates := len(updates)

		successfulUpdates := 0

		for i := 0; i < totalUpdates; i += batchSize {
			end := i + batchSize
			if end > totalUpdates {
				end = totalUpdates
			}

			batch := updates[i:end]
			batchNum := (i / batchSize) + 1
			totalBatches := (totalUpdates + batchSize - 1) / batchSize

			a.Logger.Info().
				Int("batch_number", batchNum).
				Int("total_batches", totalBatches).
				Int("batch_size", len(batch)).
				Int("updates_sent_so_far", i).
				Int("total_updates", totalUpdates).
				Msg("Sending batch of updates to Armis")

			if err := a.Updater.UpdateDeviceStatus(ctx, batch); err != nil {
				a.Logger.Error().
					Err(err).
					Int("batch_number", batchNum).
					Int("batch_size", len(batch)).
					Int("successful_updates_before_error", successfulUpdates).
					Msg("Failed to update device status batch in Armis during reconciliation")

				return fmt.Errorf("failed to update batch %d of %d (devices %d-%d): %w",
					batchNum, totalBatches, i+1, end, err)
			}

			successfulUpdates += len(batch)

			a.Logger.Info().
				Int("batch_number", batchNum).
				Int("total_batches", totalBatches).
				Int("successful_updates_total", successfulUpdates).
				Msg("Successfully sent batch to Armis")
		}

		a.Logger.Info().
			Int("total_updates_sent", successfulUpdates).
			Int("total_updates_requested", totalUpdates).
			Msg("Successfully completed Armis reconciliation")
	} else {
		a.Logger.Info().Msg("No device status updates needed for Armis reconciliation")
	}

	return nil
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
func (a *ArmisIntegration) processDevices(
	devices []Device,
	deviceLabels map[int]string,
) (data map[string][]byte, ips []string, events []*models.DeviceUpdate) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(devices))
	events = make([]*models.DeviceUpdate, 0, len(devices))

	now := time.Now()

	for i := range devices {
		d := &devices[i]

		// Process enriched device for KV storage
		enrichedData, err := a.createEnrichedDeviceData(d, deviceLabels[d.ID])
		if err != nil {
			a.Logger.Error().
				Err(err).
				Int("device_id", d.ID).
				Msg("Failed to create enriched device data")

			continue
		}

		data[fmt.Sprintf("%d", d.ID)] = enrichedData

		// Extract IP and create device update event
		ip := extractFirstIP(d.IPAddress)
		if ip == "" {
			continue
		}

		event := a.createDeviceUpdateEvent(d, ip, deviceLabels[d.ID], now)

		// Marshal event for KV storage
		kvKey := fmt.Sprintf("%s/%s", a.Config.AgentID, ip)

		eventData, err := json.Marshal(event)
		if err != nil {
			a.Logger.Error().
				Err(err).
				Int("device_id", d.ID).
				Msg("Failed to marshal device event")

			continue
		}

		data[kvKey] = eventData

		events = append(events, event)
		ips = append(ips, ip+"/32")
	}

	return data, ips, events
}

// createEnrichedDeviceData creates enriched device data for KV storage
func (*ArmisIntegration) createEnrichedDeviceData(d *Device, queryLabel string) ([]byte, error) {
	tag := ""
	if len(d.Tags) > 0 {
		tag = strings.Join(d.Tags, ",")
	}

	enriched := DeviceWithMetadata{
		Device: *d,
		Metadata: map[string]string{
			"armis_device_id": fmt.Sprintf("%d", d.ID),
			"tag":             tag,
			"query_label":     queryLabel,
		},
	}

	return json.Marshal(enriched)
}

// createDeviceUpdateEvent creates a DeviceUpdate event from an Armis device
func (a *ArmisIntegration) createDeviceUpdateEvent(d *Device, ip, queryLabel string, timestamp time.Time) *models.DeviceUpdate {
	tag := ""
	if len(d.Tags) > 0 {
		tag = strings.Join(d.Tags, ",")
	}

	hostname := d.Name
	mac := d.MacAddress
	deviceID := fmt.Sprintf("%s:%s", a.Config.Partition, ip)

	event := &models.DeviceUpdate{
		AgentID:   a.Config.AgentID,
		PollerID:  a.Config.PollerID,
		Source:    models.DiscoverySourceArmis,
		DeviceID:  deviceID,
		Partition: a.Config.Partition,
		IP:        ip,
		MAC:       &mac,
		Hostname:  &hostname,
		Timestamp: timestamp,
		Metadata: map[string]string{
			"integration_type": "armis",
			"integration_id":   fmt.Sprintf("%d", d.ID),
			"armis_device_id":  fmt.Sprintf("%d", d.ID),
			"tag":              tag,
			"query_label":      queryLabel,
		},
	}

	return event
}
