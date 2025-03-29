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
	"net/http"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
)

// Fetch retrieves devices from NetBox and generates sweep config.
func (n *NetboxIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	resp, err := n.fetchDevices(ctx)
	if err != nil {
		return nil, err
	}
	defer n.closeResponse(resp)

	deviceResp, err := n.decodeResponse(resp)
	if err != nil {
		return nil, err
	}

	data, ips := n.processDevices(deviceResp)

	log.Printf("Fetched %d devices from NetBox", len(deviceResp.Results))

	n.writeSweepConfig(ctx, ips)

	return data, nil
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

// processDevices converts devices to KV data and extracts IPs.
func (*NetboxIntegration) processDevices(deviceResp DeviceResponse) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(deviceResp.Results)) // Fixed: added length 0

	for i := range deviceResp.Results {
		device := &deviceResp.Results[i] // Take a pointer to avoid copying

		value, err := json.Marshal(device)
		if err != nil {
			log.Printf("Failed to marshal device %d: %v", device.ID, err)

			continue
		}

		data[fmt.Sprintf("%d", device.ID)] = value

		if device.PrimaryIP4.Address != "" {
			ips = append(ips, device.PrimaryIP4.Address)
		}
	}

	return data, ips
}

// writeSweepConfig generates and writes the sweep Config to KV.
func (n *NetboxIntegration) writeSweepConfig(ctx context.Context, ips []string) {
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

	configKey := fmt.Sprintf("config/%s/network-sweep", n.ServerName)
	_, err = n.KvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		log.Printf("Failed to write sweep config to %s: %v", configKey, err)

		return
	}

	log.Printf("Wrote sweep config to %s", configKey)
}
