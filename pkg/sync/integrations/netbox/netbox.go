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

// Fetch retrieves devices from NetBox and generates sweep config.
func (n *NetboxIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.SweepResult, error) {
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

	allEvents := currentEvents

	// Add retraction logic if querier is available
	if n.Querier != nil {
		existingRadarDevices, err := n.Querier.GetDeviceStatesBySource(ctx, "netbox")
		if err != nil {
			logger.Warn().
				Err(err).
				Str("source", "netbox").
				Msg("Failed to query existing Netbox devices from ServiceRadar, skipping retraction")
		} else {
			logger.Info().
				Int("device_count", len(existingRadarDevices)).
				Str("source", "netbox").
				Msg("Successfully queried device states from ServiceRadar")

			retractionEvents := n.generateRetractionEvents(currentEvents, existingRadarDevices)

			if len(retractionEvents) > 0 {
				logger.Info().
					Int("retraction_count", len(retractionEvents)).
					Str("source", "netbox").
					Msg("Generated retraction events")

				allEvents = append(allEvents, retractionEvents...)
			}
		}
	}

	logger.Info().
		Int("device_count", len(deviceResp.Results)).
		Str("source", "netbox").
		Msg("Fetched devices from NetBox")

	n.writeSweepConfig(ctx, ips)

	// Return the consistent data for both KV store and NATS publishing.
	return data, allEvents, nil
}

// generateRetractionEvents checks for devices that exist in ServiceRadar but not in the current Netbox fetch.
func (n *NetboxIntegration) generateRetractionEvents(
	currentEvents []*models.SweepResult, existingDeviceStates []DeviceState) []*models.SweepResult {
	// Create a map of current device IDs from the Netbox API for efficient lookup.
	currentDeviceIDs := make(map[string]struct{}, len(currentEvents))

	for _, event := range currentEvents {
		if integrationID, ok := event.Metadata["integration_id"]; ok {
			currentDeviceIDs[integrationID] = struct{}{}
		}
	}

	var retractionEvents []*models.SweepResult

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

			retractionEvent := &models.SweepResult{
				DeviceID:        state.DeviceID,
				DiscoverySource: "netbox",
				IP:              state.IP,
				Available:       false,
				Timestamp:       now,
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
func (n *NetboxIntegration) processDevices(deviceResp DeviceResponse) (data map[string][]byte, ips []string, events []*models.SweepResult) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(deviceResp.Results))
	events = make([]*models.SweepResult, 0, len(deviceResp.Results))

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

		event := &models.SweepResult{
			AgentID:         agentID,
			PollerID:        pollerID,
			Partition:       partition,
			DeviceID:        deviceID,
			DiscoverySource: "netbox",
			IP:              ipStr,
			Hostname:        &hostname,
			Timestamp:       now,
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
