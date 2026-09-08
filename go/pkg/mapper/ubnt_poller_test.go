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
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
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
					if err := json.NewEncoder(w).Encode(response); err != nil {
						http.Error(w, err.Error(), http.StatusInternalServerError)
						return
					}
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
				assert.Len(t, sites, len(tt.serverResponse))

				// Check cache
				job.mu.RLock()
				cachedSites, exists := job.uniFiSiteCache[apiConfig.BaseURL]
				job.mu.RUnlock()
				assert.True(t, exists)
				assert.Len(t, cachedSites, len(tt.serverResponse))
			}
		})
	}
}

func assertUniFiPageQuery(t *testing.T, r *http.Request) {
	t.Helper()

	assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))
	assert.Equal(t, "0", r.URL.Query().Get("offset"))
}

func mustAtoi(t *testing.T, value string) int {
	t.Helper()

	n, err := strconv.Atoi(value)
	require.NoError(t, err)

	return n
}

func makeUniFiDevicePage(start, count int) []UniFiDevice {
	devices := make([]UniFiDevice, 0, count)
	for i := range count {
		id := start + i
		devices = append(devices, UniFiDevice{
			ID:        fmt.Sprintf("device-%d", id),
			IPAddress: fmt.Sprintf("192.168.%d.%d", id/254, (id%254)+1),
			Name:      fmt.Sprintf("Device %d", id),
			MAC:       fmt.Sprintf("00:11:22:%02x:%02x:%02x", (id>>16)&0xff, (id>>8)&0xff, id&0xff),
		})
	}

	return devices
}

func makeUniFiClientPage(start, count int, clientType string) []UniFiClient {
	clients := make([]UniFiClient, 0, count)
	for i := range count {
		id := start + i
		clients = append(clients, UniFiClient{
			ID:             fmt.Sprintf("client-%d", id),
			Type:           clientType,
			Name:           fmt.Sprintf("Client %d", id),
			MACAddress:     fmt.Sprintf("aa:bb:cc:%02x:%02x:%02x", (id>>16)&0xff, (id>>8)&0xff, id&0xff),
			IPAddress:      fmt.Sprintf("192.168.%d.%d", id/254, (id%254)+1),
			UplinkDeviceID: "ap-1",
		})
	}

	return clients
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
				assertUniFiPageQuery(t, r)

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
					if err := json.NewEncoder(w).Encode(response); err != nil {
						http.Error(w, err.Error(), http.StatusInternalServerError)
						return
					}
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
				assert.Len(t, devices, len(tt.serverResponse))

				// Check device cache
				assert.NotNil(t, deviceCache)
				assert.Len(t, deviceCache, len(tt.serverResponse))

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

func TestFetchUniFiDevicesForSitePaginatesUntilShortPage(t *testing.T) {
	requestedOffsets := make([]int, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.Equal(t, "/sites/site1/devices", r.URL.Path)
		assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))

		switch r.URL.Query().Get("offset") {
		case "0":
			requestedOffsets = append(requestedOffsets, 0)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{Data: makeUniFiDevicePage(0, uniFiAPIPageLimit)}))
		case fmt.Sprint(uniFiAPIPageLimit):
			requestedOffsets = append(requestedOffsets, uniFiAPIPageLimit)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{Data: makeUniFiDevicePage(uniFiAPIPageLimit, 1)}))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	job := &DiscoveryJob{ID: "test-job"}
	client := &http.Client{Timeout: 30 * time.Second}
	headers := map[string]string{"X-API-Key": "test-api-key", "Content-Type": "application/json"}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: server.URL, APIKey: "test-api-key"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	devices, deviceCache, err := engine.fetchUniFiDevicesForSite(context.Background(), job, client, headers, apiConfig, site)
	require.NoError(t, err)
	assert.Equal(t, []int{0, uniFiAPIPageLimit}, requestedOffsets)
	assert.Len(t, devices, uniFiAPIPageLimit+1)
	assert.Len(t, deviceCache, uniFiAPIPageLimit+1)
	assert.Contains(t, deviceCache, fmt.Sprintf("device-%d", uniFiAPIPageLimit))
}

func TestFetchUniFiPagedDataStopsWhenControllerRepeatsPage(t *testing.T) {
	requestedOffsets := make([]int, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.Equal(t, "/sites/site1/devices", r.URL.Path)
		assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))

		switch r.URL.Query().Get("offset") {
		case "0":
			requestedOffsets = append(requestedOffsets, 0)
		case fmt.Sprint(uniFiAPIPageLimit):
			requestedOffsets = append(requestedOffsets, uniFiAPIPageLimit)
		default:
			t.Fatalf("unexpected offset %s", r.URL.Query().Get("offset"))
		}

		w.WriteHeader(http.StatusOK)
		assert.NoError(t, json.NewEncoder(w).Encode(struct {
			Data []UniFiDevice `json:"data"`
		}{Data: makeUniFiDevicePage(0, uniFiAPIPageLimit)}))
	}))
	defer server.Close()

	devices, err := fetchUniFiPagedDataWithPageCap[UniFiDevice](
		context.Background(),
		server.Client(),
		map[string]string{"X-API-Key": "test-api-key"},
		server.URL+"/sites/site1/devices",
		"devices",
		"Test API",
		"Site 1",
		10,
	)

	require.Error(t, err)
	assert.Nil(t, devices)
	assert.Equal(t, []int{0, uniFiAPIPageLimit}, requestedOffsets)
	assert.Contains(t, err.Error(), "repeated the first record")
	assert.Contains(t, err.Error(), "controller may not support offset paging")
}

func TestFetchUniFiPagedDataEnforcesPageCap(t *testing.T) {
	requestedOffsets := make([]int, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.Equal(t, "/sites/site1/devices", r.URL.Path)
		assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))

		offset := r.URL.Query().Get("offset")
		requestedOffsets = append(requestedOffsets, mustAtoi(t, offset))

		w.WriteHeader(http.StatusOK)
		assert.NoError(t, json.NewEncoder(w).Encode(struct {
			Data []UniFiDevice `json:"data"`
		}{Data: makeUniFiDevicePage(mustAtoi(t, offset), uniFiAPIPageLimit)}))
	}))
	defer server.Close()

	devices, err := fetchUniFiPagedDataWithPageCap[UniFiDevice](
		context.Background(),
		server.Client(),
		map[string]string{"X-API-Key": "test-api-key"},
		server.URL+"/sites/site1/devices",
		"devices",
		"Test API",
		"Site 1",
		2,
	)

	require.Error(t, err)
	assert.Nil(t, devices)
	assert.Equal(t, []int{0, uniFiAPIPageLimit}, requestedOffsets)
	assert.Contains(t, err.Error(), "pagination exceeded 2 pages")
	assert.Contains(t, err.Error(), "1000 records")
}

func TestFetchUniFiClientsForSite(t *testing.T) {
	tests := []struct {
		name           string
		serverResponse []UniFiClient
		statusCode     int
		expectError    bool
		expectedCount  int
	}{
		{
			name: "returns wired and wireless clients",
			serverResponse: []UniFiClient{
				{ID: "wired-1", Type: "WIRED", MACAddress: "00:11:22:33:44:55", UplinkDeviceID: "switch-1"},
				{ID: "wireless-1", Type: "WIRELESS", MACAddress: "aa:bb:cc:dd:ee:ff", UplinkDeviceID: "ap-1"},
				{ID: "wireless-2", Type: "wireless", MACAddress: "11:22:33:44:55:66", UplinkDeviceID: "ap-2"},
			},
			statusCode:    http.StatusOK,
			expectError:   false,
			expectedCount: 3,
		},
		{
			name:           "server error",
			serverResponse: nil,
			statusCode:     http.StatusInternalServerError,
			expectError:    true,
			expectedCount:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				assert.Equal(t, http.MethodGet, r.Method)
				assert.Equal(t, "/sites/site1/clients", r.URL.Path)
				assertUniFiPageQuery(t, r)
				assert.Equal(t, "test-api-key", r.Header.Get("X-API-Key"))
				assert.Equal(t, "application/json", r.Header.Get("Content-Type"))
				w.WriteHeader(tt.statusCode)
				if tt.statusCode == http.StatusOK {
					response := struct {
						Data []UniFiClient `json:"data"`
					}{Data: tt.serverResponse}
					if err := json.NewEncoder(w).Encode(response); err != nil {
						http.Error(w, err.Error(), http.StatusInternalServerError)
					}
				}
			}))
			defer server.Close()

			engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
			client := &http.Client{Timeout: 30 * time.Second}
			headers := map[string]string{"X-API-Key": "test-api-key", "Content-Type": "application/json"}
			apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: server.URL, APIKey: "test-api-key"}
			site := UniFiSite{ID: "site1", Name: "Site 1"}

			clients, err := engine.fetchUniFiClientsForSite(context.Background(), client, headers, apiConfig, site)
			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, clients)
				return
			}

			require.NoError(t, err)
			assert.Len(t, clients, tt.expectedCount)

			typeCounts := make(map[string]int)
			for _, client := range clients {
				typeCounts[client.normalizedType()]++
			}
			assert.Equal(t, 1, typeCounts["WIRED"])
			assert.Equal(t, 2, typeCounts["WIRELESS"])
		})
	}
}

func TestFetchUniFiClientsForSitePaginatesAcrossClientTypes(t *testing.T) {
	requestedOffsets := make([]int, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.Equal(t, "/sites/site1/clients", r.URL.Path)
		assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))

		switch r.URL.Query().Get("offset") {
		case "0":
			requestedOffsets = append(requestedOffsets, 0)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiClient `json:"data"`
			}{Data: makeUniFiClientPage(0, uniFiAPIPageLimit, "WIRELESS")}))
		case fmt.Sprint(uniFiAPIPageLimit):
			requestedOffsets = append(requestedOffsets, uniFiAPIPageLimit)
			page := makeUniFiClientPage(uniFiAPIPageLimit, 1, "WIRELESS")
			page = append(page, makeUniFiClientPage(uniFiAPIPageLimit+1, 1, "WIRED")...)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiClient `json:"data"`
			}{Data: page}))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	client := &http.Client{Timeout: 30 * time.Second}
	headers := map[string]string{"X-API-Key": "test-api-key", "Content-Type": "application/json"}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: server.URL, APIKey: "test-api-key"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	clients, err := engine.fetchUniFiClientsForSite(context.Background(), client, headers, apiConfig, site)
	require.NoError(t, err)
	assert.Equal(t, []int{0, uniFiAPIPageLimit}, requestedOffsets)
	assert.Len(t, clients, uniFiAPIPageLimit+2)

	wiredCount := 0
	for _, client := range clients {
		if client.normalizedType() == "WIRED" {
			wiredCount++
		}
	}
	assert.Equal(t, 1, wiredCount)
}

func TestFetchUniFiDevicesPaginatesLegacyDiscoveryPath(t *testing.T) {
	requestedOffsets := make([]int, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodGet, r.Method)
		assert.Equal(t, "/sites/site1/devices", r.URL.Path)
		assert.Equal(t, fmt.Sprint(uniFiAPIPageLimit), r.URL.Query().Get("limit"))

		switch r.URL.Query().Get("offset") {
		case "0":
			requestedOffsets = append(requestedOffsets, 0)
			page := makeUniFiDevicePage(0, uniFiAPIPageLimit)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{Data: page}))
		case fmt.Sprint(uniFiAPIPageLimit):
			requestedOffsets = append(requestedOffsets, uniFiAPIPageLimit)
			page := makeUniFiDevicePage(uniFiAPIPageLimit, 1)
			w.WriteHeader(http.StatusOK)
			assert.NoError(t, json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{Data: page}))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{Timeout: 30 * time.Second},
		logger: logger.NewTestLogger(),
	}
	job := &DiscoveryJob{ID: "test-job"}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: server.URL, APIKey: "test-api-key"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	devices, err := engine.fetchUniFiDevices(context.Background(), job, apiConfig, site)
	require.NoError(t, err)
	assert.Equal(t, []int{0, uniFiAPIPageLimit}, requestedOffsets)
	assert.Len(t, devices, uniFiAPIPageLimit+1)
	assert.Equal(t, fmt.Sprintf("device-%d", uniFiAPIPageLimit), devices[uniFiAPIPageLimit].ID)
}

func newUniFiInventoryUplinkServer(t *testing.T, deviceDetailPayload []byte) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sites/site1/devices":
			assertUniFiPageQuery(t, r)
			w.WriteHeader(http.StatusOK)
			err := json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{
				Data: []UniFiDevice{
					{
						ID:        "uplink-device",
						IPAddress: "192.168.1.254",
						Name:      "Uplink Device",
						MAC:       "ff:ee:dd:cc:bb:aa",
					},
					{
						ID:        "device1",
						IPAddress: "192.168.1.1",
						Name:      "Device 1",
						MAC:       "00:11:22:33:44:55",
						Uplink: UniFiUplink{
							DeviceID:      "uplink-device",
							LocalPortIdx:  26,
							LocalPortName: "Port 26",
						},
					},
				},
			})
			if err != nil {
				t.Fatalf("encode integration devices response: %v", err)
			}
		case "/sites/site1/devices/device1", "/sites/site1/devices/uplink-device":
			w.WriteHeader(http.StatusOK)
			_, err := w.Write(deviceDetailPayload)
			if err != nil {
				t.Fatalf("write integration device details response: %v", err)
			}
		default:
			http.NotFound(w, r)
		}
	}))
}

func TestQuerySingleUniFiAPIFallsBackToInventoryUplinkWhenDetailPayloadDrifts(t *testing.T) {
	job := &DiscoveryJob{
		ID: "test-job",
		Results: &DiscoveryResults{
			Contract: DiscoveryContract{
				ParseDiagnostics: DiscoveryParseDiagnostics{
					ParseFailures:     make(map[string]int),
					UnknownTopLevel:   make(map[string]int),
					ParserMismatches:  make(map[string]int),
					LastFailureByType: make(map[string]string),
				},
			},
		},
	}

	deviceDetailPayload := []byte(`{
		"id": "device1",
		"ipAddress": "192.168.1.1",
		"name": "Device 1",
		"macAddress": "00:11:22:33:44:55",
		"model": "UDM Pro Max",
		"supported": true,
		"interfaces": {
			"ports": []
		}
	}`)

	server := newUniFiInventoryUplinkServer(t, deviceDetailPayload)
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
		},
		logger: logger.NewTestLogger(),
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

	links, err := engine.querySingleUniFiAPI(context.Background(), job, "", apiConfig, site)
	require.NoError(t, err)
	require.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, "192.168.1.254", link.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("ff:ee:dd:cc:bb:aa"), link.LocalDeviceID)
	assert.Equal(t, int32(26), link.LocalIfIndex)
	assert.Equal(t, "Port 26", link.LocalIfName)
	assert.Equal(t, "00:11:22:33:44:55", link.NeighborChassisID)
	assert.Equal(t, "Device 1", link.NeighborSystemName)
	assert.Equal(t, "192.168.1.1", link.NeighborMgmtAddr)
	assert.Equal(t, "unifi-api-uplink", link.Metadata["source"])
	assert.Positive(t, job.Results.Contract.ParseDiagnostics.ParserMismatches["unifi.detail.quarantined"])
}

func TestQuerySingleUniFiAPIAcceptsKnownInterfacePortDetailsWithoutQuarantine(t *testing.T) {
	job := &DiscoveryJob{
		ID: "test-job",
		Results: &DiscoveryResults{
			Contract: DiscoveryContract{
				ParseDiagnostics: DiscoveryParseDiagnostics{
					ParseFailures:     make(map[string]int),
					UnknownTopLevel:   make(map[string]int),
					ParserMismatches:  make(map[string]int),
					LastFailureByType: make(map[string]string),
				},
			},
		},
	}

	deviceDetailPayload := []byte(`{
		"id": "device1",
		"ipAddress": "192.168.1.1",
		"name": "Device 1",
		"macAddress": "00:11:22:33:44:55",
		"model": "UDM Pro Max",
		"supported": true,
		"interfaces": {
			"ports": [
				{"idx":1,"state":"UP","connector":"RJ45","maxSpeedMbps":1000,"speedMbps":1000},
				{"idx":10,"state":"UP","connector":"SFPPLUS","maxSpeedMbps":10000,"speedMbps":1000}
			]
		}
	}`)

	server := newUniFiInventoryUplinkServer(t, deviceDetailPayload)
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
		},
		logger: logger.NewTestLogger(),
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

	links, err := engine.querySingleUniFiAPI(context.Background(), job, "", apiConfig, site)
	require.NoError(t, err)
	require.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, "192.168.1.254", link.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("ff:ee:dd:cc:bb:aa"), link.LocalDeviceID)
	assert.Equal(t, int32(26), link.LocalIfIndex)
	assert.Equal(t, "Port 26", link.LocalIfName)
	assert.Equal(t, "00:11:22:33:44:55", link.NeighborChassisID)
	assert.Equal(t, "Device 1", link.NeighborSystemName)
	assert.Equal(t, "192.168.1.1", link.NeighborMgmtAddr)
	assert.Equal(t, "unifi-api-uplink", link.Metadata["source"])
	assert.Equal(t, unifiDetailAdapterV1Direct, link.Metadata["source_adapter_version"])
	assert.Equal(t, "direct", link.Metadata["source_adapter_shape"])
	assert.Zero(t, job.Results.Contract.ParseDiagnostics.ParserMismatches["unifi.detail.quarantined"])
}

func TestQuerySingleUniFiAPIFallsBackToLegacyStatDeviceWhenIntegrationDetailsDrift(t *testing.T) {
	job := &DiscoveryJob{
		ID: "test-job",
		Results: &DiscoveryResults{
			Contract: DiscoveryContract{
				ParseDiagnostics: DiscoveryParseDiagnostics{
					ParseFailures:     make(map[string]int),
					UnknownTopLevel:   make(map[string]int),
					ParserMismatches:  make(map[string]int),
					LastFailureByType: make(map[string]string),
				},
			},
		},
	}

	deviceDetailPayload := []byte(`{
		"id": "device1",
		"ipAddress": "192.168.1.1",
		"name": "Device 1",
		"macAddress": "00:11:22:33:44:55",
		"model": "UDM Pro Max",
		"supported": true,
		"interfaces": {
			"ports": []
		}
	}`)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy/network/integration/v1/sites/site1/devices":
			assertUniFiPageQuery(t, r)
			w.WriteHeader(http.StatusOK)
			err := json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{
				Data: []UniFiDevice{
					{
						ID:        "device1",
						IPAddress: "192.168.1.1",
						Name:      "Device 1",
						MAC:       "00:11:22:33:44:55",
					},
				},
			})
			if err != nil {
				t.Fatalf("encode integration devices response: %v", err)
			}
		case "/proxy/network/integration/v1/sites/site1/devices/device1":
			w.WriteHeader(http.StatusOK)
			_, err := w.Write(deviceDetailPayload)
			if err != nil {
				t.Fatalf("write integration device detail response: %v", err)
			}
		case "/proxy/network/api/s/default/stat/device":
			w.WriteHeader(http.StatusOK)
			err := json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{
						"mac":  "00:11:22:33:44:55",
						"ip":   "192.168.1.1",
						"name": "Device 1",
						"lldp_table": []map[string]any{
							{
								"local_port_idx":  26,
								"local_port_name": "eth25",
								"chassis_id":      "78:45:58:6d:1e:4b",
								"port_id":         "eth4",
							},
						},
					},
				},
			})
			if err != nil {
				t.Fatalf("encode legacy stat/device response: %v", err)
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
		},
		logger: logger.NewTestLogger(),
	}

	apiConfig := UniFiAPIConfig{
		Name:    "Test API",
		BaseURL: server.URL + "/proxy/network/integration/v1",
		APIKey:  "test-api-key",
	}

	site := UniFiSite{
		ID:                "site1",
		InternalReference: "default",
		Name:              "Site 1",
	}

	links, err := engine.querySingleUniFiAPI(context.Background(), job, "", apiConfig, site)
	require.NoError(t, err)
	require.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "LLDP", link.Protocol)
	assert.Equal(t, "192.168.1.1", link.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("00:11:22:33:44:55"), link.LocalDeviceID)
	assert.Equal(t, int32(26), link.LocalIfIndex)
	assert.Equal(t, "eth25", link.LocalIfName)
	assert.Equal(t, "78:45:58:6d:1e:4b", link.NeighborChassisID)
	assert.Equal(t, "eth4", link.NeighborPortID)
	assert.Equal(t, unifiDetailAdapterLegacyStat, link.Metadata["source_adapter_version"])
	assert.Equal(t, "legacy_stat_device", link.Metadata["source_adapter_shape"])
	assert.Positive(t, job.Results.Contract.ParseDiagnostics.ParserMismatches["unifi.detail.quarantined"])
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
		LLDPTable: []UniFiLLDPEntry{
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
	assert.Equal(t, "unifi-api-lldp", link.Metadata["source"])
	assert.Equal(t, evidenceClassDirectPhysical, link.Metadata["evidence_class"])
	assert.Equal(t, "CONNECTS_TO", link.Metadata["relation_family"])
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
		PortTable: []UniFiPortEntry{
			{
				PortIdx: 1,
				Name:    "Port 1",
				Connected: UniFiPortConnectedPeer{
					MAC:  "aa:bb:cc:dd:ee:ff",
					Name: "connected-device",
					IP:   "192.168.1.2",
				},
			},
			{
				PortIdx:   2,
				Name:      "Port 2",
				Connected: UniFiPortConnectedPeer{},
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

	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{}

	// Call the function
	links := engine.processPortTable(job, device, deviceID, details, deviceCache, apiConfig, site)

	// Check results
	assert.NotNil(t, links)
	assert.Len(t, links, 1) // Only one port has a connected device

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, device.IPAddress, link.LocalDeviceIP)
	assert.Equal(t, deviceID, link.LocalDeviceID)
	assert.Equal(t, details.PortTable[0].PortIdx, link.LocalIfIndex)
	assert.Equal(t, details.PortTable[0].Name, link.LocalIfName)
	assert.Equal(t, details.PortTable[0].Connected.MAC, link.NeighborChassisID)
	assert.Equal(t, details.PortTable[0].Connected.Name, link.NeighborSystemName)
	assert.Equal(t, details.PortTable[0].Connected.IP, link.NeighborMgmtAddr)

	// Check metadata
	assert.NotNil(t, link.Metadata)
	assert.Equal(t, job.ID, link.Metadata["discovery_id"])
	assert.Equal(t, "unifi-api-port-table", link.Metadata["source"])
	assert.Equal(t, evidenceClassInferredSegment, link.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", link.Metadata["relation_family"])
	assert.Equal(t, apiConfig.BaseURL, link.Metadata["controller_url"])
	assert.Equal(t, site.ID, link.Metadata["site_id"])
	assert.Equal(t, site.Name, link.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, link.Metadata["controller_name"])
}

func TestProcessWirelessClientAssociations(t *testing.T) {
	job := &DiscoveryJob{ID: "test-job"}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	clients := []UniFiClient{
		{
			ID:             "wireless-1",
			Type:           "WIRELESS",
			Name:           "phone",
			MACAddress:     "aa:bb:cc:dd:ee:ff",
			IPAddress:      "192.168.1.50",
			UplinkDeviceID: "ap-1",
			ConnectedAt:    "2026-04-12T00:00:00Z",
			Access:         UniFiClientAccess{Type: "DEFAULT"},
		},
		{
			ID:             "wireless-missing-mac",
			Type:           "WIRELESS",
			UplinkDeviceID: "ap-1",
		},
		{
			ID:             "wireless-missing-ap",
			Type:           "WIRELESS",
			MACAddress:     "11:22:33:44:55:66",
			UplinkDeviceID: "missing-ap",
		},
	}
	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{
		"ap-1": {IP: "192.168.1.233", Name: "UAP-nanoHD", MAC: "ff:ee:dd:cc:bb:aa", DeviceID: GenerateDeviceID("ff:ee:dd:cc:bb:aa")},
	}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: "https://example.com/api"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	links := engine.processWirelessClientAssociations(job, clients, deviceCache, apiConfig, site)
	require.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, "192.168.1.233", link.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("ff:ee:dd:cc:bb:aa"), link.LocalDeviceID)
	assert.Equal(t, "wireless", link.LocalIfName)
	assert.Equal(t, "aa:bb:cc:dd:ee:ff", link.NeighborChassisID)
	assert.Equal(t, "phone", link.NeighborSystemName)
	assert.Equal(t, "192.168.1.50", link.NeighborMgmtAddr)
	assert.Equal(t, "unifi-api-wireless-client", link.Metadata["source"])
	assert.Equal(t, "endpoint-attachment", link.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", link.Metadata["relation_type"])
	assert.Equal(t, "ATTACHED_TO", link.Metadata["relation_family"])
	assert.Equal(t, "controller_client_association", link.Metadata["confidence_reason"])
	assert.Equal(t, "high", link.Metadata["confidence_tier"])
	assert.Equal(t, "DEFAULT", link.Metadata["access_type"])
}

func TestProcessWiredClientAssociations(t *testing.T) {
	job := &DiscoveryJob{ID: "test-job"}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	portIdx := int32(7)
	clients := []UniFiClient{
		{
			ID:             "wired-1",
			Type:           "WIRED",
			Name:           "pve-host",
			MACAddress:     "aa:bb:cc:dd:ee:ff",
			IPAddress:      "192.168.2.11",
			UplinkDeviceID: "switch-1",
			ConnectedAt:    "2026-04-12T00:00:00Z",
			Access:         UniFiClientAccess{Type: "DEFAULT"},
		},
		{
			ID:             "wired-with-port",
			Type:           "WIRED",
			Name:           "nas",
			MACAddress:     "11:22:33:44:55:66",
			IPAddress:      "192.168.1.40",
			UplinkDeviceID: "switch-1",
			UplinkPortIdx:  &portIdx,
		},
		{
			ID:             "wired-missing-mac",
			Type:           "WIRED",
			UplinkDeviceID: "switch-1",
		},
		{
			ID:             "wired-missing-switch",
			Type:           "WIRED",
			MACAddress:     "22:33:44:55:66:77",
			UplinkDeviceID: "missing-switch",
		},
		{
			ID:         "wired-no-uplink",
			Type:       "WIRED",
			MACAddress: "33:44:55:66:77:88",
		},
	}
	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{
		"switch-1": {IP: "192.168.1.131", Name: "USW-24-PoE", MAC: "ff:ee:dd:cc:bb:aa", DeviceID: GenerateDeviceID("ff:ee:dd:cc:bb:aa")},
	}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: "https://example.com/api"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	links := engine.processWiredClientAssociations(job, clients, deviceCache, apiConfig, site)
	require.Len(t, links, 2)

	switchLevel := links[0]
	assert.Equal(t, "UniFi-API", switchLevel.Protocol)
	assert.Equal(t, "192.168.1.131", switchLevel.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("ff:ee:dd:cc:bb:aa"), switchLevel.LocalDeviceID)
	assert.Equal(t, int32(0), switchLevel.LocalIfIndex)
	assert.Empty(t, switchLevel.LocalIfName)
	assert.Equal(t, "aa:bb:cc:dd:ee:ff", switchLevel.NeighborChassisID)
	assert.Equal(t, "pve-host", switchLevel.NeighborSystemName)
	assert.Equal(t, "192.168.2.11", switchLevel.NeighborMgmtAddr)
	assert.Equal(t, "unifi-api-wired-client", switchLevel.Metadata["source"])
	assert.Equal(t, "endpoint-attachment", switchLevel.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", switchLevel.Metadata["relation_type"])
	assert.Equal(t, "ATTACHED_TO", switchLevel.Metadata["relation_family"])
	assert.Equal(t, "medium", switchLevel.Metadata["confidence_tier"])
	assert.Equal(t, "controller_wired_client_switch_level", switchLevel.Metadata["confidence_reason"])
	assert.Equal(t, "switch-1", switchLevel.Metadata["uplink_device_id"])
	assert.Equal(t, "WIRED", switchLevel.Metadata["client_type"])
	assert.Equal(t, "DEFAULT", switchLevel.Metadata["access_type"])
	assert.Equal(t, "2026-04-12T00:00:00Z", switchLevel.Metadata["connected_at"])

	portLevel := links[1]
	assert.Equal(t, int32(7), portLevel.LocalIfIndex)
	assert.Empty(t, portLevel.LocalIfName)
	assert.Equal(t, "11:22:33:44:55:66", portLevel.NeighborChassisID)
	assert.Equal(t, "high", portLevel.Metadata["confidence_tier"])
	assert.Equal(t, "controller_client_association", portLevel.Metadata["confidence_reason"])
}

func TestQuerySingleUniFiAPIIncludesWirelessClientAssociations(t *testing.T) {
	job := &DiscoveryJob{
		ID: "test-job",
		Results: &DiscoveryResults{
			Contract: DiscoveryContract{
				ParseDiagnostics: DiscoveryParseDiagnostics{
					ParseFailures:     make(map[string]int),
					UnknownTopLevel:   make(map[string]int),
					ParserMismatches:  make(map[string]int),
					LastFailureByType: make(map[string]string),
				},
			},
		},
	}

	deviceDetailPayload := []byte(`{"interfaces":{"ports":[{"idx":1,"state":"UP","connector":"RJ45","maxSpeedMbps":1000,"speedMbps":1000}]}}`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sites/site1/devices":
			assertUniFiPageQuery(t, r)
			w.WriteHeader(http.StatusOK)
			err := json.NewEncoder(w).Encode(struct {
				Data []UniFiDevice `json:"data"`
			}{
				Data: []UniFiDevice{
					{ID: "uplink-device", IPAddress: "192.168.1.254", Name: "USW16PoE", MAC: "ff:ee:dd:cc:bb:aa"},
					{ID: "ap-1", IPAddress: "192.168.1.233", Name: "UAP-nanoHD", MAC: "00:11:22:33:44:55", Uplink: UniFiUplink{DeviceID: "uplink-device", LocalPortIdx: 26, LocalPortName: "Port 26"}},
				},
			})
			if err != nil {
				t.Fatalf("encode devices response: %v", err)
			}
		case "/sites/site1/clients":
			assertUniFiPageQuery(t, r)
			w.WriteHeader(http.StatusOK)
			err := json.NewEncoder(w).Encode(struct {
				Data []UniFiClient `json:"data"`
			}{
				Data: []UniFiClient{
					{ID: "wireless-1", Type: "WIRELESS", Name: "tablet", MACAddress: "aa:bb:cc:dd:ee:ff", IPAddress: "192.168.1.50", UplinkDeviceID: "ap-1", Access: UniFiClientAccess{Type: "DEFAULT"}},
					{ID: "wired-1", Type: "WIRED", Name: "wired-host", MACAddress: "11:22:33:44:55:66", IPAddress: "192.168.1.60", UplinkDeviceID: "uplink-device"},
				},
			})
			if err != nil {
				t.Fatalf("encode clients response: %v", err)
			}
		case "/sites/site1/devices/ap-1", "/sites/site1/devices/uplink-device":
			w.WriteHeader(http.StatusOK)
			_, err := w.Write(deviceDetailPayload)
			if err != nil {
				t.Fatalf("write details response: %v", err)
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{config: &Config{Timeout: 30 * time.Second}, logger: logger.NewTestLogger()}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: server.URL, APIKey: "test-api-key"}
	site := UniFiSite{ID: "site1", Name: "Site 1"}

	links, err := engine.querySingleUniFiAPI(context.Background(), job, "", apiConfig, site)
	require.NoError(t, err)
	require.Len(t, links, 3)

	var uplinkLink *TopologyLink
	var wirelessLink *TopologyLink
	var wiredLink *TopologyLink
	for _, link := range links {
		switch link.Metadata["source"] {
		case "unifi-api-uplink":
			uplinkLink = link
		case "unifi-api-wireless-client":
			wirelessLink = link
		case "unifi-api-wired-client":
			wiredLink = link
		}
	}
	require.NotNil(t, uplinkLink)
	require.NotNil(t, wirelessLink)
	require.NotNil(t, wiredLink)
	assert.Equal(t, "192.168.1.233", wirelessLink.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("00:11:22:33:44:55"), wirelessLink.LocalDeviceID)
	assert.Equal(t, "aa:bb:cc:dd:ee:ff", wirelessLink.NeighborChassisID)
	assert.Equal(t, "192.168.1.50", wirelessLink.NeighborMgmtAddr)
	assert.Equal(t, "endpoint-attachment", wirelessLink.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", wirelessLink.Metadata["relation_family"])

	assert.Equal(t, "192.168.1.254", wiredLink.LocalDeviceIP)
	assert.Equal(t, GenerateDeviceID("ff:ee:dd:cc:bb:aa"), wiredLink.LocalDeviceID)
	assert.Equal(t, int32(0), wiredLink.LocalIfIndex)
	assert.Empty(t, wiredLink.LocalIfName)
	assert.Equal(t, "11:22:33:44:55:66", wiredLink.NeighborChassisID)
	assert.Equal(t, "wired-host", wiredLink.NeighborSystemName)
	assert.Equal(t, "192.168.1.60", wiredLink.NeighborMgmtAddr)
	assert.Equal(t, "endpoint-attachment", wiredLink.Metadata["evidence_class"])
	assert.Equal(t, "ATTACHED_TO", wiredLink.Metadata["relation_family"])
	assert.Equal(t, "medium", wiredLink.Metadata["confidence_tier"])
	assert.Equal(t, "controller_wired_client_switch_level", wiredLink.Metadata["confidence_reason"])
}

func TestProcessUplinkInfo(t *testing.T) {
	// Create test data
	device := &UniFiDevice{
		ID:        "device1",
		IPAddress: "192.168.1.1",
		Name:      "Device 1",
		MAC:       "00:11:22:33:44:55",
		Uplink: UniFiUplink{
			DeviceID:      "uplink-device",
			LocalPortIdx:  26,
			LocalPortName: "Port 26",
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
	links := engine.processUplinkInfo(job, device, nil, deviceCache, apiConfig, site)

	// Check results
	assert.NotNil(t, links)
	assert.Len(t, links, 1)

	link := links[0]
	assert.Equal(t, "UniFi-API", link.Protocol)
	assert.Equal(t, deviceCache["uplink-device"].IP, link.LocalDeviceIP)
	assert.Equal(t, deviceCache["uplink-device"].DeviceID, link.LocalDeviceID)
	assert.Equal(t, int32(26), link.LocalIfIndex)
	assert.Equal(t, "Port 26", link.LocalIfName)
	assert.Equal(t, device.MAC, link.NeighborChassisID)
	assert.Equal(t, device.Name, link.NeighborSystemName)
	assert.Equal(t, device.IPAddress, link.NeighborMgmtAddr)

	// Check metadata
	assert.NotNil(t, link.Metadata)
	assert.Equal(t, job.ID, link.Metadata["discovery_id"])
	assert.Equal(t, "unifi-api-uplink", link.Metadata["source"])
	assert.Equal(t, evidenceClassDirectPhysical, link.Metadata["evidence_class"])
	assert.Equal(t, "CONNECTS_TO", link.Metadata["relation_family"])
	assert.Equal(t, apiConfig.BaseURL, link.Metadata["controller_url"])
	assert.Equal(t, site.ID, link.Metadata["site_id"])
	assert.Equal(t, site.Name, link.Metadata["site_name"])
	assert.Equal(t, apiConfig.Name, link.Metadata["controller_name"])
	assert.Equal(t, "uplink-device", link.Metadata["uplink_device_id"])
	assert.Equal(t, deviceCache["uplink-device"].Name, link.Metadata["uplink_device_name"])
}

func TestUniFiDeviceDetailsCamelCaseCompatibility(t *testing.T) {
	raw := []byte(`{
		"lldpTable": [{
			"localPortIdx": 26,
			"localPortName": "Port 26",
			"chassisId": "d0:21:f9:00:00:01",
			"portId": "26",
			"portDescription": "SFP+",
			"systemName": "USWAggregation",
			"managementAddr": "192.168.1.87"
		}],
		"portTable": [{
			"portIdx": 22,
			"name": "Port 22",
			"connectedDevice": {
				"macAddress": "d0:21:f9:00:00:02",
				"name": "Nano HD",
				"ipAddress": "192.168.1.233"
			}
		}],
		"uplink": {
			"deviceId": "uplink-device",
			"localPortIdx": 26,
			"localPortName": "Port 26"
		}
	}`)

	var details UniFiDeviceDetails
	require.NoError(t, json.Unmarshal(raw, &details))

	lldp := details.normalizedLLDPTable()
	require.Len(t, lldp, 1)
	assert.Equal(t, int32(26), lldp[0].ifIndex())
	assert.Equal(t, "Port 26", lldp[0].ifName())
	assert.Equal(t, "192.168.1.87", lldp[0].mgmtAddr())

	ports := details.normalizedPortTable()
	require.Len(t, ports, 1)
	peer := ports[0].connected()
	assert.Equal(t, "d0:21:f9:00:00:02", peer.mac())
	assert.Equal(t, "192.168.1.233", peer.ip())

	assert.Equal(t, "uplink-device", details.Uplink.upstreamDeviceID())
	assert.Equal(t, int32(26), details.Uplink.parentPortIndex())
	assert.Equal(t, "Port 26", details.Uplink.parentPortName())
}

func TestUniFiUplinkParentPortIndexAllowsZero(t *testing.T) {
	raw := []byte(`{
		"deviceId": "uplink-device",
		"parentPortIdx": 0
	}`)

	var uplink UniFiUplink
	require.NoError(t, json.Unmarshal(raw, &uplink))

	assert.True(t, uplink.parentPortIndexPresent())
	assert.Equal(t, int32(0), uplink.parentPortIndex())
}

func TestProcessUplinkInfoLabelsZeroParentPort(t *testing.T) {
	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{
		"uplink-device": {
			IP:       "192.168.1.10",
			Name:     "Core Switch",
			MAC:      "00:11:22:33:44:55",
			DeviceID: "device-uplink",
		},
	}
	raw := []byte(`{"deviceId":"uplink-device","parentPortIdx":0}`)
	var uplink UniFiUplink
	require.NoError(t, json.Unmarshal(raw, &uplink))

	links := (&DiscoveryEngine{}).processUplinkInfo(
		&DiscoveryJob{ID: "job-zero-port"},
		&UniFiDevice{
			ID:        "ap-1",
			IPAddress: "192.168.1.20",
			Name:      "AP",
			MAC:       "aa:bb:cc:dd:ee:ff",
			Uplink:    uplink,
		},
		nil,
		deviceCache,
		UniFiAPIConfig{Name: "controller", BaseURL: "https://unifi.example"},
		UniFiSite{ID: "site-1", Name: "Default"},
	)

	require.Len(t, links, 1)
	assert.Equal(t, int32(0), links[0].LocalIfIndex)
	assert.Equal(t, "Port 0", links[0].LocalIfName)
}

func TestParseUniFiDeviceDetailsWithAdaptersFixtures(t *testing.T) {
	engine := &DiscoveryEngine{
		logger: logger.NewTestLogger(),
	}

	newJob := func() *DiscoveryJob {
		return &DiscoveryJob{
			ID: "job-fixture",
			Results: &DiscoveryResults{
				Contract: DiscoveryContract{
					ParseDiagnostics: DiscoveryParseDiagnostics{
						ParseFailures:     make(map[string]int),
						UnknownTopLevel:   make(map[string]int),
						ParserMismatches:  make(map[string]int),
						LastFailureByType: make(map[string]string),
					},
				},
			},
		}
	}

	t.Run("direct fixture", func(t *testing.T) {
		body, err := os.ReadFile(filepath.Join("testdata", "unifi", "detail_direct.json"))
		require.NoError(t, err)

		details, parseErr := engine.parseUniFiDeviceDetailsWithAdapters(newJob(), body)
		require.NoError(t, parseErr)
		require.NotNil(t, details)
		assert.Equal(t, unifiDetailAdapterV1Direct, details.AdapterVersion)
		assert.Equal(t, "direct", details.AdapterShape)
		assert.True(t, hasUniFiTopologySignals(details))
	})

	t.Run("wrapped data fixture", func(t *testing.T) {
		body, err := os.ReadFile(filepath.Join("testdata", "unifi", "detail_wrapped_data.json"))
		require.NoError(t, err)

		details, parseErr := engine.parseUniFiDeviceDetailsWithAdapters(newJob(), body)
		require.NoError(t, parseErr)
		require.NotNil(t, details)
		assert.Equal(t, unifiDetailAdapterV1WrappedData, details.AdapterVersion)
		assert.Equal(t, "wrapped_data", details.AdapterShape)
		assert.True(t, hasUniFiTopologySignals(details))
	})

	t.Run("direct interfaces fixture accepted without topology signals", func(t *testing.T) {
		job := newJob()
		body := []byte(`{
			"id": "device1",
			"ipAddress": "192.168.1.1",
			"name": "Device 1",
			"macAddress": "00:11:22:33:44:55",
			"model": "UDM Pro Max",
			"supported": true,
			"interfaces": {
				"ports": [
					{"idx":1,"state":"UP","connector":"RJ45","maxSpeedMbps":1000,"speedMbps":1000}
				]
			}
		}`)

		details, parseErr := engine.parseUniFiDeviceDetailsWithAdapters(job, body)
		require.NoError(t, parseErr)
		require.NotNil(t, details)
		assert.Equal(t, unifiDetailAdapterV1Direct, details.AdapterVersion)
		assert.Equal(t, "direct", details.AdapterShape)
		assert.False(t, hasUniFiTopologySignals(details))
		require.Len(t, details.Interfaces.Ports, 1)
		assert.Zero(t, job.Results.Contract.ParseDiagnostics.ParserMismatches["unifi.detail.quarantined"])
	})

	t.Run("drift fixture quarantined", func(t *testing.T) {
		job := newJob()
		body, err := os.ReadFile(filepath.Join("testdata", "unifi", "detail_drifted.json"))
		require.NoError(t, err)

		details, parseErr := engine.parseUniFiDeviceDetailsWithAdapters(job, body)
		require.Error(t, parseErr)
		require.ErrorIs(t, parseErr, ErrUniFiPayloadDriftQuarantined)
		assert.Nil(t, details)
		assert.Positive(t, job.Results.Contract.ParseDiagnostics.ParserMismatches["unifi.detail.quarantined"])
		assert.NotEmpty(t, job.Results.Contract.ParseDiagnostics.UnknownTopLevel)
	})
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
			AgentID:   "agent1",
			GatewayID: "gateway1",
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

func TestCreateDiscoveredDeviceAliasesControllerHostForGateway(t *testing.T) {
	t.Parallel()

	device := &UniFiDevice{
		ID:        "62cdf205-fe09-3ceb-9e57-950b6e956104",
		IPAddress: "152.117.116.178",
		Name:      "farm01",
		MAC:       "f4:92:bf:75:c7:21",
	}
	apiConfig := UniFiAPIConfig{
		Name:    "farm01",
		BaseURL: "https://192.168.1.1/proxy/network/integration/v1",
	}
	site := UniFiSite{ID: "site1", Name: "Default"}
	job := &DiscoveryJob{ID: "test-job", Params: &DiscoveryParams{}}

	result := (&DiscoveryEngine{logger: logger.NewTestLogger()}).
		createDiscoveredDevice(job, device, apiConfig, site)

	require.NotNil(t, result)
	assert.Equal(t, "152.117.116.178", result.IP)
	assert.Equal(t, "1", result.Metadata["alt_ip:192.168.1.1"])
	assert.Contains(t, result.Metadata, "ip_alias:192.168.1.1")
}

func TestAddOrUpdateDeviceAttachesSNMPSeedToUniFiGatewayAlias(t *testing.T) {
	t.Parallel()

	existing := &DiscoveredDevice{
		DeviceID: "mac-f492bf75c721",
		IP:       "152.117.116.178",
		MAC:      "f4:92:bf:75:c7:21",
		Hostname: "farm01",
		Metadata: map[string]string{
			"source":               "unifi-api",
			"controller_url":       "https://192.168.1.1/proxy/network/integration/v1",
			"controller_name":      "farm01",
			"alt_ip:192.168.1.1":   "1",
			"ip_alias:192.168.1.1": "",
		},
	}

	job := &DiscoveryJob{
		ID:      "job-1",
		Results: &DiscoveryResults{Devices: []*DiscoveredDevice{existing}},
		deviceMap: map[string]*DeviceInterfaceMap{
			existing.DeviceID: {
				DeviceID: existing.DeviceID,
				IPs:      map[string]struct{}{existing.IP: {}, "192.168.1.1": {}},
				MACs:     map[string]struct{}{existing.MAC: {}},
			},
		},
	}

	incomingSNMP := &DiscoveredDevice{
		DeviceID: "mac-f692bf75c721",
		IP:       "192.168.1.1",
		MAC:      "f6:92:bf:75:c7:21",
		Hostname: "farm01",
		Metadata: map[string]string{"source": "snmp"},
	}

	(&DiscoveryEngine{logger: logger.NewTestLogger()}).
		addOrUpdateDeviceToResults(job, incomingSNMP)

	require.Len(t, job.Results.Devices, 1)
	assert.Equal(t, "mac-f492bf75c721", job.Results.Devices[0].DeviceID)
	assert.Equal(t, "f4:92:bf:75:c7:21", job.Results.Devices[0].MAC)
	assert.Equal(t, "1", job.Results.Devices[0].Metadata["alt_mac:f692bf75c721"])
	assert.Equal(t, "1", job.Results.Devices[0].Metadata["alt_ip:192.168.1.1"])
}

func TestUniFiLinkDedupKeyIncludesChassisAndPortWhenMgmtAddrMissing(t *testing.T) {
	t.Parallel()

	linkA := &TopologyLink{
		Protocol:          "LLDP",
		LocalDeviceIP:     "192.168.1.87",
		LocalDeviceID:     "mac-aabbccddeeff",
		LocalIfIndex:      5,
		NeighborMgmtAddr:  "",
		NeighborChassisID: "aa:aa:aa:aa:aa:01",
		NeighborPortID:    "port-1",
	}

	linkB := &TopologyLink{
		Protocol:          "LLDP",
		LocalDeviceIP:     "192.168.1.87",
		LocalDeviceID:     "mac-aabbccddeeff",
		LocalIfIndex:      5,
		NeighborMgmtAddr:  "",
		NeighborChassisID: "aa:aa:aa:aa:aa:02",
		NeighborPortID:    "port-2",
	}

	keyA := uniFiLinkDedupKey(linkA, "site-1")
	keyB := uniFiLinkDedupKey(linkB, "site-1")

	assert.NotEqual(t, keyA, keyB)
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

// TestProcessPortTableRealControllerShapes pins the "port_links:0" diagnosis
// (fix-topology-evidence-pipeline-resilience, task 3.4).
//
// processPortTable can only emit a wired attachment link when a port_table
// entry carries a `connected_device` / `connectedDevice` peer object
// (UniFiPortConnectedPeer). Neither UniFi API family sends that field:
//
//   - the Integration API v1 device detail (GET {base}/sites/{site}/devices/{id})
//     exposes `interfaces.ports[]` (idx/state/connector/speedMbps/poe) with no
//     per-port peer information at all, and
//   - the legacy controller endpoint (GET /api/s/{site}/stat/device) returns
//     `port_table[]` entries whose learned client MACs live in `mac_table[]`
//     ({mac, ip, vlan, age, uptime}) and whose switch peers live in
//     `lldp_table` — there is no `connected_device` key.
//
// So on live controllers port extraction always yields zero links while the
// wireless-client (/clients uplinkDeviceId) and uplink paths work — matching
// the demo evidence `port_links:0, wireless_client_links:35, uplink_links:10`.
//
// Fixing wired extraction means consuming the legacy `mac_table` (with uplink
// port filtering) and is owned by the add-unifi-wifi-discovery-parity change;
// it needs a live `stat/device` capture to confirm the mac_table shape for the
// deployed controller version before implementation. These fixtures pin the
// current behavior so the eventual fix flips them deliberately.
func TestProcessPortTableRealControllerShapes(t *testing.T) {
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	job := &DiscoveryJob{ID: "port-table-diagnosis"}
	device := &UniFiDevice{IPAddress: "192.168.1.87", Name: "USW-Pro-24", MAC: "d0:21:f9:00:00:01"}
	apiConfig := UniFiAPIConfig{Name: "Test API", BaseURL: "https://example.com/proxy/network/integration/v1"}
	site := UniFiSite{ID: "site1", Name: "Default"}

	deviceCache := map[string]struct {
		IP       string
		Name     string
		MAC      string
		DeviceID string
	}{}

	t.Run("integration API v1 interfaces.ports shape yields zero port links", func(t *testing.T) {
		raw := []byte(`{
			"id": "abcd1234",
			"name": "USW-Pro-24",
			"macAddress": "d0:21:f9:00:00:01",
			"ipAddress": "192.168.1.87",
			"state": "ONLINE",
			"interfaces": {
				"ports": [
					{"idx": 1, "state": "UP", "connector": "RJ45", "maxSpeedMbps": 1000, "speedMbps": 1000},
					{"idx": 2, "state": "UP", "connector": "RJ45", "maxSpeedMbps": 1000, "speedMbps": 100}
				],
				"radios": []
			}
		}`)

		var details UniFiDeviceDetails
		require.NoError(t, json.Unmarshal(raw, &details))

		// The v1 shape has no port_table at all — nothing to extract from.
		assert.Empty(t, details.normalizedPortTable())

		links := engine.processPortTable(job, device, "device-id-1", &details, deviceCache, apiConfig, site)
		assert.Empty(t, links)
	})

	t.Run("legacy stat/device port_table with mac_table yields zero port links", func(t *testing.T) {
		raw := []byte(`{
			"mac": "d0:21:f9:00:00:01",
			"ip": "192.168.1.87",
			"name": "USW-Pro-24",
			"port_table": [
				{
					"port_idx": 7,
					"name": "Port 7",
					"media": "GE",
					"up": true,
					"speed": 1000,
					"mac_table": [
						{"mac": "aa:bb:cc:dd:ee:50", "ip": "192.168.1.50", "vlan": 1, "age": 12, "uptime": 4711},
						{"mac": "aa:bb:cc:dd:ee:51", "ip": "192.168.1.51", "vlan": 1, "age": 3, "uptime": 99}
					]
				},
				{
					"port_idx": 8,
					"name": "Port 8",
					"media": "GE",
					"up": true,
					"speed": 1000,
					"lldp_table": [
						{"chassis_id": "d0:21:f9:00:00:02", "port_id": "26", "system_name": "USWAggregation"}
					]
				}
			]
		}`)

		var record legacyUniFiDeviceDetailsRecord
		require.NoError(t, json.Unmarshal(raw, &record))
		details := record.UniFiDeviceDetails

		// The legacy entries parse, but their peers live in mac_table /
		// lldp_table, which processPortTable never reads: connected() is empty
		// for every entry, so no link is emitted.
		ports := details.normalizedPortTable()
		require.Len(t, ports, 2)

		for i := range ports {
			peer := ports[i].connected()
			assert.Empty(t, peer.mac())
			assert.Empty(t, peer.ip())
		}

		links := engine.processPortTable(job, device, "device-id-1", &details, deviceCache, apiConfig, site)
		assert.Empty(t, links)
	})
}
