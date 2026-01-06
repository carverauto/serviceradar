package registry

import "time"

// DeviceRecord captures the authoritative in-memory view of a device.
// It mirrors the core fields we hydrate from the CNPG store so the
// registry can answer state queries without touching the warehouse.
type DeviceRecord struct {
	DeviceID         string
	IP               string
	GatewayID         string
	AgentID          string
	Hostname         *string
	MAC              *string
	DiscoverySources []string
	IsAvailable      bool
	FirstSeen        time.Time
	LastSeen         time.Time
	DeviceType       string

	IntegrationID    *string
	CollectorAgentID *string
	Capabilities     []string
	Metadata         map[string]string
}
