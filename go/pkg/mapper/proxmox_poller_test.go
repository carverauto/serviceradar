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

func TestQueryProxmoxDevices(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "PVEAPIToken=svc@pve!codex=secret-token", r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/api2/json/nodes":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{"node": "tonka01"},
				},
			})
		case "/api2/json/cluster/resources":
			assert.Equal(t, "vm", r.URL.Query().Get("type"))
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{
						"type":   "qemu",
						"vmid":   197,
						"name":   "vJunos-Lab-01.lab.carverauto.dev",
						"node":   "tonka01",
						"status": "running",
					},
					{
						"type":     "qemu",
						"vmid":     900,
						"name":     "tmpl-router",
						"node":     "tonka01",
						"status":   "stopped",
						"template": 1,
					},
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
			ProxmoxAPIs: []ProxmoxAPIConfig{
				{
					BaseURL:     server.URL,
					TokenID:     "svc@pve!codex",
					TokenSecret: "secret-token",
					Name:        "tonka01-pve",
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID: "test-job",
		Params: &DiscoveryParams{
			Options: map[string]string{
				"proxmox_api_names": "tonka01-pve",
			},
		},
	}

	devices, links, err := engine.queryProxmoxDevices(context.Background(), job)
	require.NoError(t, err)
	require.Len(t, devices, 2)
	require.Len(t, links, 1)

	assert.Equal(t, "tonka01", devices[0].Hostname)
	assert.Equal(t, GenerateDeviceIDFromIP("127.0.0.1"), devices[0].DeviceID)
	assert.Equal(t, "hypervisor", devices[0].Metadata["device_role"])

	assert.Equal(t, "vJunos-Lab-01.lab.carverauto.dev", devices[1].Hostname)
	assert.Equal(t, "provisional", devices[1].Metadata["identity_state"])
	assert.Equal(t, "false", devices[1].Metadata["snmp_target_eligible"])

	assert.Equal(t, "Proxmox-API", links[0].Protocol)
	assert.Equal(t, "hosted-guests", links[0].LocalIfName)
	assert.Equal(t, "vJunos-Lab-01.lab.carverauto.dev", links[0].NeighborSystemName)
	require.NotNil(t, links[0].NeighborIdentity)
	assert.Equal(t, devices[1].DeviceID, links[0].NeighborIdentity.DeviceID)
	assert.Equal(t, "proxmox-api", links[0].Metadata["source"])
}

func TestProxmoxCandidateFingerprintFromHTML(t *testing.T) {
	html := `<!DOCTYPE html><html><head><title>pve01 - Proxmox Virtual Environment</title></head><body></body></html>`

	node, ok := proxmoxFingerprintFromHTML(html)

	require.True(t, ok)
	assert.Equal(t, "pve01", node)
}

func TestProxmoxCandidateFingerprintRejectsGenericHTTPS(t *testing.T) {
	node, ok := proxmoxFingerprintFromHTML(`<!DOCTYPE html><title>router</title>`)

	require.False(t, ok)
	assert.Empty(t, node)
}

func TestProxmoxCandidateBaseURL(t *testing.T) {
	assert.Equal(t, "https://192.0.2.10:8006", proxmoxCandidateBaseURL("192.0.2.10"))
	assert.Equal(t, "https://192.0.2.10:8006", proxmoxCandidateBaseURL("https://192.0.2.10:8006/"))
	assert.Equal(t, "https://[2001:db8::10]:8006", proxmoxCandidateBaseURL("[2001:db8::10]:8006"))
}

func TestBuildProxmoxCandidateDevice(t *testing.T) {
	device := buildProxmoxCandidateDevice("192.0.2.10", "pve01")

	require.NotNil(t, device)
	assert.Equal(t, GenerateDeviceIDFromIP("192.0.2.10"), device.DeviceID)
	assert.Equal(t, "192.0.2.10", device.IP)
	assert.Equal(t, "pve01", device.Hostname)
	assert.Equal(t, "proxmox-candidate", device.Metadata["source"])
	assert.Equal(t, "true", device.Metadata["proxmox_candidate"])
	assert.Equal(t, "false", device.Metadata["snmp_target_eligible"])
}

func TestProxmoxCandidateSeedsFromJobUsesKnownDeviceIPs(t *testing.T) {
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{IP: "192.0.2.10"},
				{IP: ""},
				nil,
				{IP: "192.0.2.10"},
				{IP: "192.0.2.11"},
			},
		},
	}

	assert.Equal(t, []string{"192.0.2.10", "192.0.2.11"}, proxmoxCandidateSeedsFromJob(job))
}

func TestApplyJobOptionsMetadataSkipsProxmoxCandidateProbeOption(t *testing.T) {
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Options: map[string]string{
				"mapper_job_name":           "tonka01",
				proxmoxCandidateProbeOption: "true",
			},
		},
	}
	metadata := map[string]string{}

	applyJobOptionsMetadata(job, metadata)

	assert.Equal(t, "tonka01", metadata["mapper_job_name"])
	assert.NotContains(t, metadata, proxmoxCandidateProbeOption)
}
