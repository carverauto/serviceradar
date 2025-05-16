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
	IfIndex       int             `json:"ifIndex"`
	IfName        string          `json:"ifName"`
	IfDescr       string          `json:"ifDescr"`
	IfAlias       string          `json:"ifAlias"`
	IfSpeed       int64           `json:"ifSpeed"`
	IfPhysAddress string          `json:"ifPhysAddress"`
	IPAddresses   []string        `json:"ip_addresses"`
	IfAdminStatus int             `json:"ifAdminStatus"`
	IfOperStatus  int             `json:"ifOperStatus"`
	Metadata      json.RawMessage `json:"metadata"`
}

// TopologyDiscoveryEvent represents a topology discovery event
type TopologyDiscoveryEvent struct {
	Timestamp              time.Time       `json:"timestamp"`
	AgentID                string          `json:"agent_id"`
	PollerID               string          `json:"poller_id"`
	LocalDeviceIP          string          `json:"local_device_ip"`
	LocalDeviceID          string          `json:"local_device_id"`
	LocalIfIndex           int             `json:"local_ifIndex"`
	LocalIfName            string          `json:"local_ifName"`
	ProtocolType           string          `json:"protocol_type"` // "LLDP" or "CDP"
	NeighborChassisID      string          `json:"neighbor_chassis_id"`
	NeighborPortID         string          `json:"neighbor_port_id"`
	NeighborPortDescr      string          `json:"neighbor_port_descr"`
	NeighborSystemName     string          `json:"neighbor_system_name"`
	NeighborManagementAddr string          `json:"neighbor_management_address"`
	Metadata               json.RawMessage `json:"metadata"`
}
