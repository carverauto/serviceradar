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
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

var (
	errMockDB = errors.New("mock db error")
)

func TestNewProtonPublisher(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	tests := []struct {
		name        string
		dbService   db.Service
		config      *StreamConfig
		expectError bool
	}{
		{
			name:        "nil db service",
			dbService:   nil,
			config:      &StreamConfig{},
			expectError: true,
		},
		{
			name:        "valid db service",
			dbService:   mockDB,
			config:      &StreamConfig{},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			publisher, err := NewProtonPublisher(tt.dbService, tt.config)

			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, publisher)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, publisher)
			}
		})
	}
}

func TestPublishDevice(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	ctx := context.Background()
	device := &DiscoveredDevice{
		DeviceID:    "test-device",
		IP:          "192.168.1.1",
		MAC:         "00:11:22:33:44:55",
		Hostname:    "test-host",
		SysDescr:    "Test System",
		SysObjectID: "1.2.3.4",
		SysContact:  "admin",
		SysLocation: "datacenter",
		Uptime:      12345,
		Metadata: map[string]string{
			"custom_key": "custom_value",
		},
	}

	// Test successful publish
	mockDB.EXPECT().StoreSweepResults(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, results []*models.SweepResult) error {
			assert.Len(t, results, 1)
			assert.Equal(t, config.AgentID, results[0].AgentID)
			assert.Equal(t, config.PollerID, results[0].PollerID)
			assert.Equal(t, device.IP, results[0].IP)
			assert.Equal(t, device.MAC, *results[0].MAC)
			assert.Equal(t, device.Hostname, *results[0].Hostname)
			assert.Equal(t, "snmp_discovery", results[0].DiscoverySource)
			assert.True(t, results[0].Available)

			// Check metadata
			assert.Equal(t, device.SysDescr, results[0].Metadata["sys_descr"])
			assert.Equal(t, device.SysObjectID, results[0].Metadata["sys_object_id"])
			assert.Equal(t, device.SysContact, results[0].Metadata["sys_contact"])
			assert.Equal(t, device.SysLocation, results[0].Metadata["sys_location"])
			assert.Equal(t, "12345", results[0].Metadata["uptime"])
			assert.Equal(t, device.DeviceID, results[0].Metadata["device_id"])
			assert.Equal(t, "custom_value", results[0].Metadata["custom_key"])

			return nil
		},
	)

	err = publisher.PublishDevice(ctx, device)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().StoreSweepResults(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = publisher.PublishDevice(ctx, device)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to publish device")
}

func TestPublishInterface(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	ctx := context.Background()
	iface := &DiscoveredInterface{
		DeviceIP:      "192.168.1.1",
		DeviceID:      "test-device",
		IfIndex:       1,
		IfName:        "eth0",
		IfDescr:       "Ethernet Interface",
		IfAlias:       "LAN",
		IfSpeed:       1000000000,
		IfPhysAddress: "00:11:22:33:44:55",
		IPAddresses:   []string{"192.168.1.1"},
		IfAdminStatus: 1,
		IfOperStatus:  1,
		IfType:        6,
		Metadata: map[string]string{
			"custom_key": "custom_value",
		},
	}

	// Test successful publish
	mockDB.EXPECT().PublishDiscoveredInterface(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, discoveredInterface *models.DiscoveredInterface) error {
			assert.Equal(t, config.AgentID, discoveredInterface.AgentID)
			assert.Equal(t, config.PollerID, discoveredInterface.PollerID)
			assert.Equal(t, iface.DeviceIP, discoveredInterface.DeviceIP)
			assert.Equal(t, iface.DeviceID, discoveredInterface.DeviceID)
			assert.Equal(t, iface.IfIndex, discoveredInterface.IfIndex)
			assert.Equal(t, iface.IfName, discoveredInterface.IfName)
			assert.Equal(t, iface.IfDescr, discoveredInterface.IfDescr)
			assert.Equal(t, iface.IfAlias, discoveredInterface.IfAlias)
			assert.Equal(t, iface.IfSpeed, discoveredInterface.IfSpeed)
			assert.Equal(t, iface.IfPhysAddress, discoveredInterface.IfPhysAddress)
			assert.Equal(t, iface.IPAddresses, discoveredInterface.IPAddresses)
			assert.Equal(t, iface.IfAdminStatus, discoveredInterface.IfAdminStatus)
			assert.Equal(t, iface.IfOperStatus, discoveredInterface.IfOperStatus)

			// Check metadata
			var metadata map[string]string

			require.NoError(t, json.Unmarshal(discoveredInterface.Metadata, &metadata))
			assert.Equal(t, "custom_value", metadata["custom_key"])
			assert.Equal(t, "6", metadata["if_type"])

			return nil
		},
	)

	err = publisher.PublishInterface(ctx, iface)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().PublishDiscoveredInterface(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = publisher.PublishInterface(ctx, iface)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to publish interface")
}

func TestPublishTopologyLink(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	ctx := context.Background()
	link := &TopologyLink{
		Protocol:           "lldp",
		LocalDeviceIP:      "192.168.1.1",
		LocalDeviceID:      "test-device",
		LocalIfIndex:       1,
		LocalIfName:        "eth0",
		NeighborChassisID:  "00:22:33:44:55:66",
		NeighborPortID:     "eth1",
		NeighborPortDescr:  "Uplink",
		NeighborSystemName: "switch1",
		NeighborMgmtAddr:   "192.168.1.2",
		Metadata: map[string]string{
			"custom_key": "custom_value",
		},
	}

	// Test successful publish
	mockDB.EXPECT().PublishTopologyDiscoveryEvent(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, event *models.TopologyDiscoveryEvent) error {
			assert.Equal(t, config.AgentID, event.AgentID)
			assert.Equal(t, config.PollerID, event.PollerID)
			assert.Equal(t, link.LocalDeviceIP, event.LocalDeviceIP)
			assert.Equal(t, link.LocalDeviceID, event.LocalDeviceID)
			assert.Equal(t, link.LocalIfIndex, event.LocalIfIndex)
			assert.Equal(t, link.LocalIfName, event.LocalIfName)
			assert.Equal(t, link.Protocol, event.ProtocolType)
			assert.Equal(t, link.NeighborChassisID, event.NeighborChassisID)
			assert.Equal(t, link.NeighborPortID, event.NeighborPortID)
			assert.Equal(t, link.NeighborPortDescr, event.NeighborPortDescr)
			assert.Equal(t, link.NeighborSystemName, event.NeighborSystemName)
			assert.Equal(t, link.NeighborMgmtAddr, event.NeighborManagementAddr)

			// Check metadata
			var metadata map[string]string

			require.NoError(t, json.Unmarshal(event.Metadata, &metadata))
			assert.Equal(t, "custom_value", metadata["custom_key"])

			return nil
		},
	)

	err = publisher.PublishTopologyLink(ctx, link)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().PublishTopologyDiscoveryEvent(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = publisher.PublishTopologyLink(ctx, link)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to publish topology link")
}

func TestPublishBatchDevices(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	// Cast to concrete type to access batch methods
	protonPublisher := publisher.(*ProtonPublisher)

	ctx := context.Background()

	// Test with empty batch
	err = protonPublisher.PublishBatchDevices(ctx, []*DiscoveredDevice{})
	require.NoError(t, err)

	// Test with devices
	devices := []*DiscoveredDevice{
		{
			DeviceID: "test-device-1",
			IP:       "192.168.1.1",
			MAC:      "00:11:22:33:44:55",
			Hostname: "test-host-1",
			SysDescr: "Test System 1",
			Metadata: map[string]string{"key1": "value1"},
		},
		{
			DeviceID: "test-device-2",
			IP:       "192.168.1.2",
			MAC:      "00:11:22:33:44:66",
			Hostname: "test-host-2",
			SysDescr: "Test System 2",
			Metadata: map[string]string{"key2": "value2"},
		},
	}

	// Test successful publish
	mockDB.EXPECT().StoreSweepResults(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, results []*models.SweepResult) error {
			assert.Len(t, results, 2)

			// Check first device
			assert.Equal(t, config.AgentID, results[0].AgentID)
			assert.Equal(t, config.PollerID, results[0].PollerID)
			assert.Equal(t, devices[0].IP, results[0].IP)
			assert.Equal(t, devices[0].MAC, *results[0].MAC)
			assert.Equal(t, devices[0].Hostname, *results[0].Hostname)
			assert.Equal(t, "value1", results[0].Metadata["key1"])

			// Check second device
			assert.Equal(t, config.AgentID, results[1].AgentID)
			assert.Equal(t, config.PollerID, results[1].PollerID)
			assert.Equal(t, devices[1].IP, results[1].IP)
			assert.Equal(t, devices[1].MAC, *results[1].MAC)
			assert.Equal(t, devices[1].Hostname, *results[1].Hostname)
			assert.Equal(t, "value2", results[1].Metadata["key2"])

			return nil
		},
	)

	err = protonPublisher.PublishBatchDevices(ctx, devices)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().StoreSweepResults(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = protonPublisher.PublishBatchDevices(ctx, devices)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "failed to publish batch devices")
}

func TestPublishBatchInterfaces(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	// Cast to concrete type to access batch methods
	protonPublisher := publisher.(*ProtonPublisher)

	ctx := context.Background()

	interfaces := []*DiscoveredInterface{
		{
			DeviceIP: "192.168.1.1",
			DeviceID: "test-device-1",
			IfIndex:  1,
			IfName:   "eth0",
			Metadata: map[string]string{"key1": "value1"},
		},
		{
			DeviceIP: "192.168.1.2",
			DeviceID: "test-device-2",
			IfIndex:  2,
			IfName:   "eth1",
			Metadata: map[string]string{"key2": "value2"},
		},
	}

	// Test successful publish
	mockDB.EXPECT().PublishBatchDiscoveredInterfaces(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, modelInterfaces []*models.DiscoveredInterface) error {
			assert.Len(t, modelInterfaces, 2)

			// Check first interface
			assert.Equal(t, config.AgentID, modelInterfaces[0].AgentID)
			assert.Equal(t, config.PollerID, modelInterfaces[0].PollerID)
			assert.Equal(t, interfaces[0].DeviceIP, modelInterfaces[0].DeviceIP)
			assert.Equal(t, interfaces[0].DeviceID, modelInterfaces[0].DeviceID)
			assert.Equal(t, interfaces[0].IfIndex, modelInterfaces[0].IfIndex)
			assert.Equal(t, interfaces[0].IfName, modelInterfaces[0].IfName)

			// Check second interface
			assert.Equal(t, config.AgentID, modelInterfaces[1].AgentID)
			assert.Equal(t, config.PollerID, modelInterfaces[1].PollerID)
			assert.Equal(t, interfaces[1].DeviceIP, modelInterfaces[1].DeviceIP)
			assert.Equal(t, interfaces[1].DeviceID, modelInterfaces[1].DeviceID)
			assert.Equal(t, interfaces[1].IfIndex, modelInterfaces[1].IfIndex)
			assert.Equal(t, interfaces[1].IfName, modelInterfaces[1].IfName)

			return nil
		},
	)

	err = protonPublisher.PublishBatchInterfaces(ctx, interfaces)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().PublishBatchDiscoveredInterfaces(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = protonPublisher.PublishBatchInterfaces(ctx, interfaces)

	assert.Error(t, err)
}

func TestPublishBatchTopologyLinks(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	config := &StreamConfig{
		AgentID:  "test-agent",
		PollerID: "test-poller",
	}

	publisher, err := NewProtonPublisher(mockDB, config)
	require.NoError(t, err)
	assert.NotNil(t, publisher)

	// Cast to concrete type to access batch methods
	protonPublisher := publisher.(*ProtonPublisher)

	ctx := context.Background()

	links := []*TopologyLink{
		{
			Protocol:      "lldp",
			LocalDeviceIP: "192.168.1.1",
			LocalDeviceID: "test-device-1",
			LocalIfIndex:  1,
			LocalIfName:   "eth0",
			Metadata:      map[string]string{"key1": "value1"},
		},
		{
			Protocol:      "cdp",
			LocalDeviceIP: "192.168.1.2",
			LocalDeviceID: "test-device-2",
			LocalIfIndex:  2,
			LocalIfName:   "eth1",
			Metadata:      map[string]string{"key2": "value2"},
		},
	}

	// Test successful publish
	mockDB.EXPECT().PublishBatchTopologyDiscoveryEvents(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, events []*models.TopologyDiscoveryEvent) error {
			assert.Len(t, events, 2)

			// Check first link
			assert.Equal(t, config.AgentID, events[0].AgentID)
			assert.Equal(t, config.PollerID, events[0].PollerID)
			assert.Equal(t, links[0].LocalDeviceIP, events[0].LocalDeviceIP)
			assert.Equal(t, links[0].LocalDeviceID, events[0].LocalDeviceID)
			assert.Equal(t, links[0].LocalIfIndex, events[0].LocalIfIndex)
			assert.Equal(t, links[0].LocalIfName, events[0].LocalIfName)
			assert.Equal(t, links[0].Protocol, events[0].ProtocolType)

			// Check second link
			assert.Equal(t, config.AgentID, events[1].AgentID)
			assert.Equal(t, config.PollerID, events[1].PollerID)
			assert.Equal(t, links[1].LocalDeviceIP, events[1].LocalDeviceIP)
			assert.Equal(t, links[1].LocalDeviceID, events[1].LocalDeviceID)
			assert.Equal(t, links[1].LocalIfIndex, events[1].LocalIfIndex)
			assert.Equal(t, links[1].LocalIfName, events[1].LocalIfName)
			assert.Equal(t, links[1].Protocol, events[1].ProtocolType)

			return nil
		},
	)

	err = protonPublisher.PublishBatchTopologyLinks(ctx, links)
	require.NoError(t, err)

	// Test error case
	mockDB.EXPECT().PublishBatchTopologyDiscoveryEvents(gomock.Any(), gomock.Any()).Return(errMockDB)

	err = protonPublisher.PublishBatchTopologyLinks(ctx, links)

	assert.Error(t, err)
}
