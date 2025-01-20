package sweeper

import (
	"net"
)

// GenerateIPsFromCIDR generates all IP addresses in a CIDR range.
func GenerateIPsFromCIDR(network string) ([]net.IP, error) {
	ip, ipnet, err := net.ParseCIDR(network)
	if err != nil {
		return nil, err
	}

	var ips []net.IP

	for i := ip.Mask(ipnet.Mask); ipnet.Contains(i); inc(i) {
		// Skip network and broadcast addresses for IPv4
		if i.To4() != nil && isFirstOrLastAddress(i, ipnet) {
			continue
		}

		newIP := make(net.IP, len(i))
		copy(newIP, i)

		ips = append(ips, newIP)
	}

	return ips, nil
}

// ContainsMode checks if a mode is in a list of modes.
func ContainsMode(modes []SweepMode, mode SweepMode) bool {
	for _, m := range modes {
		if m == mode {
			return true
		}
	}

	return false
}

// inc increments an IP address.
func inc(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++

		if ip[j] > 0 {
			break
		}
	}
}

// isFirstOrLastAddress checks if the IP is the network or broadcast address.
func isFirstOrLastAddress(ip net.IP, network *net.IPNet) bool {
	// Get the IP address as 4-byte slice for IPv4
	ipv4 := ip.To4()
	if ipv4 == nil {
		return false
	}

	// Check if it's the network address (first address)
	if ipv4.Equal(ip.Mask(network.Mask)) {
		return true
	}

	// Create broadcast address
	broadcast := make(net.IP, len(ipv4))
	for i := range ipv4 {
		broadcast[i] = ipv4[i] | ^network.Mask[i]
	}

	// Check if it's the broadcast address (last address)
	return ipv4.Equal(broadcast)
}
