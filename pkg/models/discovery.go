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

// DiscoveredInterface represents a network interface discovered by the system
type DiscoveredInterface struct {
	Timestamp     time.Time       `json:"timestamp"`
	AgentID       string          `json:"agent_id"`
	PollerID      string          `json:"poller_id"`
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
	PollerID               string    `json:"poller_id"`
	LocalDeviceIP          string    `json:"local_device_ip"`
	LocalDeviceID          string    `json:"local_device_id"`
	LocalIfIndex           int       `json:"local_ifIndex"` // DB schema is int32, Proton driver should handle
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
