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
	"encoding/json"
	"time"
)

// DiscoverySource represents the different ways devices can be discovered
type DiscoverySource string

const (
	DiscoverySourceSNMP         DiscoverySource = "snmp"
	DiscoverySourceMapper       DiscoverySource = "mapper"
	DiscoverySourceIntegration  DiscoverySource = "integration"
	DiscoverySourceNetFlow      DiscoverySource = "netflow"
	DiscoverySourceManual       DiscoverySource = "manual"
	DiscoverySourceSweep        DiscoverySource = "sweep"
	DiscoverySourceSighting     DiscoverySource = "sighting"
	DiscoverySourceSelfReported DiscoverySource = "self-reported"
	DiscoverySourceArmis        DiscoverySource = "armis"
	DiscoverySourceNetbox       DiscoverySource = "netbox"
	DiscoverySourceSysmon       DiscoverySource = "sysmon"
	DiscoverySourceServiceRadar DiscoverySource = "serviceradar" // ServiceRadar infrastructure components

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

// DiscoverySourceInfo tracks when and how a device was discovered by each source
type DiscoverySourceInfo struct {
	Source     DiscoverySource `json:"source"`
	AgentID    string          `json:"agent_id"`
	GatewayID   string          `json:"gateway_id"`
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
	GatewayID    string            `json:"gateway_id"`
	Partition   string            `json:"partition,omitempty"`    // Optional partition for multi-tenant systems
	ServiceType *ServiceType      `json:"service_type,omitempty"` // Type of service component (gateway/agent/checker)
	ServiceID   string            `json:"service_id,omitempty"`   // ID of the service component
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
	case DiscoverySourceSighting:
		return ConfidenceMediumSweep // Medium confidence - promoted sighting
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

// DiscoveredInterface represents a network interface discovered by the system
type DiscoveredInterface struct {
	Timestamp     time.Time       `json:"timestamp"`
	AgentID       string          `json:"agent_id"`
	GatewayID      string          `json:"gateway_id"`
	DeviceIP      string          `json:"device_ip"`
	DeviceID      string          `json:"device_id"`
	IfIndex       int32           `json:"ifIndex"`
	IfName        string          `json:"ifName"`
	IfDescr       string          `json:"ifDescr"`
	IfAlias       string          `json:"ifAlias"`
	IfSpeed       uint64          `json:"ifSpeed"`
	IfPhysAddress string          `json:"ifPhysAddress"`
	IPAddresses   []string        `json:"ip_addresses"`
	IfAdminStatus int32           `json:"ifAdminStatus"`
	IfOperStatus  int32           `json:"ifOperStatus"`
	Metadata      json.RawMessage `json:"metadata"`
}

// TopologyDiscoveryEvent represents a topology discovery event
type TopologyDiscoveryEvent struct {
	Timestamp              time.Time `json:"timestamp"`
	AgentID                string    `json:"agent_id"`
	GatewayID               string    `json:"gateway_id"`
	LocalDeviceIP          string    `json:"local_device_ip"`
	LocalDeviceID          string    `json:"local_device_id"`
	LocalIfIndex           int32     `json:"local_ifIndex"` // DB schema is int32; Postgres driver should handle
	LocalIfName            string    `json:"local_ifName"`
	ProtocolType           string    `json:"protocol_type"` // "LLDP" or "CDP"
	NeighborChassisID      string    `json:"neighbor_chassis_id"`
	NeighborPortID         string    `json:"neighbor_port_id"`
	NeighborPortDescr      string    `json:"neighbor_port_descr"`
	NeighborSystemName     string    `json:"neighbor_system_name"`
	NeighborManagementAddr string    `json:"neighbor_management_address"`
	// BGP specific fields - added
	NeighborBGPRouterID string          `json:"neighbor_bgp_router_id,omitempty"`
	NeighborIPAddress   string          `json:"neighbor_ip_address,omitempty"` // For BGP peer IP
	NeighborAS          uint32          `json:"neighbor_as,omitempty"`
	BGPSessionState     string          `json:"bgp_session_state,omitempty"`
	Metadata            json.RawMessage `json:"metadata"`
}
