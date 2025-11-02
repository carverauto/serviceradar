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
	"time"
)

// DiscoverySource represents the different ways devices can be discovered
type DiscoverySource string

const (
	DiscoverySourceSNMP           DiscoverySource = "snmp"
	DiscoverySourceMapper         DiscoverySource = "mapper"
	DiscoverySourceIntegration    DiscoverySource = "integration"
	DiscoverySourceNetFlow        DiscoverySource = "netflow"
	DiscoverySourceManual         DiscoverySource = "manual"
	DiscoverySourceSweep          DiscoverySource = "sweep"
	DiscoverySourceSelfReported   DiscoverySource = "self-reported"
	DiscoverySourceArmis          DiscoverySource = "armis"
	DiscoverySourceNetbox         DiscoverySource = "netbox"
	DiscoverySourceSysmon         DiscoverySource = "sysmon"
	DiscoverySourceServiceRadar   DiscoverySource = "serviceradar" // ServiceRadar infrastructure components

	// Confidence levels for discovery sources (1-10 scale)
	ConfidenceLowUnknown         = 1  // Low confidence - unknown source
	ConfidenceMediumSweep        = 5  // Medium confidence - network sweep
	ConfidenceMediumTraffic      = 6  // Medium confidence - traffic analysis
	ConfidenceMediumMonitoring   = 6  // Medium confidence - system monitoring
	ConfidenceGoodExternal       = 7  // Good confidence - external system
	ConfidenceGoodSecurity       = 7  // Good confidence - external security system
	ConfidenceGoodDocumentation  = 7  // Good confidence - network documentation system
	ConfidenceHighNetworkMapping = 8  // High confidence - network mapping
	ConfidenceHighSelfReported   = 8  // High confidence - device reported itself
	ConfidenceHighSNMP           = 9  // High confidence - active SNMP query
	ConfidenceHighestManual      = 10 // Highest confidence - human input
)

// DiscoveredField represents a field value with its discovery source and metadata
type DiscoveredField[T any] struct {
	Value       T               `json:"value"`
	Source      DiscoverySource `json:"source"`
	LastUpdated time.Time       `json:"last_updated"`
	Confidence  int             `json:"confidence"` // 1-10 scale for source priority
	AgentID     string          `json:"agent_id"`
	PollerID    string          `json:"poller_id"`
}

// UnifiedDevice represents a device with tracked discovery sources for each field
type UnifiedDevice struct {
	DeviceID string `json:"device_id" db:"device_id"`
	IP       string `json:"ip" db:"ip"`

	// Fields with discovery source attribution
	Hostname *DiscoveredField[string]            `json:"hostname,omitempty" db:"hostname"`
	MAC      *DiscoveredField[string]            `json:"mac,omitempty" db:"mac"`
	Metadata *DiscoveredField[map[string]string] `json:"metadata,omitempty" db:"metadata"`

	// Discovery tracking
	DiscoverySources []DiscoverySourceInfo `json:"discovery_sources" db:"discovery_sources"`
	FirstSeen        time.Time             `json:"first_seen" db:"first_seen"`
	LastSeen         time.Time             `json:"last_seen" db:"last_seen"`
	IsAvailable      bool                  `json:"is_available" db:"is_available"`

	// Device classification
	DeviceType    string `json:"device_type,omitempty" db:"device_type"`
	ServiceType   string `json:"service_type,omitempty" db:"service_type"`
	ServiceStatus string `json:"service_status,omitempty" db:"service_status"`

	// Additional fields
	LastHeartbeat *time.Time `json:"last_heartbeat,omitempty" db:"last_heartbeat"`
	OSInfo        string     `json:"os_info,omitempty" db:"os_info"`
	VersionInfo   string     `json:"version_info,omitempty" db:"version_info"`
}

// DiscoverySourceInfo tracks when and how a device was discovered by each source
type DiscoverySourceInfo struct {
	Source     DiscoverySource `json:"source"`
	AgentID    string          `json:"agent_id"`
	PollerID   string          `json:"poller_id"`
	FirstSeen  time.Time       `json:"first_seen"`
	LastSeen   time.Time       `json:"last_seen"`
	Confidence int             `json:"confidence"`
}

// DeviceUpdate represents an update to a device from a discovery source
type DeviceUpdate struct {
	DeviceID    string            `json:"device_id"`
	IP          string            `json:"ip"`
	Source      DiscoverySource   `json:"source"`
	AgentID     string            `json:"agent_id"`
	PollerID    string            `json:"poller_id"`
	Partition   string            `json:"partition,omitempty"`   // Optional partition for multi-tenant systems
	ServiceType *ServiceType      `json:"service_type,omitempty"` // Type of service component (poller/agent/checker)
	ServiceID   string            `json:"service_id,omitempty"`  // ID of the service component
	Timestamp   time.Time         `json:"timestamp"`
	Hostname    *string           `json:"hostname,omitempty"`
	MAC         *string           `json:"mac,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
	IsAvailable bool              `json:"is_available"`
	Confidence  int               `json:"confidence"`
}

// GetSourceConfidence returns the confidence level for a discovery source
func GetSourceConfidence(source DiscoverySource) int {
	switch source {
	case DiscoverySourceSNMP:
		return ConfidenceHighSNMP // High confidence - active SNMP query
	case DiscoverySourceMapper:
		return ConfidenceHighNetworkMapping // High confidence - network mapping
	case DiscoverySourceIntegration:
		return ConfidenceGoodExternal // Good confidence - external system
	case DiscoverySourceArmis:
		return ConfidenceGoodSecurity // Good confidence - external security system
	case DiscoverySourceNetFlow:
		return ConfidenceMediumTraffic // Medium confidence - traffic analysis
	case DiscoverySourceSweep:
		return ConfidenceMediumSweep // Medium confidence - network sweep
	case DiscoverySourceSelfReported:
		return ConfidenceHighSelfReported // High confidence - device reported itself
	case DiscoverySourceManual:
		return ConfidenceHighestManual // Highest confidence - human input
	case DiscoverySourceNetbox:
		return ConfidenceGoodDocumentation // Good confidence - network documentation system
	case DiscoverySourceSysmon:
		return ConfidenceMediumMonitoring // Medium confidence - system monitoring
	case DiscoverySourceServiceRadar:
		return ConfidenceHighSelfReported // High confidence - ServiceRadar infrastructure component
	default:
		return ConfidenceLowUnknown // Low confidence - unknown source
	}
}

// ToLegacyDevice converts a UnifiedDevice to the legacy Device format for compatibility
func (ud *UnifiedDevice) ToLegacyDevice() *Device {
	device := &Device{
		DeviceID:    ud.DeviceID,
		IP:          ud.IP,
		FirstSeen:   ud.FirstSeen,
		LastSeen:    ud.LastSeen,
		IsAvailable: ud.IsAvailable,
		Metadata:    make(map[string]interface{}),
	}

	// Extract the latest values from discovered fields
	if ud.Hostname != nil {
		device.Hostname = ud.Hostname.Value
	}

	if ud.MAC != nil {
		device.MAC = ud.MAC.Value
	}

	if ud.Metadata != nil {
		for k, v := range ud.Metadata.Value {
			device.Metadata[k] = v
		}
	}

	// Convert discovery sources
	sources := make([]string, len(ud.DiscoverySources))
	for i, source := range ud.DiscoverySources {
		sources[i] = string(source.Source)
	}

	device.DiscoverySources = sources

	// Use the most confident agent/poller IDs
	if len(ud.DiscoverySources) > 0 {
		device.AgentID = ud.DiscoverySources[0].AgentID
		device.PollerID = ud.DiscoverySources[0].PollerID
	}

	return device
}

// NewUnifiedDeviceFromUpdate creates a new UnifiedDevice from a DeviceUpdate
func NewUnifiedDeviceFromUpdate(update *DeviceUpdate) *UnifiedDevice {
	now := update.Timestamp
	if now.IsZero() {
		now = time.Now()
	}

	confidence := update.Confidence
	if confidence == 0 {
		confidence = GetSourceConfidence(update.Source)
	}

	// Self-reported devices are always available by definition
	isAvailable := update.IsAvailable
	if update.Source == DiscoverySourceSelfReported {
		isAvailable = true
	}

	device := &UnifiedDevice{
		DeviceID:    update.DeviceID,
		IP:          update.IP,
		FirstSeen:   now,
		LastSeen:    now,
		IsAvailable: isAvailable,
		DeviceType:  "network_device", // Default
		DiscoverySources: []DiscoverySourceInfo{
			{
				Source:     update.Source,
				AgentID:    update.AgentID,
				PollerID:   update.PollerID,
				FirstSeen:  now,
				LastSeen:   now,
				Confidence: confidence,
			},
		},
	}

	// Set discovered fields if provided
	if update.Hostname != nil {
		device.Hostname = &DiscoveredField[string]{
			Value:       *update.Hostname,
			Source:      update.Source,
			LastUpdated: now,
			Confidence:  confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
	}

	if update.MAC != nil {
		device.MAC = &DiscoveredField[string]{
			Value:       *update.MAC,
			Source:      update.Source,
			LastUpdated: now,
			Confidence:  confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
	}

	if len(update.Metadata) > 0 {
		device.Metadata = &DiscoveredField[map[string]string]{
			Value:       update.Metadata,
			Source:      update.Source,
			LastUpdated: now,
			Confidence:  confidence,
			AgentID:     update.AgentID,
			PollerID:    update.PollerID,
		}
	}

	return device
}
