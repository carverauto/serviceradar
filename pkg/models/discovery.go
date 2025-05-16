package models

import "github.com/carverauto/serviceradar/pkg/checker/snmp"

// DiscoveryConfig holds the configuration for the discovery engine.
type DiscoveryConfig struct {
	SeedIPs     []string          `json:"seed_ips"`
	SeedSubnets []string          `json:"seed_subnets"`
	Credentials []snmp.Target     `json:"credentials"`
	Concurrency int               `json:"concurrency"`
	Interval    Duration          `json:"interval"`
	Timeout     Duration          `json:"timeout"`
	Retries     int               `json:"retries"`
	OIDs        map[string]string `json:"oids"`
}
