package agent

import (
	"net"
)

// IPSorter is a type for sorting IP addresses.
type IPSorter []string

func (s IPSorter) Len() int { return len(s) }

func (s IPSorter) Swap(i, j int) { s[i], s[j] = s[j], s[i] }

func (s IPSorter) Less(i, j int) bool {
	ip1 := net.ParseIP(s[i])
	ip2 := net.ParseIP(s[j])

	// Handle invalid IPs
	if ip1 == nil && ip2 == nil {
		// Both invalid, sort alphabetically
		return s[i] < s[j]
	}
	if ip1 == nil {
		// First is invalid, should come first
		return true
	}
	if ip2 == nil {
		// Second is invalid, should not come first
		return false
	}

	// Both are valid IPs, convert to IPv4
	ip1 = ip1.To4()
	ip2 = ip2.To4()

	// Handle non-IPv4 addresses
	if ip1 == nil && ip2 == nil {
		return s[i] < s[j]
	}
	if ip1 == nil {
		return true
	}
	if ip2 == nil {
		return false
	}

	// Compare IPv4 addresses byte by byte
	for k := 0; k < 4; k++ {
		if ip1[k] != ip2[k] {
			return ip1[k] < ip2[k]
		}
	}

	return false
}
