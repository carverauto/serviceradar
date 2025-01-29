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

	// Handle nil cases (invalid IPs) by falling back to string comparison
	if ip1 == nil || ip2 == nil {
		return s[i] < s[j]
	}

	// Convert to 4-byte representation for IPv4
	ip1 = ip1.To4()
	ip2 = ip2.To4()

	if ip1 == nil || ip2 == nil {
		return s[i] < s[j]
	}

	// Compare each byte
	for i := 0; i < 4; i++ {
		if ip1[i] != ip2[i] {
			return ip1[i] < ip2[i]
		}
	}

	return false
}
