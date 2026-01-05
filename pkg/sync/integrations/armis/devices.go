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
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
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
			if !strings.Contains(err.Error(), "401") || !strings.Contains(err.Error(), "Invalid access token") {
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

type aggregatedDeviceEntry struct {
	device     Device
	ipSet      map[string]struct{}
	ipOrder    []string
	labelSet   map[string]struct{}
	labels     []string
	sweepModes map[models.SweepMode]struct{}
}

func newAggregatedDeviceEntry(device Device, query models.QueryConfig) *aggregatedDeviceEntry {
	entry := &aggregatedDeviceEntry{
		device: Device{
			ID:               device.ID,
			IPAddress:        device.IPAddress,
			MacAddress:       device.MacAddress,
			Name:             device.Name,
			Type:             device.Type,
			Category:         device.Category,
			Manufacturer:     device.Manufacturer,
			Model:            device.Model,
			OperatingSystem:  device.OperatingSystem,
			FirstSeen:        device.FirstSeen,
			LastSeen:         device.LastSeen,
			RiskLevel:        device.RiskLevel,
			Boundaries:       device.Boundaries,
			Tags:             append([]string(nil), device.Tags...),
			CustomProperties: device.CustomProperties,
			BusinessImpact:   device.BusinessImpact,
			Visibility:       device.Visibility,
			Site:             device.Site,
		},
		ipSet:      make(map[string]struct{}),
		ipOrder:    make([]string, 0, 4),
		labelSet:   make(map[string]struct{}),
		labels:     make([]string, 0, 1),
		sweepModes: make(map[models.SweepMode]struct{}),
	}

	entry.mergeIPs(device.IPAddress)
	entry.addQuery(query)
	return entry
}

func (e *aggregatedDeviceEntry) mergeDevice(device Device) {
	e.mergeIPs(device.IPAddress)

	mergeStringIfEmpty(&e.device.MacAddress, device.MacAddress)
	mergeStringIfEmpty(&e.device.Name, device.Name)
	mergeStringIfEmpty(&e.device.Type, device.Type)
	mergeStringIfEmpty(&e.device.Category, device.Category)
	mergeStringIfEmpty(&e.device.Manufacturer, device.Manufacturer)
	mergeStringIfEmpty(&e.device.Model, device.Model)
	mergeStringIfEmpty(&e.device.OperatingSystem, device.OperatingSystem)
	updateToLatest(&e.device.LastSeen, device.LastSeen)
	updateToEarliest(&e.device.FirstSeen, device.FirstSeen)
	mergeStringIfEmpty(&e.device.Boundaries, device.Boundaries)
	mergeStringIfEmpty(&e.device.BusinessImpact, device.BusinessImpact)
	mergeStringIfEmpty(&e.device.Visibility, device.Visibility)
	setInterfaceIfNil(&e.device.CustomProperties, device.CustomProperties)
	setInterfaceIfNil(&e.device.Site, device.Site)
	e.mergeTags(device.Tags)
}

func (e *aggregatedDeviceEntry) mergeIPs(ipList string) {
	for _, ip := range extractAllIPs(ipList) {
		trimmed := strings.TrimSpace(ip)
		if trimmed == "" {
			continue
		}
		if _, exists := e.ipSet[trimmed]; exists {
			continue
		}
		e.ipSet[trimmed] = struct{}{}
		e.ipOrder = append(e.ipOrder, trimmed)
	}

	if len(e.ipOrder) == 0 {
		return
	}

	e.device.IPAddress = strings.Join(e.ipOrder, ",")
}

func (e *aggregatedDeviceEntry) mergeTags(tags []string) {
	if len(tags) == 0 {
		return
	}

	existing := make(map[string]struct{}, len(e.device.Tags))
	for _, tag := range e.device.Tags {
		existing[tag] = struct{}{}
	}

	for _, tag := range tags {
		trimmed := strings.TrimSpace(tag)
		if trimmed == "" {
			continue
		}
		if _, ok := existing[trimmed]; ok {
			continue
		}
		existing[trimmed] = struct{}{}
		e.device.Tags = append(e.device.Tags, trimmed)
	}
}

func mergeStringIfEmpty(dst *string, candidate string) {
	if dst == nil || *dst != "" || candidate == "" {
		return
	}
	*dst = candidate
}

func updateToLatest(dst *time.Time, candidate time.Time) {
	if dst == nil || candidate.IsZero() {
		return
	}
	current := *dst
	if current.IsZero() || candidate.After(current) {
		*dst = candidate
	}
}

func updateToEarliest(dst *time.Time, candidate time.Time) {
	if dst == nil || candidate.IsZero() {
		return
	}
	current := *dst
	if current.IsZero() || candidate.Before(current) {
		*dst = candidate
	}
}

func setInterfaceIfNil(dst *interface{}, candidate interface{}) {
	if dst == nil || *dst != nil || candidate == nil {
		return
	}
	*dst = candidate
}

func (e *aggregatedDeviceEntry) addQuery(query models.QueryConfig) {
	if query.Label != "" {
		if _, exists := e.labelSet[query.Label]; !exists {
			e.labelSet[query.Label] = struct{}{}
			e.labels = append(e.labels, query.Label)
		}
	}

	for _, mode := range query.SweepModes {
		if mode == "" {
			continue
		}
		e.sweepModes[mode] = struct{}{}
	}
}

func (e *aggregatedDeviceEntry) labelSummary() string {
	if len(e.labels) == 0 {
		return ""
	}

	sorted := append([]string(nil), e.labels...)
	sort.Strings(sorted)
	return strings.Join(sorted, ",")
}

func (e *aggregatedDeviceEntry) sweepModeSlice() []models.SweepMode {
	if len(e.sweepModes) == 0 {
		return nil
	}

	names := make([]string, 0, len(e.sweepModes))
	for mode := range e.sweepModes {
		names = append(names, string(mode))
	}

	sort.Strings(names)

	result := make([]models.SweepMode, 0, len(names))
	for _, name := range names {
		result = append(result, models.SweepMode(name))
	}

	return result
}

type deviceAggregator struct {
	entries map[int]*aggregatedDeviceEntry
}

func newDeviceAggregator() *deviceAggregator {
	return &deviceAggregator{
		entries: make(map[int]*aggregatedDeviceEntry),
	}
}

func (agg *deviceAggregator) addDevices(devices []Device, query models.QueryConfig) {
	for i := range devices {
		agg.addDevice(devices[i], query)
	}
}

func (agg *deviceAggregator) addDevice(device Device, query models.QueryConfig) {
	if agg.entries == nil {
		agg.entries = make(map[int]*aggregatedDeviceEntry)
	}

	if entry, exists := agg.entries[device.ID]; exists {
		entry.mergeDevice(device)
		entry.addQuery(query)
		return
	}

	agg.entries[device.ID] = newAggregatedDeviceEntry(device, query)
}

func (agg *deviceAggregator) materialize() ([]Device, map[int]string, map[int]models.QueryConfig) {
	if len(agg.entries) == 0 {
		return nil, map[int]string{}, map[int]models.QueryConfig{}
	}

	deviceIDs := make([]int, 0, len(agg.entries))
	for id := range agg.entries {
		deviceIDs = append(deviceIDs, id)
	}
	sort.Ints(deviceIDs)

	allDevices := make([]Device, 0, len(deviceIDs))
	deviceLabels := make(map[int]string, len(deviceIDs))
	deviceQueries := make(map[int]models.QueryConfig, len(deviceIDs))

	for _, id := range deviceIDs {
		entry := agg.entries[id]
		label := entry.labelSummary()
		if label == "" {
			label = "armis_devices"
		}

		allDevices = append(allDevices, entry.device)
		deviceLabels[id] = label
		deviceQueries[id] = models.QueryConfig{
			Label:      label,
			SweepModes: entry.sweepModeSlice(),
		}
	}

	return allDevices, deviceLabels, deviceQueries
}

func (agg *deviceAggregator) len() int {
	if agg == nil {
		return 0
	}
	return len(agg.entries)
}

// parseBlacklistNetworks parses the blacklist CIDRs and returns valid networks
func (a *ArmisIntegration) parseBlacklistNetworks() []*net.IPNet {
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

	return blacklistNetworks
}

// isIPBlacklisted checks if an IP is contained in any of the blacklist networks
func (*ArmisIntegration) isIPBlacklisted(ipStr string, blacklistNetworks []*net.IPNet) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	for _, network := range blacklistNetworks {
		if network.Contains(ip) {
			return true
		}
	}

	return false
}

// applyBlacklistFiltering filters out devices based on the network blacklist.
func (a *ArmisIntegration) applyBlacklistFiltering(
	events []*models.DeviceUpdate,
) (filteredEvents []*models.DeviceUpdate) {
	if len(a.Config.NetworkBlacklist) == 0 {
		return events
	}

	a.Logger.Info().
		Int("original_device_count", len(events)).
		Strs("blacklist_cidrs", a.Config.NetworkBlacklist).
		Msg("Applying network blacklist filtering to Armis devices")

	blacklistNetworks := a.parseBlacklistNetworks()
	filteredEvents = make([]*models.DeviceUpdate, 0, len(events))

	for _, event := range events {
		if a.isIPBlacklisted(event.IP, blacklistNetworks) {
			continue
		}
		filteredEvents = append(filteredEvents, event)
	}

	a.Logger.Info().
		Int("filtered_device_count", len(filteredEvents)).
		Int("filtered_out", len(events)-len(filteredEvents)).
		Msg("Applied network blacklist filtering to devices")

	return filteredEvents
}

// fetchAndProcessDevices is an unexported method that handles the core logic of fetching devices from Armis
// and processing them into DeviceUpdate events.
func (a *ArmisIntegration) fetchAndProcessDevices(ctx context.Context) ([]*models.DeviceUpdate, []Device, error) {
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

	a.Logger.Info().
		Int("query_count", len(a.Config.Queries)).
		Msg("Starting device fetch for all queries - accumulating in memory before writing sweep config")

	deviceAgg := newDeviceAggregator()

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
			return nil, nil, queryErr
		}

		a.Logger.Info().
			Int("query_index", queryIndex).
			Str("query_label", q.Label).
			Int("query_device_count", len(devices)).
			Int("aggregated_device_count_before", deviceAgg.len()).
			Msg("Query completed, aggregating devices in memory")

		deviceAgg.addDevices(devices, q)

		a.Logger.Info().
			Int("query_index", queryIndex).
			Str("query_label", q.Label).
			Int("total_unique_devices", deviceAgg.len()).
			Msg("Devices accumulated from query")
	}

	allDevices, deviceLabels, _ := deviceAgg.materialize()

	a.Logger.Info().
		Int("total_unique_devices_from_all_queries", len(allDevices)).
		Int("total_queries_processed", len(a.Config.Queries)).
		Msg("All queries completed - processing aggregated devices")

	// Process devices with query labels and configs
	events := a.processDevices(ctx, allDevices, deviceLabels)

	a.Logger.Info().
		Int("total_devices", len(allDevices)).
		Int("total_events", len(events)).
		Msg("Device processing completed - applying blacklist filtering")

	// Apply blacklist filtering to devices before returning
	events = a.applyBlacklistFiltering(events)

	a.Logger.Info().
		Int("filtered_events", len(events)).
		Msg("Blacklist filtering completed")

	return events, allDevices, nil
}

// Fetch retrieves devices from Armis for discovery purposes only.
// This method focuses purely on data discovery and does not perform state reconciliation.
func (a *ArmisIntegration) Fetch(ctx context.Context) ([]*models.DeviceUpdate, error) {
	// Discovery: Fetch devices from Armis and create sweep configs
	events, devices, err := a.fetchAndProcessDevices(ctx)
	if err != nil {
		return nil, err
	}

	a.Logger.Info().
		Int("devices_discovered", len(devices)).
		Int("sweep_results_generated", len(events)).
		Msg("Completed Armis discovery operation")

	return events, nil
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
	defer func() { _ = resp.Body.Close() }()

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

// processDevices converts devices to DeviceUpdate events.
type armisDeviceContext struct {
	device    *Device
	label     string
	primaryIP string
	allIPs    []string
	event     *models.DeviceUpdate
}

func (a *ArmisIntegration) processDevices(
	_ context.Context,
	devices []Device,
	deviceLabels map[int]string,
) (events []*models.DeviceUpdate) {
	events = make([]*models.DeviceUpdate, 0, len(devices))

	contexts := make([]armisDeviceContext, 0, len(devices))
	now := time.Now()

	for i := range devices {
		d := &devices[i]

		allIPs := extractAllIPs(d.IPAddress)
		if len(allIPs) == 0 {
			a.Logger.Warn().
				Int("device_id", d.ID).
				Msg("Device has no IP addresses")

			continue
		}

		primaryIP := allIPs[0]
		event := a.createDeviceUpdateEventWithAllIPs(d, primaryIP, allIPs, deviceLabels[d.ID], now)

		contexts = append(contexts, armisDeviceContext{
			device:    d,
			label:     deviceLabels[d.ID],
			primaryIP: primaryIP,
			allIPs:    allIPs,
			event:     event,
		})
	}

	for _, ctxDevice := range contexts {
		events = append(events, ctxDevice.event)

		a.Logger.Debug().
			Int("device_id", ctxDevice.device.ID).
			Str("primary_ip", ctxDevice.primaryIP).
			Int("total_ips", len(ctxDevice.allIPs)).
			Strs("all_ips", ctxDevice.allIPs).
			Msg("Processed device with multiple IPs")
	}

	return events
}

// createDeviceUpdateEventWithAllIPs creates a DeviceUpdate event with all IP addresses in metadata
func (a *ArmisIntegration) createDeviceUpdateEventWithAllIPs(
	d *Device, primaryIP string, allIPs []string, queryLabel string, timestamp time.Time,
) *models.DeviceUpdate {
	tag := ""
	if len(d.Tags) > 0 {
		tag = strings.Join(d.Tags, ",")
	}

	hostname := d.Name
	rawMAC := extractPrimaryMAC(d.MacAddress)
	var macPtr *string
	if rawMAC != "" {
		macCopy := rawMAC
		macPtr = &macCopy
	}

	// Device ID is left empty - the registry's DeviceIdentityResolver will generate
	// a stable ServiceRadar UUID based on strong identifiers (MAC, armis_device_id).
	// This prevents duplicate devices when IP addresses change (DHCP churn).
	// The Armis device ID is stored in metadata as a strong identifier for merging.

	event := &models.DeviceUpdate{
		AgentID:   a.Config.AgentID,
		PollerID:  a.Config.PollerID,
		Source:    models.DiscoverySourceArmis,
		DeviceID:  "", // Let registry generate ServiceRadar UUID
		Partition: a.Config.Partition,
		IP:        primaryIP,
		MAC:       macPtr,
		Hostname:  &hostname,
		Timestamp: timestamp,
		Metadata: map[string]string{
			"integration_type": "armis",
			"integration_id":   fmt.Sprintf("%d", d.ID),
			"armis_device_id":  fmt.Sprintf("%d", d.ID), // Strong identifier for merging
			"tag":              tag,
			"query_label":      queryLabel,
			"primary_ip":       primaryIP,
			"all_ips":          strings.Join(allIPs, ","),
			"ip_count":         fmt.Sprintf("%d", len(allIPs)),
		},
	}

	return event
}

func extractPrimaryMAC(raw string) string {
	if raw == "" {
		return ""
	}

	parts := strings.FieldsFunc(raw, func(r rune) bool {
		switch r {
		case ',', ';', ' ', '\n', '\t':
			return true
		default:
			return false
		}
	})

	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}

		hw, err := net.ParseMAC(part)
		if err != nil {
			continue
		}

		return strings.ToUpper(hw.String())
	}

	return ""
}
