package models

import (
	"time"
)

// Device represents a network device.
type Device struct {
	DeviceID        string                 `json:"device_id"`
	PollerID        string                 `json:"poller_id"`
	DiscoverySource string                 `json:"discovery_source"`
	IP              string                 `json:"ip"`
	MAC             string                 `json:"mac,omitempty"`
	Hostname        string                 `json:"hostname,omitempty"`
	FirstSeen       time.Time              `json:"first_seen"`
	LastSeen        time.Time              `json:"last_seen"`
	IsAvailable     bool                   `json:"is_available"`
	Metadata        map[string]interface{} `json:"metadata,omitempty"`
}

// DeviceInfo represents device information collected at the agent level.
type DeviceInfo struct {
	// Basic identification
	IP       string `json:"ip"`                 // IP address (primary identifier)
	MAC      string `json:"mac,omitempty"`      // MAC address if available
	Hostname string `json:"hostname,omitempty"` // DNS hostname if resolved

	// Status
	Available bool  `json:"available"` // Current availability status
	LastSeen  int64 `json:"last_seen"` // Unix timestamp of last observation

	// Discovery metadata
	DiscoverySource string `json:"discovery_source"`         // How device was discovered (network_sweep, icmp, snmp, etc.)
	DiscoveryTime   int64  `json:"discovery_time,omitempty"` // When first discovered

	// Network information
	OpenPorts      []int  `json:"open_ports,omitempty"`      // List of open ports found
	NetworkSegment string `json:"network_segment,omitempty"` // Network segment/VLAN if known

	// Service information
	ServiceType string `json:"service_type,omitempty"` // Type of service used for discovery (port, icmp, snmp)
	ServiceName string `json:"service_name,omitempty"` // Name of service that discovered it

	// Response metrics
	ResponseTime int64   `json:"response_time,omitempty"` // Response time in nanoseconds
	PacketLoss   float64 `json:"packet_loss,omitempty"`   // Packet loss percentage (for ICMP)

	// Hardware/OS information if available
	DeviceType string `json:"device_type,omitempty"` // Router, switch, server, etc.
	Vendor     string `json:"vendor,omitempty"`      // Hardware vendor if known
	Model      string `json:"model,omitempty"`       // Device model if known
	OSInfo     string `json:"os_info,omitempty"`     // OS information if available

	// Additional metadata as string map for extensibility
	Metadata map[string]string `json:"metadata,omitempty"` // Additional metadata not covered by fields above
}
