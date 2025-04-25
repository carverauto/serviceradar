package cli

import (
	"fmt"
	"net"
	"strings"
)

// normalizeServiceType standardizes service type names.
func normalizeServiceType(serviceType string) string {
	// Convert to lowercase for case-insensitive matching
	serviceType = strings.ToLower(serviceType)

	// Remove "serviceradar-" prefix if present
	serviceType = strings.TrimPrefix(serviceType, "serviceradar-")

	// Remove "-checker" suffix if present
	serviceType = strings.TrimSuffix(serviceType, "-checker")

	// Map known aliases to standard types
	switch serviceType {
	case "rperf", "rperf-service", "perf":
		return "rperf-checker"
	case "system", "system-monitor", "sysmonitor", "systemmon":
		return "sysmon"
	case "snmpchecker", "snmp-service":
		return "snmp"
	case "dusk-checker", "dusk-service":
		return "dusk"
	case "sweep-checker", "network-sweep", "networksweep":
		return "sweep"
	case "ping":
		return "icmp"
	}

	return serviceType
}

// getLocalIP returns the non-loopback local IP of the host.
func getLocalIP() (string, error) {
	// This implementation tries to find a non-loopback IP address
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return defaultIPAddress, fmt.Errorf("error getting interface addresses: %w", err)
	}

	for _, addr := range addrs {
		// Check if it's an IP network
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			// Check if it's IPv4
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String(), nil
			}
		}
	}

	// No suitable address found, return localhost
	return defaultIPAddress, nil
}
