package scan

import (
	"net"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ExpandCIDR expands a CIDR notation into a slice of IP addresses.
// Skips network and broadcast addresses for non-/32 networks.
func ExpandCIDR(cidr string) ([]string, error) {
	baseIP, ipnet, err := net.ParseCIDR(cidr) // Renamed outer "ip" to "baseIP"
	if err != nil {
		return nil, err
	}

	var ips []string

	for currentIP := baseIP.Mask(ipnet.Mask); ipnet.Contains(currentIP); incIP(currentIP) { // Renamed loop "ip" to "currentIP"
		// Skip network and broadcast addresses for IPv4 non-/32
		ones, _ := ipnet.Mask.Size()
		if currentIP.To4() != nil && ones != 32 {
			if currentIP.Equal(ipnet.IP) || isBroadcast(currentIP, ipnet) {
				continue
			}
		}

		ips = append(ips, currentIP.String())
	}

	return ips, nil
}

// incIP increments an IP address in place.
func incIP(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] != 0 {
			break
		}
	}
}

// isBroadcast checks if an IP is the broadcast address of a network.
func isBroadcast(ip net.IP, ipnet *net.IPNet) bool {
	broadcast := make(net.IP, len(ip))
	for i := range ip {
		broadcast[i] = ipnet.IP[i] | ^ipnet.Mask[i]
	}

	return ip.Equal(broadcast)
}

// TargetFromIP creates a models.Target from an IP string and mode, with optional port.
func TargetFromIP(ip string, mode models.SweepMode, port ...int) models.Target {
	t := models.Target{
		Host: ip,
		Mode: mode,
	}

	if len(port) > 0 {
		t.Port = port[0]
	}

	return t
}
