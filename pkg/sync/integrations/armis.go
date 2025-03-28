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

package integrations

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// ArmisIntegration manages the Armis API integration.
type ArmisIntegration struct {
	config     models.SourceConfig
	kvClient   proto.KVServiceClient // Add gRPC client for KV writes
	grpcConn   *grpc.ClientConn      // Connection to reuse
	serverName string
}

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client.
func NewArmisIntegration(
	_ context.Context,
	config models.SourceConfig,
	kvClient proto.KVServiceClient,
	grpcConn *grpc.ClientConn,
	serverName string,
) *ArmisIntegration {
	return &ArmisIntegration{
		config:     config,
		kvClient:   kvClient,
		grpcConn:   grpcConn,
		serverName: serverName,
	}
}

// Device represents an Armis device.
type Device struct {
	DeviceID  string `json:"device_id"`
	IPAddress string `json:"ip_address"`
}

// DeviceResponse represents the Armis API response.
type DeviceResponse struct {
	Devices []Device `json:"devices"`
	Total   int      `json:"total"`
	Page    int      `json:"page"`
	PerPage int      `json:"per_page"`
}

// SweepConfig defines the network sweep tool configuration.
type SweepConfig struct {
	Networks      []string `json:"networks"`
	Ports         []int    `json:"ports"`
	SweepModes    []string `json:"sweep_modes"`
	Interval      string   `json:"interval"`
	Concurrency   int      `json:"concurrency"`
	Timeout       string   `json:"timeout"`
	IcmpCount     int      `json:"icmp_count"`
	HighPerfIcmp  bool     `json:"high_perf_icmp"`
	IcmpRateLimit int      `json:"icmp_rate_limit"`
}

var (
	errUnexpectedStatusCode = errors.New("unexpected status code")
)

// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	resp, err := a.fetchDevices(ctx)
	if err != nil {
		return nil, err
	}
	defer a.closeResponse(resp)

	deviceResp, err := a.decodeResponse(resp)
	if err != nil {
		return nil, err
	}

	data, ips := a.processDevices(deviceResp)

	log.Printf("Fetched %d devices from Armis", len(deviceResp.Devices))

	a.writeSweepConfig(ctx, ips)

	return data, nil
}

// fetchDevices sends the HTTP request to the Armis API.
func (a *ArmisIntegration) fetchDevices(ctx context.Context) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.config.Endpoint+"?page=1&per_page=10", http.NoBody)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+a.config.Credentials["api_key"])

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode != http.StatusOK {
		err := resp.Body.Close()
		if err != nil {
			return nil, err
		} // Close here since we won't defer in caller

		return nil, fmt.Errorf("%w: %d", errUnexpectedStatusCode, resp.StatusCode)
	}

	return resp, nil
}

// closeResponse closes the HTTP response body, logging any errors.
func (*ArmisIntegration) closeResponse(resp *http.Response) {
	if err := resp.Body.Close(); err != nil {
		log.Printf("Failed to close response body: %v", err)
	}
}

// decodeResponse decodes the HTTP response into a DeviceResponse.
func (*ArmisIntegration) decodeResponse(resp *http.Response) (DeviceResponse, error) {
	var deviceResp DeviceResponse

	if err := json.NewDecoder(resp.Body).Decode(&deviceResp); err != nil {
		return DeviceResponse{}, err
	}

	return deviceResp, nil
}

// processDevices converts devices to KV data and extracts IPs.
func (*ArmisIntegration) processDevices(deviceResp DeviceResponse) (data map[string][]byte, ips []string) {
	data = make(map[string][]byte)
	ips = make([]string, 0, len(deviceResp.Devices))

	for _, device := range deviceResp.Devices {
		value, err := json.Marshal(device)

		if err != nil {
			log.Printf("Failed to marshal device %s: %v", device.DeviceID, err)

			continue // Skip this device, don't fail entirely
		}

		data[device.DeviceID] = value

		ips = append(ips, device.IPAddress+"/32")
	}

	return data, ips
}

// writeSweepConfig generates and writes the sweep config to KV.
func (a *ArmisIntegration) writeSweepConfig(ctx context.Context, ips []string) {
	sweepConfig := SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3306, 5432, 6379, 8080, 8443},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "5m",
		Concurrency:   100,
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

	// Use serverName from sync.json for KV path
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", a.serverName)

	_, err = a.kvClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})
	if err != nil {
		log.Printf("Failed to write sweep config to %s: %v", configKey, err)

		return
	}

	log.Printf("Wrote sweep config to %s", configKey)
}
