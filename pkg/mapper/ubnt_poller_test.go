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

package mapper

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateUniFiClient(t *testing.T) {
	tests := []struct {
		name     string
		config   UniFiAPIConfig
		timeout  time.Duration
		insecure bool
	}{
		{
			name: "default config",
			config: UniFiAPIConfig{
				Name:               "Test API",
				BaseURL:            "https://example.com/api",
				APIKey:             "test-api-key",
				InsecureSkipVerify: false,
			},
			timeout:  30 * time.Second,
			insecure: false,
		},
		{
			name: "insecure config",
			config: UniFiAPIConfig{
				Name:               "Test Insecure API",
				BaseURL:            "https://example.com/api",
				APIKey:             "test-api-key",
				InsecureSkipVerify: true,
			},
			timeout:  30 * time.Second,
			insecure: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := &DiscoveryEngine{
				config: &Config{
					Timeout: tt.timeout,
				},
				logger: logger.NewTestLogger(),
			}

			client := engine.createUniFiClient(tt.config)

			assert.NotNil(t, client)
			assert.Equal(t, tt.timeout, client.Timeout)

			// Check TLS config
			transport, ok := client.Transport.(*http.Transport)
			assert.True(t, ok)
			assert.NotNil(t, transport.TLSClientConfig)
			assert.Equal(t, tt.insecure, transport.TLSClientConfig.InsecureSkipVerify)
		})
	}
}

func TestFetchUniFiSites(t *testing.T) {
	tests := []struct {
		name           string
		serverResponse []UniFiSite
		statusCode     int
		expectError    bool
	}{
		{
			name: "successful response",
			serverResponse: []UniFiSite{
				{
					ID:                "site1",
					InternalReference: "ref1",
					Name:              "Site 1",
				},
				{
					ID:                "site2",
					InternalReference: "ref2",
					Name:              "Site 2",
				},
			},
			statusCode:  http.StatusOK,
			expectError: false,
		},
		{
			name:           "empty response",
			serverResponse: []UniFiSite{},
			statusCode:     http.StatusOK,
			expectError:    true,
		},
		{
			name:           "server error",
			serverResponse: nil,
			statusCode:     http.StatusInternalServerError,
			expectError:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a test server
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Check request method and path
				assert.Equal(t, http.MethodGet, r.Method)
				assert.Equal(t, "/sites", r.URL.Path)

				// Check headers
				assert.Equal(t, "test-api-key", r.Header.Get("X-API-Key"))
				assert.Equal(t, "application/json", r.Header.Get("Content-Type"))

				// Set response status code
				w.WriteHeader(tt.statusCode)

				// Write response body
				if tt.statusCode == http.StatusOK {
					response := struct {
						Data []UniFiSite `json:"data"`
					}{
						Data: tt.serverResponse,
					}
					json.NewEncoder(w).Encode(response)
				}
			}))
			defer server.Close()

			// Create engine and job
			engine := &DiscoveryEngine{
				config: &Config{
					Timeout: 30 * time.Second,
				},
				logger: logger.NewTestLogger(),
			}

			job := &DiscoveryJob{
				ID: "test-job",
				mu: sync.RWMutex{},
			}

			// Configure API
			apiConfig := UniFiAPIConfig{
				Name:    "Test API",
				BaseURL: server.URL,
				APIKey:  "test-api-key",
			}

			// Call the function
			sites, err := engine.fetchUniFiSites(context.Background(), job, apiConfig)

			// Check results
			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, sites)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, sites)
				assert.Equal(t, len(tt.serverResponse), len(sites))

				// Check cache
				job.mu.RLock()
				cachedSites, exists := job.uniFiSiteCache[apiConfig.BaseURL]
				job.mu.RUnlock()
				assert.True(t, exists)
				assert.Equal(t, len(tt.serverResponse), len(cachedSites))
			}
		})
	}
}

func TestFetchUniFiDevicesForSite(t *testing.T) {
	tests := []struct {
		name           string
		serverResponse []UniFiDevice
		statusCode     int
		expectError    bool
	}{
		{
			name: "successful response",
			serverResponse: []UniFiDevice{
				{
					ID:        "device1",
					IPAddress: "192.168.1.1",
					Name:      "Device 1",
					MAC:       "00:11:22:33:44:55",
				},
				{
					ID:        "device2",
					IPAddress: "192.168.1.2",
					Name:      "Device 2",
					MAC:       "AA:BB:CC:DD:EE:FF",
				},
			},
			statusCode:  http.StatusOK,
			expectError: false,
		},
		{
			name:           "empty response",
			serverResponse: []UniFiDevice{},
			statusCode:     http.StatusOK,
			expectError:    false,
		},
		{
			name:           "server error",
			serverResponse: nil,
			statusCode:     http.StatusInternalServerError,
			expectError:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create a test server
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Check request method and path
				assert.Equal(t, http.MethodGet, r.Method)
				assert.Equal(t, "/sites/site1/devices", r.URL.Path)
				assert.Contains(t, r.URL.RawQuery, "limit=50")

				// Check headers
				assert.Equal(t, "test-api-key", r.Header.Get("X-API-Key"))
				assert.Equal(t, "application/json", r.Header.Get("Content-Type"))

				// Set response status code
				w.WriteHeader(tt.statusCode)

				// Write response body
				if tt.statusCode == http.StatusOK {
					response := struct {
						Data []UniFiDevice `json:"data"`
					}{
						Data: tt.serverResponse,
					}
					json.NewEncoder(w).Encode(response)
				}
			}))
			defer server.Close()

			// Create engine and job
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			job := &DiscoveryJob{
				ID: "test-job",
			}

			// Create HTTP client
			client := &http.Client{
				Timeout: 30 * time.Second,
			}

			// Configure headers and API
			headers := map[string]string{
				"X-API-Key":    "test-api-key",
				"Content-Type": "application/json",
			}

			apiConfig := UniFiAPIConfig{
				Name:    "Test API",
				BaseURL: server.URL,
				APIKey:  "test-api-key",
			}

			site := UniFiSite{
				ID:   "site1",
				Name: "Site 1",
			}

			// Call the function
			devices, deviceCache, err := engine.fetchUniFiDevicesForSite(
				context.Background(),
				job,
				client,
				headers,
				apiConfig,
				site,
			)

			// Check results
			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, devices)
				assert.Nil(t, deviceCache)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, devices)
				assert.Equal(t, len(tt.serverResponse), len(devices))

				// Check device cache
				assert.NotNil(t, deviceCache)
				assert.Equal(t, len(tt.serverResponse), len(deviceCache))

				// Verify cache entries
				for _, device := range tt.serverResponse {
					cacheEntry, exists := deviceCache[device.ID]
					assert.True(t, exists)
					assert.Equal(t, device.IPAddress, cacheEntry.IP)
					assert.Equal(t, device.Name, cacheEntry.Name)
					assert.Equal(t, device.MAC, cacheEntry.MAC)
				}
			}
		})
	}
}

func TestProcessLLDPTable(t *testing.T) {
	// Create test data
	device := &UniFiDevice{
		ID:        "device1",
		IPAddress: "192.168.1.1",
		Name:      "Device 1",
		MAC:       "00:11:22:33:44:55",
	}

	deviceID := "device-id-1"

	details := &UniFiDeviceDetails{
		LLDPTable: []struct {
			LocalPortIdx    int32  `json:"local_port_idx"`
			LocalPortName   string `json:"local_port_name"`
			ChassisID       string `json:"chassis_id"`
			PortID          string `json:"port_id"`
			PortDescription string `json:"port_description"`
			SystemName      string `json:"system_name"`
			ManagementAddr  string `json:"management_address"`
		}{
			{
				LocalPortIdx:    1,
				LocalPortName:   "Port 1",
				ChassisID:       "aa:bb:cc:dd:ee:ff",
				PortID:          "Gi0/1",
				PortDescription: "GigabitEthernet0/1",
				SystemName:      "neighbor-device",
				ManagementAddr:  "192.168.1.2",
			},
		},
	}

	apiConfig := UniFiAPIConfig{
		Name:    "Test API",
		BaseURL: "https://example.com/api",
	}

	site := UniFiSite{
		ID:   "site1",
		Name: "Site 1",
	}

	job := &DiscoveryJob{
		ID: "test-job",
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	// Call the function
	links := engine.processLLDPTable(job, device, deviceID, details, apiConfig, site)

	// Check results
	assert.NotNil(t, links)
	assert.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "LLDP", link.Protocol)
	assert.Equal(t, device.IPAddress, link.LocalDeviceIP)
	assert.Equal(t, deviceID, link.LocalDeviceID)
	assert.Equal(t, details.LLDPTable[0].LocalPortIdx, link.LocalIfIndex)
	assert.Equal(t, details.LLDPTable[0].LocalPortName, link.LocalIfName)
	assert.Equal(t, details.LLDPTable[0].ChassisID, link.NeighborChassisID)
	assert.Equal(t, details.LLDPTable[0].PortID, link.NeighborPortID)
	assert.Equal(t, details.LLDPTable[0].PortDescription, link.NeighborPortDescr)
	assert.Equal(t, details.LLDPTable[0].SystemName, link.NeighborSystemName)
	assert.Equal(t, details.LLDPTable[0].ManagementAddr, link.NeighborMgmtAddr)

	// Check metadata
	assert.NotNil(t, link.Metadata)
	assert.Equal(t, job.ID, link.Metadata["discovery_id"])
	assert.Equal(t, "unifi-api", link.Metadata["source"])
	assert.Equal(t, apiConfig.BaseURL, link.Metadata["controller_url"])
	assert.Equal(t, site.ID, link.Metadata["site_id"])
	assert.Equal(t, site.Name, link.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, link.Metadata["controller_name"])
}

func TestProcessPortTable(t *testing.T) {
	// Create test data
	device := &UniFiDevice{
		ID:        "device1",
		IPAddress: "192.168.1.1",
		Name:      "Device 1",
		MAC:       "00:11:22:33:44:55",
	}

	deviceID := "device-id-1"

	details := &UniFiDeviceDetails{
		PortTable: []struct {
			PortIdx         int32  `json:"port_idx"`
			Name            string `json:"name"`
			ConnectedDevice struct {
				MAC  string `json:"mac"`
				Name string `json:"name"`
				IP   string `json:"ip"`
			} `json:"connected_device"`
		}{
			{
				PortIdx: 1,
				Name:    "Port 1",
				ConnectedDevice: struct {
					MAC  string `json:"mac"`
					Name string `json:"name"`
					IP   string `json:"ip"`
				}{
					MAC:  "aa:bb:cc:dd:ee:ff",
					Name: "connected-device",
					IP:   "192.168.1.2",
				},
			},
			{
				PortIdx: 2,
				Name:    "Port 2",
				ConnectedDevice: struct {
					MAC  string `json:"mac"`
					Name string `json:"name"`
					IP   string `json:"ip"`
				}{
					// Empty connected device
				},
			},
		},
	}

	apiConfig := UniFiAPIConfig{
		Name:    "Test API",
		BaseURL: "https://example.com/api",
	}

	site := UniFiSite{
		ID:   "site1",
		Name: "Site 1",
	}

	job := &DiscoveryJob{
		ID: "test-job",
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	// Call the function
	links := engine.processPortTable(job, device, deviceID, details, apiConfig, site)

	// Check results
	assert.NotNil(t, links)
	assert.Len(t, links, 1) // Only one port has a connected device

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, device.IPAddress, link.LocalDeviceIP)
	assert.Equal(t, deviceID, link.LocalDeviceID)
	assert.Equal(t, details.PortTable[0].PortIdx, link.LocalIfIndex)
	assert.Equal(t, details.PortTable[0].Name, link.LocalIfName)
	assert.Equal(t, details.PortTable[0].ConnectedDevice.MAC, link.NeighborChassisID)
	assert.Equal(t, details.PortTable[0].ConnectedDevice.Name, link.NeighborSystemName)
	assert.Equal(t, details.PortTable[0].ConnectedDevice.IP, link.NeighborMgmtAddr)

	// Check metadata
	assert.NotNil(t, link.Metadata)
	assert.Equal(t, job.ID, link.Metadata["discovery_id"])
	assert.Equal(t, "unifi-api", link.Metadata["source"])
	assert.Equal(t, apiConfig.BaseURL, link.Metadata["controller_url"])
	assert.Equal(t, site.ID, link.Metadata["site_id"])
	assert.Equal(t, site.Name, link.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, link.Metadata["controller_name"])
}

func TestProcessUplinkInfo(t *testing.T) {
	// Create test data
	device := &UniFiDevice{
		ID:        "device1",
		IPAddress: "192.168.1.1",
		Name:      "Device 1",
		MAC:       "00:11:22:33:44:55",
		Uplink: struct {
			DeviceID string `json:"deviceId"`
		}{
			DeviceID: "uplink-device",
		},
	}

	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{
		"uplink-device": {
			IP:       "192.168.1.254",
			Name:     "Uplink Device",
			MAC:      "ff:ee:dd:cc:bb:aa",
			DeviceID: "uplink-device-id",
		},
	}

	apiConfig := UniFiAPIConfig{
		Name:    "Test API",
		BaseURL: "https://example.com/api",
	}

	site := UniFiSite{
		ID:   "site1",
		Name: "Site 1",
	}

	job := &DiscoveryJob{
		ID: "test-job",
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	// Call the function
	links := engine.processUplinkInfo(job, device, deviceCache, apiConfig, site)

	// Check results
	assert.NotNil(t, links)
	assert.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, deviceCache["uplink-device"].IP, link.LocalDeviceIP)
	assert.Equal(t, deviceCache["uplink-device"].DeviceID, link.LocalDeviceID)
	assert.Equal(t, int32(0), link.LocalIfIndex)
	assert.Equal(t, device.MAC, link.NeighborChassisID)
	assert.Equal(t, device.Name, link.NeighborSystemName)
	assert.Equal(t, device.IPAddress, link.NeighborMgmtAddr)

	// Check metadata
	assert.NotNil(t, link.Metadata)
	assert.Equal(t, job.ID, link.Metadata["discovery_id"])
	assert.Equal(t, "unifi-api", link.Metadata["source"])
	assert.Equal(t, apiConfig.BaseURL, link.Metadata["controller_url"])
	assert.Equal(t, site.ID, link.Metadata["site_id"])
	assert.Equal(t, site.Name, link.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, link.Metadata["controller_name"])
	assert.Equal(t, "uplink-device", link.Metadata["uplink_device_id"])
	assert.Equal(t, deviceCache["uplink-device"].Name, link.Metadata["uplink_device_name"])
}

func TestCreateDiscoveredDevice(t *testing.T) {
	// Create test data
	device := &UniFiDevice{
		ID:        "device1",
		IPAddress: "192.168.1.1",
		Name:      "Device 1",
		MAC:       "00:11:22:33:44:55",
	}

	apiConfig := UniFiAPIConfig{
		Name:    "Test API",
		BaseURL: "https://example.com/api",
	}

	site := UniFiSite{
		ID:   "site1",
		Name: "Site 1",
	}

	job := &DiscoveryJob{
		ID: "test-job",
		Params: &DiscoveryParams{
			AgentID:  "agent1",
			PollerID: "poller1",
		},
	}

	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	// Call the function
	result := engine.createDiscoveredDevice(job, device, apiConfig, site)

	// Check results
	assert.NotNil(t, result)
	assert.Equal(t, device.IPAddress, result.IP)
	assert.Equal(t, device.MAC, result.MAC)
	assert.Equal(t, device.Name, result.Hostname)

	// DeviceID should be generated
	assert.NotEmpty(t, result.DeviceID)

	// Check metadata
	assert.NotNil(t, result.Metadata)
	assert.Equal(t, "unifi-api", result.Metadata["source"])
	assert.Equal(t, apiConfig.BaseURL, result.Metadata["controller_url"])
	assert.Equal(t, site.ID, result.Metadata["site_id"])
	assert.Equal(t, site.Name, result.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, result.Metadata["controller_name"])
	assert.Equal(t, device.ID, result.Metadata["unifi_device_id"])

	// Test with empty IP address
	deviceNoIP := &UniFiDevice{
		ID:        "device2",
		IPAddress: "",
		Name:      "Device 2",
		MAC:       "aa:bb:cc:dd:ee:ff",
	}

	result = engine.createDiscoveredDevice(job, deviceNoIP, apiConfig, site)
	assert.Nil(t, result) // Should return nil for devices without IP
}

func TestAddPoEMetadata(t *testing.T) {
	tests := []struct {
		name string
		port *struct {
			Idx          int    `json:"idx"`
			State        string `json:"state"`
			Connector    string `json:"connector"`
			MaxSpeedMbps int    `json:"maxSpeedMbps"`
			SpeedMbps    int    `json:"speedMbps"`
			PoE          struct {
				Standard string `json:"standard"`
				Type     int    `json:"type"`
				Enabled  bool   `json:"enabled"`
				State    string `json:"state"`
			} `json:"poe,omitempty"`
		}
		expectedKeys []string
	}{
		{
			name: "port with PoE enabled",
			port: &struct {
				Idx          int    `json:"idx"`
				State        string `json:"state"`
				Connector    string `json:"connector"`
				MaxSpeedMbps int    `json:"maxSpeedMbps"`
				SpeedMbps    int    `json:"speedMbps"`
				PoE          struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				} `json:"poe,omitempty"`
			}{
				Idx:          1,
				State:        "up",
				Connector:    "RJ45",
				MaxSpeedMbps: 1000,
				SpeedMbps:    1000,
				PoE: struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				}{
					Standard: "802.3at",
					Type:     2,
					Enabled:  true,
					State:    "active",
				},
			},
			expectedKeys: []string{"poe_standard", "poe_type", "poe_state", "poe_enabled"},
		},
		{
			name: "port with PoE disabled",
			port: &struct {
				Idx          int    `json:"idx"`
				State        string `json:"state"`
				Connector    string `json:"connector"`
				MaxSpeedMbps int    `json:"maxSpeedMbps"`
				SpeedMbps    int    `json:"speedMbps"`
				PoE          struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				} `json:"poe,omitempty"`
			}{
				Idx:          2,
				State:        "up",
				Connector:    "RJ45",
				MaxSpeedMbps: 1000,
				SpeedMbps:    1000,
				PoE: struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				}{
					Standard: "802.3at",
					Type:     2,
					Enabled:  false,
					State:    "disabled",
				},
			},
			expectedKeys: []string{"poe_standard", "poe_type", "poe_state", "poe_enabled"},
		},
		{
			name: "port without PoE",
			port: &struct {
				Idx          int    `json:"idx"`
				State        string `json:"state"`
				Connector    string `json:"connector"`
				MaxSpeedMbps int    `json:"maxSpeedMbps"`
				SpeedMbps    int    `json:"speedMbps"`
				PoE          struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				} `json:"poe,omitempty"`
			}{
				Idx:          3,
				State:        "up",
				Connector:    "RJ45",
				MaxSpeedMbps: 1000,
				SpeedMbps:    1000,
				PoE: struct {
					Standard string `json:"standard"`
					Type     int    `json:"type"`
					Enabled  bool   `json:"enabled"`
					State    string `json:"state"`
				}{},
			},
			expectedKeys: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			metadata := make(map[string]string)
			engine := &DiscoveryEngine{
				logger: logger.NewTestLogger(),
			}

			engine.addPoEMetadata(metadata, tt.port)

			// Check if expected keys are present
			for _, key := range tt.expectedKeys {
				assert.Contains(t, metadata, key)
				assert.NotEmpty(t, metadata[key])
			}

			// If PoE is enabled, check specific values
			if tt.port.PoE.Enabled || tt.port.PoE.Standard != "" {
				assert.Equal(t, tt.port.PoE.Standard, metadata["poe_standard"])
				assert.Equal(t, tt.port.PoE.State, metadata["poe_state"])
				assert.Equal(t, "true", metadata["poe_enabled"])
			}
		})
	}
}
