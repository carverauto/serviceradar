package models

import "time"

type Duration time.Duration

// SNMPConfig represents SNMP checker configuration.
type SNMPConfig struct {
	NodeAddress string          `json:"node_address"`
	Timeout     Duration        `json:"timeout"`
	ListenAddr  string          `json:"listen_addr"`
	Security    *SecurityConfig `json:"security"`
	Targets     []Target        `json:"targets"`
}
