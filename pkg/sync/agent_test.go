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
	"go.uber.org/mock/gomock"
)

func TestSyncPoller_GetStatus_NoResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	syncer := &SyncPoller{
		config: Config{
			AgentID: "test-agent",
		},
		lastSyncResults: nil,
	}

	req := &proto.StatusRequest{
		ServiceName: "netbox-sync",
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
	assert.Equal(t, "No sync results available yet", response["message"])
	assert.Equal(t, []interface{}{}, response["hosts"])
}

func TestSyncPoller_GetStatus_WithResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	hostname1 := "proxmox-06"
	hostname2 := "proxmox-07"
	mac1 := "00:50:56:12:34:56"

	sweepResults := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DiscoverySource: "netbox",
			IP:              "192.168.2.18",
			MAC:             &mac1,
			Hostname:        &hostname1,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata: map[string]string{
				"netbox_device_id": "6",
				"role":             "hypervisors",
				"site":             "carver",
			},
		},
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DiscoverySource: "netbox",
			IP:              "192.168.2.19",
			MAC:             nil,
			Hostname:        &hostname2,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata: map[string]string{
				"netbox_device_id": "7",
				"role":             "hypervisors",
				"site":             "carver",
			},
		},
	}

	syncer := &SyncPoller{
		config: Config{
			AgentID: "test-agent",
		},
		lastSyncResults: sweepResults,
	}

	req := &proto.StatusRequest{
		ServiceName: "netbox-sync",
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
	assert.Equal(t, "Discovery sync completed", response["message"])

	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	assert.Len(t, hosts, 2)

	// Check first host
	host1, ok := hosts[0].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "192.168.2.18", host1["host"])
	assert.Equal(t, true, host1["available"])
	assert.Equal(t, "00:50:56:12:34:56", host1["mac"])
	assert.Equal(t, "proxmox-06", host1["hostname"])

	metadata1, ok := host1["metadata"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "6", metadata1["netbox_device_id"])
	assert.Equal(t, "hypervisors", metadata1["role"])

	// Check second host (no MAC)
	host2, ok := hosts[1].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "192.168.2.19", host2["host"])
	assert.Equal(t, true, host2["available"])
	assert.Equal(t, "proxmox-07", host2["hostname"])
	assert.NotContains(t, host2, "mac") // Should not be present when nil
}

func TestSyncPoller_GetStatus_WithUnavailableHosts(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	hostname := "offline-device"

	sweepResults := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DiscoverySource: "netbox",
			IP:              "192.168.2.100",
			MAC:             nil,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
			Available:       false, // Device is offline
			Metadata: map[string]string{
				"netbox_device_id": "100",
				"role":             "servers",
				"site":             "carver",
			},
		},
	}

	syncer := &SyncPoller{
		config: Config{
			AgentID: "test-agent",
		},
		lastSyncResults: sweepResults,
	}

	req := &proto.StatusRequest{
		ServiceName: "netbox-sync",
		ServiceType: "sweep",
	}

	resp, err := syncer.GetStatus(context.Background(), req)
	require.NoError(t, err)

	// Parse the response message
	var response map[string]interface{}
	err = json.Unmarshal(resp.Message, &response)
	require.NoError(t, err)

	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	assert.Len(t, hosts, 1)

	host, ok := hosts[0].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "192.168.2.100", host["host"])
	assert.Equal(t, false, host["available"]) // Should preserve unavailable status
}

func TestSync_StoresResultsForGetStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockInteg := NewMockIntegration(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "https://netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "token"},
			},
		},
		AgentID:      "test-agent",
		PollerID:     "test-poller",
		KVAddress:    "localhost:50051",
		PollInterval: models.Duration(1 * time.Second),
		StreamName:   "devices",
		Subject:      "discovery.devices",
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockInteg
		},
	}

	// Create test sweep results
	hostname := "test-device"
	mac := "00:50:56:12:34:56"
	sweepResults := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DiscoverySource: "netbox",
			IP:              "192.168.1.100",
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata: map[string]string{
				"netbox_device_id": "123",
				"role":             "servers",
			},
		},
	}

	data := map[string][]byte{"test": []byte("data")}

	// Mock the integration to return our test data
	mockInteg.EXPECT().Fetch(gomock.Any()).Return(data, sweepResults, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), gomock.Any(), gomock.Any()).Return(&proto.PutManyResponse{}, nil)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, nil)
	require.NoError(t, err)

	// Verify no results initially
	assert.Len(t, syncer.lastSyncResults, 0)

	// Run sync
	err = syncer.Sync(context.Background())
	require.NoError(t, err)

	// Verify results are stored
	assert.Len(t, syncer.lastSyncResults, 1)
	assert.Equal(t, "192.168.1.100", syncer.lastSyncResults[0].IP)
	assert.Equal(t, "netbox", syncer.lastSyncResults[0].DiscoverySource)

	// Verify GetStatus returns the stored results
	req := &proto.StatusRequest{
		ServiceName: "netbox-sync",
		ServiceType: "sweep",
	}

	resp, err := syncer.GetStatus(context.Background(), req)
	require.NoError(t, err)

	var response map[string]interface{}
	err = json.Unmarshal(resp.Message, &response)
	require.NoError(t, err)

	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	assert.Len(t, hosts, 1)

	host, ok := hosts[0].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "192.168.1.100", host["host"])
	assert.Equal(t, "test-device", host["hostname"])
	assert.Equal(t, "00:50:56:12:34:56", host["mac"])
}

func TestSync_MultipleSources_CombinesResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockKV := NewMockKVClient(ctrl)
	mockGRPC := NewMockGRPCClient(ctrl)
	mockNetbox := NewMockIntegration(ctrl)
	mockArmis := NewMockIntegration(ctrl)

	mockGRPC.EXPECT().GetConnection().Return(nil).AnyTimes()

	c := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "https://netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "token"},
			},
			"armis": {
				Type:        "armis",
				Endpoint:    "https://armis.example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		AgentID:      "test-agent",
		PollerID:     "test-poller",
		KVAddress:    "localhost:50051",
		PollInterval: models.Duration(1 * time.Second),
		StreamName:   "devices",
		Subject:      "discovery.devices",
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockNetbox
		},
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return mockArmis
		},
	}

	// Create test results from both sources
	hostname1 := "netbox-device"
	hostname2 := "armis-device"

	netboxResults := []*models.SweepResult{
		{
			IP:              "192.168.1.1",
			Hostname:        &hostname1,
			DiscoverySource: "netbox",
			Available:       true,
		},
	}

	armisResults := []*models.SweepResult{
		{
			IP:              "192.168.1.2",
			Hostname:        &hostname2,
			DiscoverySource: "armis",
			Available:       true,
		},
	}

	// Mock both integrations
	mockNetbox.EXPECT().Fetch(gomock.Any()).Return(map[string][]byte{"netbox": []byte("data")}, netboxResults, nil)
	mockArmis.EXPECT().Fetch(gomock.Any()).Return(map[string][]byte{"armis": []byte("data")}, armisResults, nil)
	mockKV.EXPECT().PutMany(gomock.Any(), gomock.Any(), gomock.Any()).Return(&proto.PutManyResponse{}, nil).Times(2)

	syncer, err := New(context.Background(), c, mockKV, nil, nil, registry, nil, nil)
	require.NoError(t, err)

	// Run sync
	err = syncer.Sync(context.Background())
	require.NoError(t, err)

	// Verify results from both sources are combined
	assert.Len(t, syncer.lastSyncResults, 2)

	// Check that we have results from both sources
	var netboxFound, armisFound bool
	for _, result := range syncer.lastSyncResults {
		if result.DiscoverySource == "netbox" {
			netboxFound = true
			assert.Equal(t, "192.168.1.1", result.IP)
		}
		if result.DiscoverySource == "armis" {
			armisFound = true
			assert.Equal(t, "192.168.1.2", result.IP)
		}
	}
	assert.True(t, netboxFound, "Should have netbox results")
	assert.True(t, armisFound, "Should have armis results")
}