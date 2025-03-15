package scan

import (
	"net"

	"github.com/carverauto/serviceradar/pkg/models"
)

// ExpandCIDR expands a CIDR notation into a slice of IP addresses.
// Skips network and broadcast addresses for non-/32 networks.
func ExpandCIDR(cidr string) ([]string, error) {
	ip, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, err
	}

	var ips []string
	for ip := ip.Mask(ipnet.Mask); ipnet.Contains(ip); incIP(ip) {
		// Skip network and broadcast addresses for IPv4 non-/32
		ones, _ := ipnet.Mask.Size()
		if ip.To4() != nil && ones != 32 {
			if ip.Equal(ipnet.IP) || isBroadcast(ip, ipnet) {
				continue
			}
		}

		ips = append(ips, ip.String())
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
