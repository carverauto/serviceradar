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

package models

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGenerateServiceDeviceID(t *testing.T) {
	tests := []struct {
		name        string
		serviceType ServiceType
		serviceID   string
		expected    string
	}{
		{
			name:        "Poller device ID",
			serviceType: ServiceTypePoller,
			serviceID:   "k8s-poller",
			expected:    "serviceradar:poller:k8s-poller",
		},
		{
			name:        "Agent device ID",
			serviceType: ServiceTypeAgent,
			serviceID:   "agent-123",
			expected:    "serviceradar:agent:agent-123",
		},
		{
			name:        "Checker device ID",
			serviceType: ServiceTypeChecker,
			serviceID:   "sysmon@agent-123",
			expected:    "serviceradar:checker:sysmon@agent-123",
		},
		{
			name:        "Service ID with special characters",
			serviceType: ServiceTypePoller,
			serviceID:   "poller-test_123",
			expected:    "serviceradar:poller:poller-test_123",
		},
		{
			name:        "Empty service ID",
			serviceType: ServiceTypeAgent,
			serviceID:   "",
			expected:    "serviceradar:agent:",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GenerateServiceDeviceID(tt.serviceType, tt.serviceID)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestGenerateNetworkDeviceID(t *testing.T) {
	tests := []struct {
		name      string
		partition string
		ip        string
		expected  string
	}{
		{
			name:      "Standard network device",
			partition: "network",
			ip:        "192.168.1.1",
			expected:  "network:192.168.1.1",
		},
		{
			name:      "Default partition for empty partition",
			partition: "",
			ip:        "10.0.0.1",
			expected:  "default:10.0.0.1",
		},
		{
			name:      "Custom partition",
			partition: "datacenter-1",
			ip:        "172.16.0.1",
			expected:  "datacenter-1:172.16.0.1",
		},
		{
			name:      "IPv6 address",
			partition: "network",
			ip:        "2001:db8::1",
			expected:  "network:2001:db8::1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := GenerateNetworkDeviceID(tt.partition, tt.ip)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestIsServiceDevice(t *testing.T) {
	tests := []struct {
		name     string
		deviceID string
		expected bool
	}{
		{
			name:     "Poller device ID",
			deviceID: "serviceradar:poller:k8s-poller",
			expected: true,
		},
		{
			name:     "Agent device ID",
			deviceID: "serviceradar:agent:agent-123",
			expected: true,
		},
		{
			name:     "Checker device ID",
			deviceID: "serviceradar:checker:sysmon@agent-123",
			expected: true,
		},
		{
			name:     "Network device ID",
			deviceID: "network:192.168.1.1",
			expected: false,
		},
		{
			name:     "Default partition device ID",
			deviceID: "default:10.0.0.1",
			expected: false,
		},
		{
			name:     "Empty device ID",
			deviceID: "",
			expected: false,
		},
		{
			name:     "Partial match - too short",
			deviceID: "service",
			expected: false,
		},
		{
			name:     "Exact match of partition only",
			deviceID: "serviceradar",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsServiceDevice(tt.deviceID)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestCreatePollerDeviceUpdate(t *testing.T) {
	pollerID := "test-poller"
	hostIP := "192.168.1.100"
	metadata := map[string]string{
		"region": "us-west",
		"env":    "production",
	}

	result := CreatePollerDeviceUpdate(pollerID, hostIP, metadata)

	require.NotNil(t, result)
	assert.Equal(t, "serviceradar:poller:test-poller", result.DeviceID)
	assert.NotNil(t, result.ServiceType)
	assert.Equal(t, ServiceTypePoller, *result.ServiceType)
	assert.Equal(t, pollerID, result.ServiceID)
	assert.Equal(t, hostIP, result.IP)
	assert.Equal(t, DiscoverySourceServiceRadar, result.Source)
	assert.Equal(t, pollerID, result.PollerID)
	assert.Equal(t, ServiceDevicePartition, result.Partition)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, ConfidenceHighSelfReported, result.Confidence)

	// Check metadata includes both provided and added fields
	assert.Equal(t, "us-west", result.Metadata["region"])
	assert.Equal(t, "production", result.Metadata["env"])
	assert.Equal(t, "poller", result.Metadata["component_type"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])

	// Timestamp should be recent
	assert.WithinDuration(t, time.Now(), result.Timestamp, 5*time.Second)
}

func TestCreatePollerDeviceUpdate_NilMetadata(t *testing.T) {
	pollerID := "test-poller"
	hostIP := "192.168.1.100"

	result := CreatePollerDeviceUpdate(pollerID, hostIP, nil)

	require.NotNil(t, result)
	require.NotNil(t, result.Metadata)
	assert.Equal(t, "poller", result.Metadata["component_type"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])
}

func TestCreateAgentDeviceUpdate(t *testing.T) {
	agentID := "test-agent"
	pollerID := "test-poller"
	hostIP := "192.168.1.101"
	metadata := map[string]string{
		"version": "1.0.0",
	}

	result := CreateAgentDeviceUpdate(agentID, pollerID, hostIP, metadata)

	require.NotNil(t, result)
	assert.Equal(t, "serviceradar:agent:test-agent", result.DeviceID)
	assert.NotNil(t, result.ServiceType)
	assert.Equal(t, ServiceTypeAgent, *result.ServiceType)
	assert.Equal(t, agentID, result.ServiceID)
	assert.Equal(t, hostIP, result.IP)
	assert.Equal(t, DiscoverySourceServiceRadar, result.Source)
	assert.Equal(t, agentID, result.AgentID)
	assert.Equal(t, pollerID, result.PollerID)
	assert.Equal(t, ServiceDevicePartition, result.Partition)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, ConfidenceHighSelfReported, result.Confidence)

	// Check metadata includes both provided and added fields
	assert.Equal(t, "1.0.0", result.Metadata["version"])
	assert.Equal(t, "agent", result.Metadata["component_type"])
	assert.Equal(t, agentID, result.Metadata["agent_id"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])
}

func TestCreateAgentDeviceUpdate_NilMetadata(t *testing.T) {
	agentID := "test-agent"
	pollerID := "test-poller"
	hostIP := "192.168.1.101"

	result := CreateAgentDeviceUpdate(agentID, pollerID, hostIP, nil)

	require.NotNil(t, result)
	require.NotNil(t, result.Metadata)
	assert.Equal(t, "agent", result.Metadata["component_type"])
	assert.Equal(t, agentID, result.Metadata["agent_id"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])
}

func TestCreateCheckerDeviceUpdate(t *testing.T) {
	checkerID := "sysmon@test-agent"
	checkerKind := "sysmon"
	agentID := "test-agent"
	pollerID := "test-poller"
	hostIP := "192.168.1.102"
	metadata := map[string]string{
		"check_interval": "30s",
	}

	result := CreateCheckerDeviceUpdate(checkerID, checkerKind, agentID, pollerID, hostIP, metadata)

	require.NotNil(t, result)
	assert.Equal(t, "serviceradar:checker:sysmon@test-agent", result.DeviceID)
	assert.NotNil(t, result.ServiceType)
	assert.Equal(t, ServiceTypeChecker, *result.ServiceType)
	assert.Equal(t, checkerID, result.ServiceID)
	assert.Equal(t, hostIP, result.IP)
	assert.Equal(t, DiscoverySourceServiceRadar, result.Source)
	assert.Equal(t, agentID, result.AgentID)
	assert.Equal(t, pollerID, result.PollerID)
	assert.Equal(t, ServiceDevicePartition, result.Partition)
	assert.True(t, result.IsAvailable)
	assert.Equal(t, ConfidenceHighSelfReported, result.Confidence)

	// Check metadata includes both provided and added fields
	assert.Equal(t, "30s", result.Metadata["check_interval"])
	assert.Equal(t, "checker", result.Metadata["component_type"])
	assert.Equal(t, checkerID, result.Metadata["checker_id"])
	assert.Equal(t, checkerKind, result.Metadata["checker_kind"])
	assert.Equal(t, agentID, result.Metadata["agent_id"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])
}

func TestCreateCheckerDeviceUpdate_NilMetadata(t *testing.T) {
	checkerID := "sysmon@test-agent"
	checkerKind := "sysmon"
	agentID := "test-agent"
	pollerID := "test-poller"
	hostIP := "192.168.1.102"

	result := CreateCheckerDeviceUpdate(checkerID, checkerKind, agentID, pollerID, hostIP, nil)

	require.NotNil(t, result)
	require.NotNil(t, result.Metadata)
	assert.Equal(t, "checker", result.Metadata["component_type"])
	assert.Equal(t, checkerID, result.Metadata["checker_id"])
	assert.Equal(t, checkerKind, result.Metadata["checker_kind"])
	assert.Equal(t, agentID, result.Metadata["agent_id"])
	assert.Equal(t, pollerID, result.Metadata["poller_id"])
}

func TestServiceDeviceIDUniqueness(t *testing.T) {
	// Test that different service types with same ID produce different device IDs
	serviceID := "test-123"

	pollerID := GenerateServiceDeviceID(ServiceTypePoller, serviceID)
	agentID := GenerateServiceDeviceID(ServiceTypeAgent, serviceID)
	checkerID := GenerateServiceDeviceID(ServiceTypeChecker, serviceID)

	assert.NotEqual(t, pollerID, agentID)
	assert.NotEqual(t, pollerID, checkerID)
	assert.NotEqual(t, agentID, checkerID)

	// Verify they all have the service partition prefix
	assert.True(t, IsServiceDevice(pollerID))
	assert.True(t, IsServiceDevice(agentID))
	assert.True(t, IsServiceDevice(checkerID))
}

func TestServiceVsNetworkDeviceIDs(t *testing.T) {
	// Test that service devices and network devices have distinct ID formats
	serviceID := GenerateServiceDeviceID(ServiceTypePoller, "test-poller")
	networkID := GenerateNetworkDeviceID("network", "192.168.1.1")

	assert.NotEqual(t, serviceID, networkID)
	assert.True(t, IsServiceDevice(serviceID))
	assert.False(t, IsServiceDevice(networkID))
}

func TestServiceTypesConstants(t *testing.T) {
	// Verify ServiceType constants are correctly defined
	assert.Equal(t, ServiceType("poller"), ServiceTypePoller)
	assert.Equal(t, ServiceType("agent"), ServiceTypeAgent)
	assert.Equal(t, ServiceType("checker"), ServiceTypeChecker)
	assert.Equal(t, ServiceType("network"), ServiceTypeNetworkDevice)
}

func TestServiceDevicePartitionConstant(t *testing.T) {
	// Verify the partition constant is as expected
	assert.Equal(t, "serviceradar", ServiceDevicePartition)
}

func TestHighCardinalityCheckerIDs(t *testing.T) {
	// Test that we can create many unique checker IDs without collision
	pollerID := "poller-1"
	hostIP := "192.168.1.100"

	checkerTypes := []string{"sysmon", "rperf", "snmp", "mapper"}
	deviceIDs := make(map[string]bool)

	// Create 100 checkers across different agents and types
	for i := 1; i <= 25; i++ {
		agentID := fmt.Sprintf("agent-%d", i)
		for _, checkerType := range checkerTypes {
			checkerID := checkerType + "@" + agentID
			result := CreateCheckerDeviceUpdate(checkerID, checkerType, agentID, pollerID, hostIP, nil)

			// Ensure each device ID is unique
			assert.False(t, deviceIDs[result.DeviceID], "Duplicate device ID: %s", result.DeviceID)
			deviceIDs[result.DeviceID] = true
		}
	}

	// Should have created 100 unique device IDs
	assert.Equal(t, 100, len(deviceIDs))
}

func TestMultipleServicesOnSameIP(t *testing.T) {
	// Test that multiple services on the same IP get unique device IDs
	hostIP := "192.168.1.100"

	pollerUpdate := CreatePollerDeviceUpdate("poller-1", hostIP, nil)
	agentUpdate := CreateAgentDeviceUpdate("agent-1", "poller-1", hostIP, nil)
	checkerUpdate := CreateCheckerDeviceUpdate("sysmon@agent-1", "sysmon", "agent-1", "poller-1", hostIP, nil)

	// All have the same IP
	assert.Equal(t, hostIP, pollerUpdate.IP)
	assert.Equal(t, hostIP, agentUpdate.IP)
	assert.Equal(t, hostIP, checkerUpdate.IP)

	// But all have different device IDs
	assert.NotEqual(t, pollerUpdate.DeviceID, agentUpdate.DeviceID)
	assert.NotEqual(t, pollerUpdate.DeviceID, checkerUpdate.DeviceID)
	assert.NotEqual(t, agentUpdate.DeviceID, checkerUpdate.DeviceID)

	// Verify expected device ID format
	assert.Equal(t, "serviceradar:poller:poller-1", pollerUpdate.DeviceID)
	assert.Equal(t, "serviceradar:agent:agent-1", agentUpdate.DeviceID)
	assert.Equal(t, "serviceradar:checker:sysmon@agent-1", checkerUpdate.DeviceID)
}
