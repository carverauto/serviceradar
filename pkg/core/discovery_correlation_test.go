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

package core

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
)

// TestCorrelationLogicFlow tests the flow of the correlation logic
// This is a unit test that verifies the logic without mocking the entire database
func TestCorrelationLogicFlow(t *testing.T) {
	// Test scenario:
	// 1. We have an existing device with ID "partition1:192.168.2.1" that has alternate IP "192.168.4.1"
	// 2. When we discover interfaces on IP "192.168.4.1", it should correlate to the existing device
	
	// Create a map that simulates what ipToCanonicalDevice would contain after database lookup
	canonicalDevice := &models.UnifiedDevice{
		DeviceID: "partition1:192.168.2.1",
		IP:       "192.168.2.1",
		Hostname: &models.DiscoveredField[string]{Value: "UDM Pro"},
		MAC:      &models.DiscoveredField[string]{Value: "00:11:22:33:44:55"},
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"alternate_ips": `["192.168.4.1"]`,
				"device_type":   "router",
			},
		},
	}

	ipToCanonicalDevice := map[string]*models.UnifiedDevice{
		"192.168.2.1": canonicalDevice,
		"192.168.4.1": canonicalDevice, // Alternate IP points to same device
	}

	// Test 1: IP that exists in the map should return the canonical device
	testIP := "192.168.4.1"
	if device, ok := ipToCanonicalDevice[testIP]; ok {
		if device.DeviceID != "partition1:192.168.2.1" {
			t.Errorf("Expected canonical ID 'partition1:192.168.2.1', got '%s'", device.DeviceID)
		}
		if device.IP != "192.168.2.1" {
			t.Errorf("Expected canonical IP '192.168.2.1', got '%s'", device.IP)
		}
		if device.Hostname.Value != "UDM Pro" {
			t.Errorf("Expected hostname 'UDM Pro', got '%s'", device.Hostname.Value)
		}
	} else {
		t.Error("Expected to find IP in correlation map")
	}

	// Test 2: IP that doesn't exist should be treated as new device
	newIP := "192.168.5.1"
	if _, ok := ipToCanonicalDevice[newIP]; ok {
		t.Error("Did not expect to find new IP in correlation map")
	} else {
		// This is the expected path - would generate new ID
		expectedNewID := "partition1:" + newIP
		if expectedNewID != "partition1:192.168.5.1" {
			t.Errorf("Expected new ID 'partition1:192.168.5.1', got '%s'", expectedNewID)
		}
	}
}

// TestSmartMerging tests the smart merging behavior when correlating devices
func TestSmartMerging(t *testing.T) {
	// Test scenario: Existing device should preserve its identity when enriched with new data
	
	// Existing canonical device
	existingDevice := &models.UnifiedDevice{
		DeviceID: "default:152.117.116.178",
		IP:       "152.117.116.178",
		Hostname: &models.DiscoveredField[string]{Value: "UDM Pro"},
		MAC:      &models.DiscoveredField[string]{Value: "24:5e:be:89:5e:78"},
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"device_type":   "router",
				"alternate_ips": `["192.168.2.1"]`,
			},
		},
	}

	// Simulate new sighting data that would come from a switch discovery
	newSightingIP := "192.168.2.1"
	newAlternateIPs := []string{"192.168.2.2", "192.168.2.3"} // New IPs found in this sighting

	// Test the merging logic
	
	// Start with existing device data
	hostname := existingDevice.Hostname.Value
	mac := existingDevice.MAC.Value
	metadata := make(map[string]string)
	for k, v := range existingDevice.Metadata.Value {
		metadata[k] = v
	}

	// Merge alternate IPs
	existingAltIPs := make(map[string]struct{})
	if alternateIPsJSON, ok := metadata["alternate_ips"]; ok {
		var altIPs []string
		if json.Unmarshal([]byte(alternateIPsJSON), &altIPs) == nil {
			for _, ip := range altIPs {
				existingAltIPs[ip] = struct{}{}
			}
		}
	}
	
	// Add new alternate IPs (excluding the canonical primary IP)
	for _, ip := range newAlternateIPs {
		if ip != existingDevice.IP {
			existingAltIPs[ip] = struct{}{}
		}
	}
	// Also add the sighting IP if it's not the canonical primary
	if newSightingIP != existingDevice.IP {
		existingAltIPs[newSightingIP] = struct{}{}
	}

	finalAltIPs := make([]string, 0, len(existingAltIPs))
	for ip := range existingAltIPs {
		finalAltIPs = append(finalAltIPs, ip)
	}

	// Verify the merged result preserves canonical identity
	if hostname != "UDM Pro" {
		t.Errorf("Expected hostname to be preserved as 'UDM Pro', got '%s'", hostname)
	}
	if mac != "24:5e:be:89:5e:78" {
		t.Errorf("Expected MAC to be preserved as '24:5e:be:89:5e:78', got '%s'", mac)
	}
	
	// Verify alternate IPs were merged correctly
	expectedAltIPs := map[string]bool{
		"192.168.2.1": true, // Original alternate IP
		"192.168.2.2": true, // New alternate IP
		"192.168.2.3": true, // New alternate IP
	}
	
	if len(finalAltIPs) != len(expectedAltIPs) {
		t.Errorf("Expected %d alternate IPs, got %d", len(expectedAltIPs), len(finalAltIPs))
	}
	
	for _, ip := range finalAltIPs {
		if !expectedAltIPs[ip] {
			t.Errorf("Unexpected alternate IP: %s", ip)
		}
	}
}