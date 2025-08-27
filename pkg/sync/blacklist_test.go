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
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestNewNetworkBlacklist(t *testing.T) {
	log := logger.NewTestLogger()

	tests := []struct {
		name      string
		cidrs     []string
		wantErr   bool
		errString string
	}{
		{
			name:    "valid CIDRs",
			cidrs:   []string{"192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"},
			wantErr: false,
		},
		{
			name:    "empty list",
			cidrs:   []string{},
			wantErr: false,
		},
		{
			name:      "invalid CIDR format",
			cidrs:     []string{"192.168.0.0/16", "invalid-cidr"},
			wantErr:   true,
			errString: "invalid CIDR",
		},
		{
			name:      "invalid IP in CIDR",
			cidrs:     []string{"256.168.0.0/16"},
			wantErr:   true,
			errString: "invalid CIDR",
		},
		{
			name:      "missing prefix length",
			cidrs:     []string{"192.168.0.0"},
			wantErr:   true,
			errString: "invalid CIDR",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			nb, err := NewNetworkBlacklist(tt.cidrs, log)
			if tt.wantErr {
				require.Error(t, err)
				assert.Contains(t, err.Error(), tt.errString)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, nb)
				assert.Len(t, nb.networks, len(tt.cidrs))
			}
		})
	}
}

func TestIsBlacklisted(t *testing.T) {
	log := logger.NewTestLogger()

	nb, err := NewNetworkBlacklist([]string{
		"192.168.0.0/16",
		"10.0.0.0/8",
		"172.16.0.0/12",
	}, log)
	require.NoError(t, err)

	tests := []struct {
		name        string
		ip          string
		blacklisted bool
	}{
		// IPs in blacklisted ranges
		{"192.168.x.x range", "192.168.1.1", true},
		{"192.168.x.x range edge", "192.168.255.255", true},
		{"10.x.x.x range", "10.0.0.1", true},
		{"10.x.x.x range middle", "10.50.100.200", true},
		{"172.16.x.x range", "172.16.0.1", true},
		{"172.16.x.x range edge", "172.31.255.255", true},

		// IPs outside blacklisted ranges
		{"public IP", "8.8.8.8", false},
		{"outside 192.168", "192.169.0.1", false},
		{"outside 10.x", "11.0.0.1", false},
		{"outside 172.16-31", "172.32.0.1", false},
		{"localhost", "127.0.0.1", false},

		// Invalid IPs
		{"invalid IP", "invalid-ip", false},
		{"empty IP", "", false},
		{"IPv6", "2001:db8::1", false}, // Should not match IPv4 blacklists
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := nb.IsBlacklisted(tt.ip)
			assert.Equal(t, tt.blacklisted, result)
		})
	}
}

func TestFilterDevices(t *testing.T) {
	log := logger.NewTestLogger()

	nb, err := NewNetworkBlacklist([]string{
		"192.168.0.0/16",
		"10.0.0.0/8",
	}, log)
	require.NoError(t, err)

	devices := []*models.DeviceUpdate{
		{IP: "192.168.1.100", Source: models.DiscoverySourceArmis},
		{IP: "10.0.0.50", Source: models.DiscoverySourceNetbox},
		{IP: "8.8.8.8", Source: models.DiscoverySourceArmis},
		{IP: "1.1.1.1", Source: models.DiscoverySourceNetbox},
		{IP: "", Source: models.DiscoverySourceArmis}, // Device without IP
		{IP: "192.168.50.1", Source: models.DiscoverySourceNetbox},
		{IP: "172.16.0.1", Source: models.DiscoverySourceArmis}, // Not in blacklist
	}

	filtered := nb.FilterDevices(devices)

	// Should filter out 192.168.x.x and 10.x.x.x addresses
	assert.Len(t, filtered, 4)

	// Verify remaining IPs
	expectedIPs := []string{"8.8.8.8", "1.1.1.1", "", "172.16.0.1"}

	actualIPs := make([]string, len(filtered))

	for i, d := range filtered {
		actualIPs[i] = d.IP
	}

	assert.ElementsMatch(t, expectedIPs, actualIPs)
}

func TestFilterDevicesEmptyBlacklist(t *testing.T) {
	log := logger.NewTestLogger()

	// Create blacklist with no networks
	nb, err := NewNetworkBlacklist([]string{}, log)
	require.NoError(t, err)

	devices := []*models.DeviceUpdate{
		{IP: "192.168.1.100", Source: models.DiscoverySourceArmis},
		{IP: "10.0.0.50", Source: models.DiscoverySourceNetbox},
		{IP: "8.8.8.8", Source: models.DiscoverySourceArmis},
	}

	filtered := nb.FilterDevices(devices)

	// Should not filter any devices
	assert.Len(t, filtered, len(devices))
	assert.Equal(t, devices, filtered)
}

func TestFilterKVData(t *testing.T) {
	log := logger.NewTestLogger()

	nb, err := NewNetworkBlacklist([]string{
		"192.168.0.0/16",
		"10.0.0.0/8",
	}, log)
	require.NoError(t, err)

	// Create test KV data
	kvData := map[string][]byte{
		"12345":                []byte(`{"id": 12345}`),           // Device ID key - should be kept
		"agent1/192.168.1.100": []byte(`{"ip": "192.168.1.100"}`), // Blacklisted IP
		"agent1/10.0.0.50":     []byte(`{"ip": "10.0.0.50"}`),     // Blacklisted IP
		"agent1/8.8.8.8":       []byte(`{"ip": "8.8.8.8"}`),       // Allowed IP
		"agent1/1.1.1.1":       []byte(`{"ip": "1.1.1.1"}`),       // Allowed IP
		"some-other-key":       []byte(`{"data": "value"}`),       // Non-IP key
		"agent2/192.168.50.1":  []byte(`{"ip": "192.168.50.1"}`),  // Blacklisted IP
		"agent2/172.16.0.1":    []byte(`{"ip": "172.16.0.1"}`),    // Allowed IP
	}

	// Create corresponding devices (after filtering)
	devices := []*models.DeviceUpdate{
		{IP: "8.8.8.8", Source: models.DiscoverySourceArmis},
		{IP: "1.1.1.1", Source: models.DiscoverySourceNetbox},
		{IP: "172.16.0.1", Source: models.DiscoverySourceArmis},
	}

	filtered := nb.FilterKVData(kvData, devices)

	// Should keep device ID keys, allowed IP keys, and non-IP pattern keys
	expectedKeys := []string{
		"12345",
		"agent1/8.8.8.8",
		"agent1/1.1.1.1",
		"some-other-key",
		"agent2/172.16.0.1",
	}

	assert.Len(t, filtered, len(expectedKeys))

	for _, key := range expectedKeys {
		_, exists := filtered[key]
		assert.True(t, exists, "Expected key %s to exist in filtered data", key)
	}

	// Verify blacklisted keys are removed
	blacklistedKeys := []string{
		"agent1/192.168.1.100",
		"agent1/10.0.0.50",
		"agent2/192.168.50.1",
	}

	for _, key := range blacklistedKeys {
		_, exists := filtered[key]
		assert.False(t, exists, "Expected key %s to be filtered out", key)
	}
}

func TestFilterKVDataEmptyBlacklist(t *testing.T) {
	log := logger.NewTestLogger()

	// Create blacklist with no networks
	nb, err := NewNetworkBlacklist([]string{}, log)
	require.NoError(t, err)

	kvData := map[string][]byte{
		"12345":                []byte(`{"id": 12345}`),
		"agent1/192.168.1.100": []byte(`{"ip": "192.168.1.100"}`),
		"agent1/10.0.0.50":     []byte(`{"ip": "10.0.0.50"}`),
	}

	devices := []*models.DeviceUpdate{
		{IP: "192.168.1.100", Source: models.DiscoverySourceArmis},
		{IP: "10.0.0.50", Source: models.DiscoverySourceNetbox},
	}

	filtered := nb.FilterKVData(kvData, devices)

	// Should not filter any data
	assert.Len(t, filtered, len(kvData))

	for key := range kvData {
		_, exists := filtered[key]
		assert.True(t, exists, "Expected key %s to exist in filtered data", key)
	}
}
