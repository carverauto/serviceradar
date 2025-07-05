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
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// DeduplicateDevices finds and merges duplicate devices in the database
func (r *DeviceRegistry) DeduplicateDevices(ctx context.Context) error {
	log.Println("Starting device deduplication process...")

	// Step 1: Get all devices from the database
	devices, err := r.db.ListUnifiedDevices(ctx, 10000, 0) // Get up to 10k devices
	if err != nil {
		return fmt.Errorf("failed to list devices: %w", err)
	}

	log.Printf("Found %d total devices to analyze", len(devices))

	// Step 2: Build a map of all IPs to devices
	ipToDevices := make(map[string][]*models.UnifiedDevice)
	
	for _, device := range devices {
		// Add primary IP
		if device.IP != "" {
			ipToDevices[device.IP] = append(ipToDevices[device.IP], device)
		}
		
		// Add alternate IPs
		if device.Metadata != nil && device.Metadata.Value != nil {
			alternateIPs := extractAlternateIPs(device.Metadata.Value)
			for _, ip := range alternateIPs {
				if ip != "" {
					ipToDevices[ip] = append(ipToDevices[ip], device)
				}
			}
		}
	}

	// Step 3: Find duplicate groups
	processedDevices := make(map[string]bool)
	duplicateGroups := [][]string{} // Groups of device IDs that should be merged
	
	for _, device := range devices {
		if processedDevices[device.DeviceID] {
			continue
		}
		
		// Find all devices that share any IP with this device
		relatedDevices := make(map[string]*models.UnifiedDevice)
		relatedDevices[device.DeviceID] = device
		
		// Check primary IP
		if device.IP != "" {
			for _, related := range ipToDevices[device.IP] {
				if related.DeviceID != device.DeviceID {
					relatedDevices[related.DeviceID] = related
				}
			}
		}
		
		// Check alternate IPs
		if device.Metadata != nil && device.Metadata.Value != nil {
			alternateIPs := extractAlternateIPs(device.Metadata.Value)
			for _, ip := range alternateIPs {
				if ip != "" {
					for _, related := range ipToDevices[ip] {
						if related.DeviceID != device.DeviceID {
							relatedDevices[related.DeviceID] = related
						}
					}
				}
			}
		}
		
		// If we found duplicates, create a group
		if len(relatedDevices) > 1 {
			group := make([]string, 0, len(relatedDevices))
			for deviceID := range relatedDevices {
				group = append(group, deviceID)
				processedDevices[deviceID] = true
			}
			duplicateGroups = append(duplicateGroups, group)
			
			log.Printf("Found duplicate group with %d devices: %v", len(group), group)
		} else {
			processedDevices[device.DeviceID] = true
		}
	}

	log.Printf("Found %d duplicate groups to merge", len(duplicateGroups))

	// Step 4: Merge each duplicate group
	for _, group := range duplicateGroups {
		if err := r.mergeDuplicateGroup(ctx, group, devices); err != nil {
			log.Printf("Error merging duplicate group %v: %v", group, err)
			// Continue with other groups even if one fails
		}
	}

	log.Println("Device deduplication process completed")
	return nil
}

// mergeDuplicateGroup merges a group of duplicate devices into a single canonical device
func (r *DeviceRegistry) mergeDuplicateGroup(ctx context.Context, deviceIDs []string, allDevices []*models.UnifiedDevice) error {
	if len(deviceIDs) < 2 {
		return nil // Nothing to merge
	}

	// Find the devices in this group
	devices := make([]*models.UnifiedDevice, 0, len(deviceIDs))
	deviceMap := make(map[string]*models.UnifiedDevice)
	
	for _, device := range allDevices {
		for _, id := range deviceIDs {
			if device.DeviceID == id {
				devices = append(devices, device)
				deviceMap[id] = device
				break
			}
		}
	}

	// Choose the canonical device (prefer SNMP sources, then most recently seen)
	var canonicalDevice *models.UnifiedDevice
	for _, device := range devices {
		if canonicalDevice == nil {
			canonicalDevice = device
			continue
		}
		
		// Prefer SNMP sources
		canonicalHasSNMP := false
		deviceHasSNMP := false
		
		for _, sourceInfo := range canonicalDevice.DiscoverySources {
			if sourceInfo.Source == models.DiscoverySourceSNMP {
				canonicalHasSNMP = true
				break
			}
		}
		
		for _, sourceInfo := range device.DiscoverySources {
			if sourceInfo.Source == models.DiscoverySourceSNMP {
				deviceHasSNMP = true
				break
			}
		}
		
		if !canonicalHasSNMP && deviceHasSNMP {
			canonicalDevice = device
		} else if canonicalHasSNMP == deviceHasSNMP && device.LastSeen.After(canonicalDevice.LastSeen) {
			canonicalDevice = device
		}
	}

	log.Printf("Merging %d devices into canonical device %s", len(devices), canonicalDevice.DeviceID)

	// Collect all unique IPs from all devices
	allIPs := make(map[string]bool)
	allIPs[canonicalDevice.IP] = true
	
	for _, device := range devices {
		if device.IP != "" {
			allIPs[device.IP] = true
		}
		if device.Metadata != nil && device.Metadata.Value != nil {
			for _, ip := range extractAlternateIPs(device.Metadata.Value) {
				if ip != "" {
					allIPs[ip] = true
				}
			}
		}
	}

	// Convert to slice and remove canonical IP
	alternateIPs := make([]string, 0, len(allIPs)-1)
	for ip := range allIPs {
		if ip != canonicalDevice.IP {
			alternateIPs = append(alternateIPs, ip)
		}
	}

	// Prepare metadata with all alternate IPs
	metadata := make(map[string]string)
	if canonicalDevice.Metadata != nil && canonicalDevice.Metadata.Value != nil {
		metadata = canonicalDevice.Metadata.Value
	}
	
	alternateIPsJSON, _ := json.Marshal(alternateIPs)
	metadata["alternate_ips"] = string(alternateIPsJSON)
	metadata["merged_devices"] = fmt.Sprintf("%v", deviceIDs)
	metadata["merge_timestamp"] = time.Now().Format(time.RFC3339)

	// Get primary agent and poller ID from canonical device
	var agentID, pollerID string
	for _, sourceInfo := range canonicalDevice.DiscoverySources {
		agentID = sourceInfo.AgentID
		pollerID = sourceInfo.PollerID
		break // Use the first one
	}

	// Create a sweep result that will update the canonical device with all the merged data
	sweepResult := &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		DeviceID:        canonicalDevice.DeviceID,
		IP:              canonicalDevice.IP,
		Available:       canonicalDevice.IsAvailable,
		Timestamp:       time.Now(),
		DiscoverySource: "deduplication",
		Metadata:        metadata,
	}

	// Publish the update
	if err := r.ProcessSweepResult(ctx, sweepResult); err != nil {
		return fmt.Errorf("failed to update canonical device %s: %w", canonicalDevice.DeviceID, err)
	}

	// Mark other devices as merged
	for _, device := range devices {
		if device.DeviceID == canonicalDevice.DeviceID {
			continue // Skip the canonical device
		}

		mergedMetadata := make(map[string]string)
		if device.Metadata != nil && device.Metadata.Value != nil {
			mergedMetadata = device.Metadata.Value
		}
		
		mergedMetadata["_merged_into"] = canonicalDevice.DeviceID
		mergedMetadata["_merge_timestamp"] = time.Now().Format(time.RFC3339)

		// Get agent and poller ID from device's discovery sources
		var deviceAgentID, devicePollerID string
		for _, sourceInfo := range device.DiscoverySources {
			deviceAgentID = sourceInfo.AgentID
			devicePollerID = sourceInfo.PollerID
			break // Use the first one
		}

		// Create a sweep result to mark this device as merged
		mergeResult := &models.SweepResult{
			AgentID:         deviceAgentID,
			PollerID:        devicePollerID,
			DeviceID:        device.DeviceID,
			IP:              device.IP,
			Available:       false, // Mark as unavailable
			Timestamp:       time.Now(),
			DiscoverySource: "deduplication",
			Metadata:        mergedMetadata,
		}

		if err := r.ProcessSweepResult(ctx, mergeResult); err != nil {
			log.Printf("Failed to mark device %s as merged: %v", device.DeviceID, err)
			// Continue with other devices
		}
	}

	return nil
}