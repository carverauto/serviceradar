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
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
)

// Fetch retrieves devices from NetBox for discovery purposes only.
// This method focuses purely on data discovery and does not perform state reconciliation.
func (n *NetboxIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.DeviceUpdate, error) {
	resp, err := n.fetchDevices(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer n.closeResponse(resp)

	deviceResp, err := n.decodeResponse(resp)
	if err != nil {
		return nil, nil, err
	}

	// Process current devices from Netbox API
	data, ips, currentEvents := n.processDevices(deviceResp)

	logger.Info().
		Int("devices_discovered", len(deviceResp.Results)).
		Int("sweep_results_generated", len(currentEvents)).
		Msg("Completed NetBox discovery operation")

	n.writeSweepConfig(ctx, ips)

	// Return the data for both KV store and sweep agents
	return data, currentEvents, nil
}

// Reconcile performs state reconciliation operations for NetBox.
// This method generates retraction events for devices that no longer exist in NetBox.
// It should only be called after sweep operations have completed.
func (n *NetboxIntegration) Reconcile(ctx context.Context) error {
	if n.Querier == nil {
		logger.Info().Msg("NetBox querier not configured, skipping reconciliation")
		return nil
	}

	logger.Info().Msg("Starting NetBox reconciliation operation")

	// Get current device states from ServiceRadar
	existingRadarDevices, err := n.Querier.GetDeviceStatesBySource(ctx, "netbox")
	if err != nil {
		logger.Error().
			Err(err).
			Str("source", "netbox").
			Msg("Failed to query existing Netbox devices from ServiceRadar during reconciliation")

		return err
	}

	if len(existingRadarDevices) == 0 {
		logger.Info().Msg("No existing NetBox device states found, skipping reconciliation")
		return nil
	}

	logger.Info().
		Int("device_count", len(existingRadarDevices)).
		Str("source", "netbox").
		Msg("Successfully queried device states from ServiceRadar for reconciliation")

	// Fetch current devices from NetBox to identify retractions
	resp, err := n.fetchDevices(ctx)
	if err != nil {
		logger.Error().
			Err(err).
			Msg("Failed to fetch current devices from NetBox during reconciliation")

		return err
	}
	defer n.closeResponse(resp)

	deviceResp, err := n.decodeResponse(resp)
	if err != nil {
		logger.Error().
			Err(err).
			Msg("Failed to decode NetBox response during reconciliation")

		return err
	}

	// Process current devices to get current events
	_, _, currentEvents := n.processDevices(deviceResp)

	// Generate retraction events
	retractionEvents := n.generateRetractionEvents(currentEvents, existingRadarDevices)

	if len(retractionEvents) > 0 {
		logger.Info().
			Int("retraction_count", len(retractionEvents)).
			Str("source", "netbox").
			Msg("Generated retraction events during reconciliation")

		// Send retraction events to the core service
		if n.ResultSubmitter != nil {
			if err := n.ResultSubmitter.SubmitBatchSweepResults(ctx, retractionEvents); err != nil {
				logger.Error().
					Err(err).
					Int("retraction_count", len(retractionEvents)).
					Msg("Failed to submit retraction events to core service")

				return err
			}

			logger.Info().
				Int("retraction_count", len(retractionEvents)).
				Msg("Successfully submitted retraction events to core service")
		} else {
			logger.Warn().
				Int("retraction_count", len(retractionEvents)).
				Msg("ResultSubmitter not configured, retraction events not sent")
		}
	} else {
		logger.Info().Msg("No retraction events needed for NetBox reconciliation")
	}

	logger.Info().Msg("Successfully completed NetBox reconciliation")

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
			logger.Info().
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
					"_deleted": "true",
				},
				AgentID:   n.Config.AgentID,
				PollerID:  n.Config.PollerID,
				Partition: n.Config.Partition,
			}

			retractionEvents = append(retractionEvents, retractionEvent)
		}
	}

	return retractionEvents
}

// fetchDevices sends the HTTP request to the NetBox API.
func (n *NetboxIntegration) fetchDevices(ctx context.Context) (*http.Response, error) {
	url := n.Config.Endpoint + "/api/dcim/devices/"

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

// closeResponse closes the HTTP response body, logging any errors.
func (*NetboxIntegration) closeResponse(resp *http.Response) {
	if err := resp.Body.Close(); err != nil {
		logger.Warn().
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

// processDevices converts devices to KV data, extracts IPs, and returns the list of devices.
func (n *NetboxIntegration) processDevices(deviceResp DeviceResponse) (data map[string][]byte, ips []string, events []*models.DeviceUpdate) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(deviceResp.Results))
	events = make([]*models.DeviceUpdate, 0, len(deviceResp.Results))

	agentID := n.Config.AgentID
	pollerID := n.Config.PollerID
	partition := n.Config.Partition

	now := time.Now()

	for i := range deviceResp.Results {
		var err error

		device := &deviceResp.Results[i]

		if device.PrimaryIP4.Address == "" {
			continue
		}

		ip, _, err := net.ParseCIDR(device.PrimaryIP4.Address)
		if err != nil {
			logger.Warn().
				Err(err).
				Str("ip_address", device.PrimaryIP4.Address).
				Msg("Failed to parse IP address")

			continue
		}

		ipStr := ip.String()

		if n.ExpandSubnets {
			ips = append(ips, device.PrimaryIP4.Address)
		} else {
			ips = append(ips, fmt.Sprintf("%s/32", ipStr))
		}

		kvKey := fmt.Sprintf("%s/%s", agentID, ipStr)

		metadata := map[string]interface{}{
			"netbox_device_id": fmt.Sprintf("%d", device.ID),
			"role":             device.Role.Name,
			"site":             device.Site.Name,
		}

		// Create discovery event (sweep result style)
		hostname := device.Name
		deviceID := fmt.Sprintf("%s:%s", partition, ipStr)

		event := &models.DeviceUpdate{
			AgentID:   agentID,
			PollerID:  pollerID,
			Source:    models.DiscoverySourceNetbox,
			DeviceID:  deviceID,
			Partition: partition,
			IP:        ipStr,
			Hostname:  &hostname,
			Timestamp: now,
			Metadata: map[string]string{
				"integration_type": "netbox",
				"integration_id":   fmt.Sprintf("%d", device.ID),
			},
		}

		for k, v := range metadata {
			if str, ok := v.(string); ok {
				event.Metadata[k] = str
			} else {
				event.Metadata[k] = fmt.Sprintf("%v", v)
			}
		}

		var metaJSON []byte

		if metaJSON, err = json.Marshal(event.Metadata); err == nil {
			logger.Debug().
				Str("metadata", string(metaJSON)).
				Msg("SweepResult metadata")
		}

		value, err := json.Marshal(event)
		if err != nil {
			logger.Error().
				Err(err).
				Int("device_id", device.ID).
				Msg("Failed to marshal device")

			continue
		}

		data[kvKey] = value
		// Add the consistently created device to the slice to be returned.
		events = append(events, event)
	}

	return data, ips, events
}

// writeSweepConfig generates and writes the sweep Config to KV.
func (n *NetboxIntegration) writeSweepConfig(ctx context.Context, ips []string) {
	if n.KvClient == nil {
		logger.Warn().Msg("KV client not configured; skipping sweep config write")
		return
	}

	// AgentID to be used for the sweep config key.
	// We prioritize the agent_id set on the source config itself.
	agentIDForConfig := n.Config.AgentID
	if agentIDForConfig == "" {
		// As a fallback, we could use ServerName, but logging a warning is better
		// to encourage explicit configuration.
		logger.Warn().
			Str("source", "netbox").
			Msg("agent_id not set for Netbox source. Sweep config key may be incorrect")
		// If you need a fallback, you can use: agentIDForConfig = n.ServerName

		return // Or simply return to avoid writing a config with an unpredictable key
	}

	interval := n.Config.SweepInterval
	if interval == "" {
		interval = "5m"
	}

	sweepConfig := models.SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3389, 445, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      interval,
		Concurrency:   50,
		Timeout:       "10s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")

		return
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", agentIDForConfig)
	_, err = n.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	logger.Info().
		Str("config_key", configKey).
		Str("config", string(configJSON)).
		Msg("Writing sweep config")

	if err != nil {
		logger.Error().
			Err(err).
			Str("config_key", configKey).
			Msg("Failed to write sweep config")

		return
	}

	logger.Info().
		Str("config_key", configKey).
		Msg("Successfully wrote sweep config")
}
