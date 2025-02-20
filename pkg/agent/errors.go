package agent

import "errors"

var (
	errInvalidPort          = errors.New("invalid port")
	errDetailsRequiredPorts = errors.New("details field is required for port checks")
	errDetailsRequiredGRPC  = errors.New("details field is required for gRPC checks")
	errDetailsRequiredSNMP  = errors.New("details field is required for SNMP checks")
	errInvalidDetailsFormat = errors.New("invalid details format: expected 'host:port'")
	errSNMPServiceUnhealthy = errors.New("SNMP service reported unhealthy")
)
