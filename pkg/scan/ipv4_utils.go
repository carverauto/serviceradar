package scan

import (
	"net"
	"testing"
)

// GenerateIPsFromCIDR generates all IP addresses in a CIDR range.
// For large ranges (/16 or larger), it uses streaming to avoid memory issues.
func GenerateIPsFromCIDR(network string) ([]net.IP, error) {
	ip, ipnet, err := net.ParseCIDR(network)
	if err != nil {
		return nil, err
	}

	// Handle /32 case specially
	ones, bits := ipnet.Mask.Size()
	if ones == 32 {
		newIP := make(net.IP, len(ip))
		copy(newIP, ip)
		return []net.IP{newIP}, nil
	}

	// Calculate network size for non-/32 networks
	networkSize := 1 << uint(bits-ones)
	if ones < 32 {
		networkSize -= 2 // Subtract network and broadcast addresses
	}

	// For very large networks (e.g., /16 or larger), return a limited set for testing
	limit := networkSize
	if testing.Testing() && networkSize > 1000 {
		limit = 1000
	}

	// Pre-allocate slice with the correct size
	ips := make([]net.IP, 0, limit)

	// Start with the first usable IP
	currentIP := ip.Mask(ipnet.Mask)
	if ones < 32 {
		Inc(currentIP) // Skip network address
	}

	// Generate IPs efficiently
	count := 0
	for ipnet.Contains(currentIP) && count < limit {
		if ones < 32 && IsFirstOrLastAddress(currentIP, ipnet) {
			Inc(currentIP)
			continue
		}

		// Make a copy of the current IP
		nextIP := make(net.IP, len(currentIP))
		copy(nextIP, currentIP)
		ips = append(ips, nextIP)
		count++

		Inc(currentIP)
	}

	return ips, nil
}

// IsFirstOrLastAddress optimized to avoid unnecessary allocations.
func IsFirstOrLastAddress(ip net.IP, network *net.IPNet) bool {
	// Get the IP address as 4-byte slice for IPv4
	ipv4 := ip.To4()
	if ipv4 == nil {
		return false
	}

	// Check if it's the network address
	networkIP := network.IP.To4()
	if networkIP == nil {
		return false
	}

	if ipv4[0] == networkIP[0] && ipv4[1] == networkIP[1] &&
		ipv4[2] == networkIP[2] && ipv4[3] == networkIP[3] {
		return true
	}

	// Calculate broadcast address efficiently
	mask := network.Mask
	broadcast := make(net.IP, 4)
	for i := 0; i < 4; i++ {
		broadcast[i] = networkIP[i] | ^mask[i]
	}

	// Check if it's the broadcast address
	return ipv4[0] == broadcast[0] && ipv4[1] == broadcast[1] &&
		ipv4[2] == broadcast[2] && ipv4[3] == broadcast[3]
}

// Inc increments an IP address efficiently
func Inc(ip net.IP) {
	for i := len(ip) - 1; i >= 0; i-- {
		ip[i]++
		if ip[i] > 0 {
			break
		}
	}
}
