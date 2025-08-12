package models

import (
	"fmt"
	"net"
)

type SourceConfig struct {
	Type               string            `json:"type"`                   // "armis", "netbox", etc.
	Endpoint           string            `json:"endpoint"`               // API endpoint
	Credentials        map[string]string `json:"credentials"`            // e.g., {"api_key": "xyz"}
	Prefix             string            `json:"prefix"`                 // KV key prefix, e.g., "armis/"
	InsecureSkipVerify bool              `json:"insecure_skip_verify"`   // For TLS connections
	Queries            []QueryConfig     `json:"queries"`                // List of AQL/ASQ queries
	CustomField        string            `json:"custom_field,omitempty"` // Custom field for additional metadata

	// AgentID and PollerID allow assigning discovered devices to specific
	// agents and pollers. When set, they override any global defaults for
	// the Sync service.
	AgentID   string `json:"agent_id,omitempty"`
	PollerID  string `json:"poller_id,omitempty"`
	Partition string `json:"partition,omitempty"`

	// SweepInterval allows configuring how often agents should sweep the
	// networks discovered by this source. If empty, a sensible default is
	// used by each integration.
	SweepInterval string `json:"sweep_interval,omitempty"`

	// PollInterval allows configuring how often this specific source should be polled.
	// If empty, uses the global PollInterval from the sync config.
	PollInterval Duration `json:"poll_interval,omitempty"`

	// NetworkBlacklist contains CIDR ranges to filter out from this specific source
	NetworkBlacklist []string `json:"network_blacklist,omitempty"`
}

// QueryConfig represents a single labeled AQL/ASQ query.
type QueryConfig struct {
	Label      string      `json:"label"`       // Name or description of the query
	Query      string      `json:"query"`       // The AQL/ASQ query string
	SweepModes []SweepMode `json:"sweep_modes"` // Sweep modes to apply to devices from this query
}

// FilterIPsWithBlacklist filters out IP addresses that match the given CIDR blacklist.
// This is a utility function to be used by sync integrations to apply network blacklisting.
func FilterIPsWithBlacklist(ips, blacklistCIDRs []string) ([]string, error) {
	if len(blacklistCIDRs) == 0 {
		return ips, nil
	}

	// Parse blacklist CIDRs
	blacklistNets := make([]*net.IPNet, 0, len(blacklistCIDRs))

	for _, cidr := range blacklistCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		blacklistNets = append(blacklistNets, network)
	}

	// Filter IPs
	filtered := make([]string, 0, len(ips))

	for _, ip := range ips {
		// Handle both plain IP addresses and CIDR notation
		var parsedIP net.IP
		if parsedIP = net.ParseIP(ip); parsedIP == nil {
			// Try parsing as CIDR (e.g., "192.168.1.10/32")
			ipAddr, _, err := net.ParseCIDR(ip)
			if err != nil {
				// Keep invalid IPs as-is (they'll be handled elsewhere)
				filtered = append(filtered, ip)
				continue
			}

			parsedIP = ipAddr
		}

		isBlacklisted := false

		for _, network := range blacklistNets {
			if network.Contains(parsedIP) {
				isBlacklisted = true
				break
			}
		}

		if !isBlacklisted {
			filtered = append(filtered, ip)
		}
	}

	return filtered, nil
}
