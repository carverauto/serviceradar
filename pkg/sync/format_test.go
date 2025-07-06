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

package sync

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSweepResultToHostFormat tests the conversion from SweepResult to the host format expected by the core
func TestSweepResultToHostFormat(t *testing.T) {
	tests := []struct {
		name           string
		sweepResults   []*models.SweepResult
		expectedHosts  []map[string]interface{}
		expectedMsg    string
	}{
		{
			name:          "empty results",
			sweepResults:  []*models.SweepResult{},
			expectedHosts: []map[string]interface{}{},
			expectedMsg:   "No sync results available yet",
		},
		{
			name: "single host with all fields",
			sweepResults: []*models.SweepResult{
				{
					AgentID:         "test-agent",
					PollerID:        "test-poller", 
					Partition:       "default",
					DiscoverySource: "netbox",
					IP:              "192.168.1.10",
					MAC:             stringPtr("00:50:56:12:34:56"),
					Hostname:        stringPtr("web-server-01"),
					Timestamp:       time.Now(),
					Available:       true,
					Metadata: map[string]string{
						"netbox_device_id": "42",
						"role":             "web-servers",
						"site":             "datacenter-1",
						"rack":             "A1",
					},
				},
			},
			expectedHosts: []map[string]interface{}{
				{
					"host":      "192.168.1.10",
					"available": true,
					"mac":       "00:50:56:12:34:56",
					"hostname":  "web-server-01",
					"metadata": map[string]interface{}{
						"netbox_device_id": "42",
						"role":             "web-servers",
						"site":             "datacenter-1",
						"rack":             "A1",
					},
				},
			},
			expectedMsg: "Discovery sync completed",
		},
		{
			name: "host without MAC",
			sweepResults: []*models.SweepResult{
				{
					IP:              "192.168.1.11",
					MAC:             nil,
					Hostname:        stringPtr("no-mac-device"),
					Available:       true,
					Metadata: map[string]string{
						"type": "virtual",
					},
				},
			},
			expectedHosts: []map[string]interface{}{
				{
					"host":      "192.168.1.11",
					"available": true,
					"hostname":  "no-mac-device",
					"metadata": map[string]interface{}{
						"type": "virtual",
					},
				},
			},
			expectedMsg: "Discovery sync completed",
		},
		{
			name: "host without hostname",
			sweepResults: []*models.SweepResult{
				{
					IP:        "192.168.1.12",
					MAC:       stringPtr("00:50:56:78:90:12"),
					Hostname:  nil,
					Available: false,
					Metadata: map[string]string{
						"discovered_via": "ping",
					},
				},
			},
			expectedHosts: []map[string]interface{}{
				{
					"host":      "192.168.1.12",
					"available": false,
					"mac":       "00:50:56:78:90:12",
					"metadata": map[string]interface{}{
						"discovered_via": "ping",
					},
				},
			},
			expectedMsg: "Discovery sync completed",
		},
		{
			name: "multiple hosts from different sources",
			sweepResults: []*models.SweepResult{
				{
					IP:              "192.168.1.20",
					DiscoverySource: "netbox",
					Available:       true,
					Hostname:        stringPtr("netbox-device"),
					Metadata: map[string]string{
						"source": "netbox",
						"id":     "100",
					},
				},
				{
					IP:              "192.168.1.21",
					DiscoverySource: "armis",
					Available:       true,
					Hostname:        stringPtr("armis-device"),
					Metadata: map[string]string{
						"source": "armis",
						"risk":   "low",
					},
				},
			},
			expectedHosts: []map[string]interface{}{
				{
					"host":      "192.168.1.20",
					"available": true,
					"hostname":  "netbox-device",
					"metadata": map[string]interface{}{
						"source": "netbox",
						"id":     "100",
					},
				},
				{
					"host":      "192.168.1.21",
					"available": true,
					"hostname":  "armis-device",
					"metadata": map[string]interface{}{
						"source": "armis",
						"risk":   "low",
					},
				},
			},
			expectedMsg: "Discovery sync completed",
		},
		{
			name: "host with empty metadata",
			sweepResults: []*models.SweepResult{
				{
					IP:        "192.168.1.30",
					Available: true,
					Metadata:  map[string]string{},
				},
			},
			expectedHosts: []map[string]interface{}{
				{
					"host":      "192.168.1.30",
					"available": true,
					"metadata":  map[string]interface{}{},
				},
			},
			expectedMsg: "Discovery sync completed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			syncer := &SyncPoller{
				config: Config{
					AgentID: "test-agent",
				},
				lastSyncResults: tt.sweepResults,
			}

			req := &proto.StatusRequest{
				ServiceName: "test-sync",
				ServiceType: "sweep",
			}

			resp, err := syncer.GetStatus(context.Background(), req)
			require.NoError(t, err)
			assert.NotNil(t, resp)
			assert.True(t, resp.Available)
			assert.Equal(t, "sweep", resp.ServiceType)
			assert.Equal(t, "test-agent", resp.AgentId)

			// Parse the response message
			var response map[string]interface{}
			err = json.Unmarshal(resp.Message, &response)
			require.NoError(t, err)

			// Check message
			assert.Equal(t, tt.expectedMsg, response["message"])

			// Check hosts
			hosts, ok := response["hosts"].([]interface{})
			require.True(t, ok)
			assert.Len(t, hosts, len(tt.expectedHosts))

			for i, expectedHost := range tt.expectedHosts {
				actualHost, ok := hosts[i].(map[string]interface{})
				require.True(t, ok, "Host %d should be a map", i)

				// Check required fields
				assert.Equal(t, expectedHost["host"], actualHost["host"], "Host %d IP mismatch", i)
				assert.Equal(t, expectedHost["available"], actualHost["available"], "Host %d availability mismatch", i)

				// Check optional MAC field
				if expectedMAC, hasMAC := expectedHost["mac"]; hasMAC {
					assert.Equal(t, expectedMAC, actualHost["mac"], "Host %d MAC mismatch", i)
				} else {
					assert.NotContains(t, actualHost, "mac", "Host %d should not have MAC field", i)
				}

				// Check optional hostname field  
				if expectedHostname, hasHostname := expectedHost["hostname"]; hasHostname {
					assert.Equal(t, expectedHostname, actualHost["hostname"], "Host %d hostname mismatch", i)
				} else {
					assert.NotContains(t, actualHost, "hostname", "Host %d should not have hostname field", i)
				}

				// Check metadata
				expectedMeta := expectedHost["metadata"].(map[string]interface{})
				actualMeta, ok := actualHost["metadata"].(map[string]interface{})
				require.True(t, ok, "Host %d metadata should be a map", i)
				assert.Equal(t, expectedMeta, actualMeta, "Host %d metadata mismatch", i)
			}
		})
	}
}

// TestGetStatusResponseFormat tests that the response format matches what the core expects
func TestGetStatusResponseFormat(t *testing.T) {
	hostname := "test-device"
	mac := "00:50:56:12:34:56"

	syncer := &SyncPoller{
		config: Config{
			AgentID: "test-agent",
		},
		lastSyncResults: []*models.SweepResult{
			{
				IP:              "192.168.1.100",
				MAC:             &mac,
				Hostname:        &hostname,
				Available:       true,
				DiscoverySource: "netbox",
				Metadata: map[string]string{
					"netbox_device_id": "123",
					"role":             "servers",
				},
			},
		},
	}

	req := &proto.StatusRequest{
		ServiceName: "netbox-sync",
		ServiceType: "sweep",
	}

	resp, err := syncer.GetStatus(context.Background(), req)
	require.NoError(t, err)

	// Verify the response structure matches what the core expects for sweep services
	var response map[string]interface{}
	err = json.Unmarshal(resp.Message, &response)
	require.NoError(t, err)

	// Must have these top-level fields
	assert.Contains(t, response, "message")
	assert.Contains(t, response, "hosts")

	// Hosts must be an array
	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	require.Len(t, hosts, 1)

	// Each host must have the required structure
	host, ok := hosts[0].(map[string]interface{})
	require.True(t, ok)

	// Required fields for core's processSweepData
	assert.Contains(t, host, "host")      // IP address (renamed from 'ip')
	assert.Contains(t, host, "available") // availability
	assert.Contains(t, host, "metadata")  // metadata map

	// Optional fields
	assert.Contains(t, host, "mac")      // MAC address
	assert.Contains(t, host, "hostname") // hostname

	// Verify types match what core expects
	assert.IsType(t, "", host["host"])
	assert.IsType(t, true, host["available"])
	assert.IsType(t, "", host["mac"])
	assert.IsType(t, "", host["hostname"])
	assert.IsType(t, map[string]interface{}{}, host["metadata"])
}

// TestConcurrentGetStatus tests thread safety of GetStatus
func TestConcurrentGetStatus(t *testing.T) {
	syncer := &SyncPoller{
		config: Config{
			AgentID: "test-agent",
		},
		lastSyncResults: []*models.SweepResult{
			{
				IP:        "192.168.1.1",
				Available: true,
				Metadata:  map[string]string{"test": "data"},
			},
		},
	}

	req := &proto.StatusRequest{
		ServiceName: "test-sync",
		ServiceType: "sweep",
	}

	// Run multiple GetStatus calls concurrently
	done := make(chan bool, 10)
	for i := 0; i < 10; i++ {
		go func() {
			defer func() { done <- true }()
			
			resp, err := syncer.GetStatus(context.Background(), req)
			assert.NoError(t, err)
			assert.NotNil(t, resp)
			assert.True(t, resp.Available)
		}()
	}

	// Wait for all goroutines to complete
	for i := 0; i < 10; i++ {
		<-done
	}
}

func stringPtr(s string) *string {
	return &s
}