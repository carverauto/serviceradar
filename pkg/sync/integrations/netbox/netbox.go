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

package netbox

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
)

// parseTCPPorts parses TCP ports from the config credentials.
// It looks for a "tcp_ports" credential containing comma-separated port numbers.
// If not found or invalid, returns the default NetBox ports.
func parseTCPPorts(config *models.SourceConfig) []int {
	defaultPorts := []int{22, 80, 443, 3389, 445, 5985, 5986, 8080}

	portsStr, ok := config.Credentials["tcp_ports"]
	if !ok || portsStr == "" {
		return defaultPorts
	}

	var ports []int

	for _, portStr := range strings.Split(portsStr, ",") {
		portStr = strings.TrimSpace(portStr)
		if port, err := strconv.Atoi(portStr); err == nil && port > 0 && port <= 65535 {
			ports = append(ports, port)
		}
	}

	// If no valid ports were parsed, return defaults
	if len(ports) == 0 {
		return defaultPorts
	}

	return ports
}

// Fetch retrieves devices from NetBox for discovery purposes only.
// This method focuses purely on data discovery and does not perform state reconciliation.
func (n *NetboxIntegration) Fetch(ctx context.Context) ([]*models.DeviceUpdate, error) {
	deviceResp, deviceCount, pagesFetched, err := n.fetchAllDevices(ctx)
	if err != nil {
		return nil, err
	}

	// Process current devices from Netbox API
	currentEvents := n.processDevices(ctx, deviceResp)

	n.Logger.Info().
		Int("devices_discovered", len(deviceResp.Results)).
		Int("devices_reported_by_netbox", deviceCount).
		Int("pages_fetched", pagesFetched).
		Int("sweep_results_generated", len(currentEvents)).
		Msg("Completed NetBox discovery operation")

	return currentEvents, nil
}

// Reconcile performs state reconciliation operations for NetBox.
// This method generates retraction events for devices that no longer exist in NetBox.
// It should only be called after sweep operations have completed.
func (n *NetboxIntegration) Reconcile(ctx context.Context) error {
	if n.Querier == nil {
		n.Logger.Info().Msg("NetBox querier not configured, skipping reconciliation")
		return nil
	}

	n.Logger.Info().Msg("Starting NetBox reconciliation operation")

	// Get current device states from ServiceRadar
	existingRadarDevices, err := n.Querier.GetDeviceStatesBySource(ctx, "netbox")
	if err != nil {
		n.Logger.Error().
			Err(err).
			Str("source", "netbox").
			Msg("Failed to query existing Netbox devices from ServiceRadar during reconciliation")

		return err
	}

	if len(existingRadarDevices) == 0 {
		n.Logger.Info().Msg("No existing NetBox device states found, skipping reconciliation")
		return nil
	}

	n.Logger.Info().
		Int("device_count", len(existingRadarDevices)).
		Str("source", "netbox").
		Msg("Successfully queried device states from ServiceRadar for reconciliation")

	// Fetch current devices from NetBox to identify retractions
	deviceResp, deviceCount, pagesFetched, err := n.fetchAllDevices(ctx)
	if err != nil {
		n.Logger.Error().
			Err(err).
			Msg("Failed to fetch current devices from NetBox during reconciliation")

		return err
	}

	// Process current devices to get current events
	currentEvents := n.processDevices(ctx, deviceResp)

	n.Logger.Info().
		Int("devices_discovered", len(deviceResp.Results)).
		Int("devices_reported_by_netbox", deviceCount).
		Int("pages_fetched", pagesFetched).
		Msg("Fetched current NetBox inventory for reconciliation")

	// Generate retraction events
	retractionEvents := n.generateRetractionEvents(currentEvents, existingRadarDevices)

	if len(retractionEvents) > 0 {
		n.Logger.Info().
			Int("retraction_count", len(retractionEvents)).
			Str("source", "netbox").
			Msg("Generated retraction events during reconciliation")

		// Send retraction events to the core service
		if n.ResultSubmitter != nil {
			if err := n.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents); err != nil {
				n.Logger.Error().
					Err(err).
					Int("retraction_count", len(retractionEvents)).
					Msg("Failed to submit retraction events to core service")

				return err
			}

			n.Logger.Info().
				Int("retraction_count", len(retractionEvents)).
				Msg("Successfully submitted retraction events to core service")
		} else {
			n.Logger.Warn().
				Int("retraction_count", len(retractionEvents)).
				Msg("ResultSubmitter not configured, retraction events not sent")
		}
	} else {
		n.Logger.Info().Msg("No retraction events needed for NetBox reconciliation")
	}

	n.Logger.Info().Msg("Successfully completed NetBox reconciliation")

	return nil
}

// generateRetractionEvents checks for devices that exist in ServiceRadar but not in the current Netbox fetch.
func (n *NetboxIntegration) generateRetractionEvents(
	currentEvents []*models.DeviceUpdate, existingDeviceStates []DeviceState) []*models.DeviceUpdate {
	// Create a map of current device IDs from the Netbox API for efficient lookup.
	currentDeviceIDs := make(map[string]struct{}, len(currentEvents))

	for _, event := range currentEvents {
		if integrationID, ok := event.Metadata["integration_id"]; ok {
			currentDeviceIDs[integrationID] = struct{}{}
		}
	}

	var retractionEvents []*models.DeviceUpdate

	now := time.Now()

	for _, state := range existingDeviceStates {
		// Extract the original integration_id from the metadata.
		netboxID, ok := state.Metadata["integration_id"].(string)
		if !ok {
			continue // Cannot determine retraction status.
		}

		// If a device that was previously discovered is not in the current list, it's considered retracted.
		if _, found := currentDeviceIDs[netboxID]; !found {
			n.Logger.Info().
				Str("netbox_id", netboxID).
				Str("ip", state.IP).
				Msg("Device no longer detected, generating retraction event")

			retractionEvent := &models.DeviceUpdate{
				DeviceID:    state.DeviceID,
				Source:      models.DiscoverySourceNetbox,
				IP:          state.IP,
				IsAvailable: false,
				Timestamp:   now,
				Metadata: map[string]string{
					"_deleted":         "true",
					"sync_service_id":  n.Config.SyncServiceID,
					"tenant_id":        n.Config.TenantID,
					"tenant_slug":      n.Config.TenantSlug,
				},
				AgentID:   n.Config.AgentID,
				GatewayID:  n.Config.GatewayID,
				Partition: n.Config.Partition,
			}

			retractionEvents = append(retractionEvents, retractionEvent)
		}
	}

	return retractionEvents
}

func (n *NetboxIntegration) fetchDevicesFromURL(ctx context.Context, url string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Token "+n.Config.Credentials["api_token"])
	req.Header.Set("Accept", "application/json")

	// Create a custom HTTP client with TLS configuration
	//nolint:gosec // Allow insecure TLS configuration for testing purposes
	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: n.Config.InsecureSkipVerify,
			},
		},
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode != http.StatusOK {
		err := resp.Body.Close()
		if err != nil {
			return nil, err
		}

		return nil, fmt.Errorf("%w: %d", errUnexpectedStatusCode, resp.StatusCode)
	}

	return resp, nil
}

func (n *NetboxIntegration) resolveNextURL(currentURL, nextURL string) (string, error) {
	nextParsed, err := neturl.Parse(nextURL)
	if err != nil {
		return "", fmt.Errorf("parse next url: %w", err)
	}

	if nextParsed.IsAbs() {
		return nextParsed.String(), nil
	}

	currentParsed, err := neturl.Parse(currentURL)
	if err != nil {
		return "", fmt.Errorf("parse current url: %w", err)
	}

	return currentParsed.ResolveReference(nextParsed).String(), nil
}

func (n *NetboxIntegration) fetchAllDevices(ctx context.Context) (DeviceResponse, int, int, error) {
	firstURL := n.Config.Endpoint + "/api/dcim/devices/"

	var allDevices []Device

	deviceCount := 0
	pagesFetched := 0
	nextURL := firstURL

	for nextURL != "" {
		pagesFetched++

		resp, err := n.fetchDevicesFromURL(ctx, nextURL)
		if err != nil {
			return DeviceResponse{}, 0, pagesFetched, err
		}

		deviceResp, err := n.decodeResponse(resp)
		n.closeResponse(resp)
		if err != nil {
			return DeviceResponse{}, 0, pagesFetched, err
		}

		if pagesFetched == 1 {
			deviceCount = deviceResp.Count
		}

		allDevices = append(allDevices, deviceResp.Results...)

		nextURL = ""
		if deviceResp.Next != nil && *deviceResp.Next != "" {
			resolved, err := n.resolveNextURL(resp.Request.URL.String(), *deviceResp.Next)
			if err != nil {
				return DeviceResponse{}, 0, pagesFetched, err
			}
			nextURL = resolved
		}
	}

	return DeviceResponse{
		Results: allDevices,
		Count:   deviceCount,
	}, deviceCount, pagesFetched, nil
}

// closeResponse closes the HTTP response body, logging any errors.
func (n *NetboxIntegration) closeResponse(resp *http.Response) {
	if err := resp.Body.Close(); err != nil {
		n.Logger.Warn().
			Err(err).
			Msg("Failed to close response body")
	}
}

// decodeResponse decodes the HTTP response into a DeviceResponse.
func (*NetboxIntegration) decodeResponse(resp *http.Response) (DeviceResponse, error) {
	var deviceResp DeviceResponse

	if err := json.NewDecoder(resp.Body).Decode(&deviceResp); err != nil {
		return DeviceResponse{}, err
	}

	return deviceResp, nil
}

// processDevices converts NetBox devices to DeviceUpdate events.
type netboxDeviceContext struct {
	device *Device
	event  *models.DeviceUpdate
}

func (n *NetboxIntegration) processDevices(_ context.Context, deviceResp DeviceResponse) (
	events []*models.DeviceUpdate,
) {
	events = make([]*models.DeviceUpdate, 0, len(deviceResp.Results))

	agentID := n.Config.AgentID
	gatewayID := n.Config.GatewayID
	partition := n.Config.Partition

	contexts := make([]netboxDeviceContext, 0, len(deviceResp.Results))

	now := time.Now()

	for i := range deviceResp.Results {
		var err error

		device := &deviceResp.Results[i]

		if device.PrimaryIP4.Address == "" {
			continue
		}

		ip, _, err := net.ParseCIDR(device.PrimaryIP4.Address)
		if err != nil {
			n.Logger.Warn().
				Err(err).
				Str("ip_address", device.PrimaryIP4.Address).
				Msg("Failed to parse IP address")

			continue
		}

		ipStr := ip.String()

		metadata := map[string]interface{}{
			"netbox_device_id": fmt.Sprintf("%d", device.ID),
			"role":             device.Role.Name,
			"site":             device.Site.Name,
		}

		hostname := device.Name
		deviceID := fmt.Sprintf("%s:%s", partition, ipStr)

		event := &models.DeviceUpdate{
			AgentID:   agentID,
			GatewayID:  gatewayID,
			Source:    models.DiscoverySourceNetbox,
			DeviceID:  deviceID,
			Partition: partition,
			IP:        ipStr,
			Hostname:  &hostname,
			Timestamp: now,
			Metadata: map[string]string{
				"integration_type":  "netbox",
				"integration_id":    fmt.Sprintf("%d", device.ID),
				"sync_service_id":   n.Config.SyncServiceID,
				"tenant_id":         n.Config.TenantID,
				"tenant_slug":       n.Config.TenantSlug,
			},
		}

		for k, v := range metadata {
			if str, ok := v.(string); ok {
				event.Metadata[k] = str
			} else {
				event.Metadata[k] = fmt.Sprintf("%v", v)
			}
		}

		contexts = append(contexts, netboxDeviceContext{
			device: device,
			event:  event,
		})
	}

	for _, ctxDevice := range contexts {
		metaJSON, err := json.Marshal(ctxDevice.event.Metadata)
		if err == nil {
			n.Logger.Debug().
				Str("metadata", string(metaJSON)).
				Msg("SweepResult metadata")
		}

		events = append(events, ctxDevice.event)
	}

	return events
}
