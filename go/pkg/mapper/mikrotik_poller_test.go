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
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestQueryMikroTikDevices(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		username, password, ok := r.BasicAuth()
		if !assert.True(t, ok) {
			http.Error(w, "missing auth", http.StatusUnauthorized)
			return
		}
		assert.Equal(t, "admin", username)
		assert.Equal(t, "secret", password)

		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/rest/system/identity":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "chr-demo"})
		case "/rest/system/resource":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"version":           "7.16.1",
				"architecture-name": "x86_64",
				"board-name":        "CHR",
				"uptime":            "1d2h3m4s",
			})
		case "/rest/system/routerboard":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"model":         "CHR",
				"serial-number": "ABC123",
			})
		case "/rest/interface":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					".id":         "*2",
					"name":        "ether1",
					"type":        "ether",
					"mac-address": "00:11:22:33:44:55",
					"running":     true,
					"disabled":    false,
					"comment":     "WAN uplink",
				},
			})
		case "/rest/ip/address":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"interface": "ether1",
					"address":   "192.168.88.2/24",
				},
			})
		case "/rest/interface/bridge/port":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"interface": "ether1",
					"bridge":    "bridge1",
					"pvid":      "1",
				},
			})
		case "/rest/interface/bridge/vlan":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"vlan-ids": "10",
					"tagged":   "bridge1",
					"untagged": "ether1",
				},
			})
		case "/rest/ip/neighbor":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"interface":   "ether1",
					"address":     "192.168.88.3",
					"identity":    "switch-1",
					"mac-address": "aa:bb:cc:dd:ee:ff",
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
			MikroTikAPIs: []MikroTikAPIConfig{
				{
					BaseURL:  server.URL + "/rest",
					Username: "admin",
					Password: "secret",
					Name:     "chr-demo",
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID: "test-job",
		Params: &DiscoveryParams{
			Options: map[string]string{
				"mikrotik_api_names": "chr-demo",
			},
		},
	}

	devices, interfaces, links, err := engine.queryMikroTikDevices(context.Background(), job)
	require.NoError(t, err)
	require.Len(t, devices, 1)
	require.Len(t, interfaces, 1)
	require.Len(t, links, 1)

	assert.Equal(t, "chr-demo", devices[0].Hostname)
	assert.Equal(t, "MikroTik RouterOS CHR 7.16.1", devices[0].SysDescr)
	assert.Equal(t, "001122334455", devices[0].MAC)
	assert.Equal(t, "127.0.0.1", devices[0].IP)
	assert.Equal(t, "mikrotik-api", devices[0].Metadata["source"])
	assert.Equal(t, "ABC123", devices[0].Metadata["serial_number"])

	assert.Equal(t, "ether1", interfaces[0].IfName)
	assert.Equal(t, int32(2), interfaces[0].IfIndex)
	assert.Equal(t, "bridge1", interfaces[0].Metadata["bridge_name"])
	assert.Equal(t, []string{"192.168.88.2"}, interfaces[0].IPAddresses)

	assert.Equal(t, "MikroTik-API", links[0].Protocol)
	assert.Equal(t, "switch-1", links[0].NeighborSystemName)
	assert.Equal(t, "192.168.88.3", links[0].NeighborMgmtAddr)
	assert.Equal(t, "mikrotik-api-neighbor", links[0].Metadata["source"])
}

func TestQueryMikroTikDevicesIgnoresUnsupportedRouterboardEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/rest/system/identity":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "chr-demo"})
		case "/rest/system/resource":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"version":           "7.21.3",
				"architecture-name": "x86_64",
				"board-name":        "CHR QEMU Standard PC (i440FX + PIIX, 1996)",
				"uptime":            "15h46m34s",
			})
		case "/rest/system/routerboard":
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"detail":"no such command or directory (routerboard)","error":400,"message":"Bad Request"}`))
		case "/rest/interface":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					".id":         "*2",
					"name":        "ether1",
					"type":        "ether",
					"mac-address": "00:11:22:33:44:55",
					"running":     true,
					"disabled":    false,
				},
				{
					".id":         "*1",
					"name":        "lo",
					"type":        "loopback",
					"mac-address": "00:00:00:00:00:00",
					"running":     true,
					"disabled":    false,
				},
			})
		case "/rest/ip/address":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{
					"interface": "ether1",
					"address":   "192.168.6.167/24",
				},
			})
		case "/rest/interface/bridge/port":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		case "/rest/interface/bridge/vlan":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		case "/rest/ip/neighbor":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
			MikroTikAPIs: []MikroTikAPIConfig{
				{
					BaseURL:  server.URL + "/rest",
					Username: "admin",
					Password: "secret",
					Name:     "chr-demo",
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID: "test-job",
		Params: &DiscoveryParams{
			Options: map[string]string{
				"mikrotik_api_names": "chr-demo",
			},
		},
	}

	devices, interfaces, links, err := engine.queryMikroTikDevices(context.Background(), job)
	require.NoError(t, err)
	require.Len(t, devices, 1)
	require.Len(t, interfaces, 2)
	require.Empty(t, links)

	assert.Equal(t, int32(2), interfaces[0].IfIndex)
	assert.Equal(t, int32(1), interfaces[1].IfIndex)
	assert.Equal(t, "MikroTik RouterOS CHR QEMU Standard PC (i440FX + PIIX, 1996) 7.21.3", devices[0].SysDescr)
	assert.Equal(t, "mikrotik-api", devices[0].Metadata["source"])
	assert.Empty(t, devices[0].Metadata["serial_number"])
}
