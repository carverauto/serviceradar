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
	"log"
	"net"
	"net/http"
	"time"

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

	// Call the refactored function and get all consistent data in one go.
	data, ips, events := n.processDevices(deviceResp)

	log.Printf("Fetched %d devices from NetBox", len(deviceResp.Results))

	n.writeSweepConfig(ctx, ips)

	// Return the consistent data for both KV store and NATS publishing.
	return data, events, nil
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
		log.Printf("Failed to close response body: %v", err)
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
		device := &deviceResp.Results[i]

		if device.PrimaryIP4.Address == "" {
			continue
		}

		ip, _, err := net.ParseCIDR(device.PrimaryIP4.Address)
		if err != nil {
			log.Printf("Failed to parse IP %s: %v", device.PrimaryIP4.Address, err)
			continue
		}

		ipStr := ip.String()

		if n.ExpandSubnets {
			ips = append(ips, device.PrimaryIP4.Address)
		} else {
			ips = append(ips, fmt.Sprintf("%s/32", ipStr))
		}

		kvKey := fmt.Sprintf("%s:%s", partition, ipStr)

		metadata := map[string]interface{}{
			"netbox_device_id": fmt.Sprintf("%d", device.ID),
			"role":             device.Role.Name,
			"site":             device.Site.Name,
		}

		// Create discovery event (sweep result style)
		hostname := device.Name
		event := &models.SweepResult{
			AgentID:         agentID,
			PollerID:        pollerID,
			Partition:       partition,
			DiscoverySource: "netbox",
			IP:              ipStr,
			Hostname:        &hostname,
			Timestamp:       now,
			Available:       true,
			Metadata:        map[string]string{},
		}

		for k, v := range metadata {
			if str, ok := v.(string); ok {
				event.Metadata[k] = str
			} else {
				event.Metadata[k] = fmt.Sprintf("%v", v)
			}
		}

		value, err := json.Marshal(event)
		if err != nil {
			log.Printf("Failed to marshal device %d: %v", device.ID, err)
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
		log.Print("KV client not configured; skipping sweep config write")
	}

	// AgentID to be used for the sweep config key.
	// We prioritize the agent_id set on the source config itself.
	agentIDForConfig := n.Config.AgentID
	if agentIDForConfig == "" {
		// As a fallback, we could use ServerName, but logging a warning is better
		// to encourage explicit configuration.
		log.Printf("Warning: agent_id not set for Netbox source. Sweep config key may be incorrect.")
		// If you need a fallback, you can use: agentIDForConfig = n.ServerName

		return // Or simply return to avoid writing a config with an unpredictable key
	}

	sweepConfig := models.SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3389, 445, 8080},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "5m",
		Concurrency:   50,
		Timeout:       "10s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}

	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		log.Printf("Failed to marshal sweep config: %v", err)

		return
	}

	// The key now uses the explicitly configured AgentID, making it predictable.
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", agentIDForConfig)
	_, err = n.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	// log the key/value pair for debugging
	log.Printf("Writing sweep config to %s: %s", configKey, string(configJSON))

	if err != nil {
		log.Printf("Failed to write sweep config to %s: %v", configKey, err)

		return
	}

	log.Printf("Wrote sweep config to %s", configKey)
}
