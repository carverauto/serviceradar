// Package sweeper pkg/sweeper/target_generator.go
package sweeper

import (
	"fmt"
	"log"
	"net"
)

// generateTargets creates scan targets from CIDR ranges and ports.
func generateTargets(config Config) ([]Target, error) {
	var targets []Target

	for _, network := range config.Networks {
		// Parse CIDR range
		ip, ipnet, err := net.ParseCIDR(network)
		if err != nil {
			return nil, fmt.Errorf("invalid network %s: %w", network, err)
		}

		// Generate all IP addresses in the range
		for i := ip.Mask(ipnet.Mask); ipnet.Contains(i); inc(i) {
			// Skip network and broadcast addresses for IPv4
			if i.To4() != nil {
				if isFirstOrLastAddress(i, ipnet) {
					continue
				}
			}

			ipStr := i.String()
			log.Printf("Generated target IP: %s", ipStr)

			// Create a target for each port
			for _, port := range config.Ports {
				targets = append(targets, Target{
					Host: ipStr,
					Port: port,
				})
			}
		}
	}

	log.Printf("Generated %d total targets", len(targets))
	return targets, nil
}

// inc increments an IP address
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
