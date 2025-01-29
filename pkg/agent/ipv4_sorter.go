package agent

import (
	"net"
	"sort"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

// IPSorter is a type for sorting IP addresses
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

// SortIPList sorts a list of IP addresses in natural order
func SortIPList(ips []string) {
	sort.Sort(IPSorter(ips))
}

func SortHostResults(hosts []models.HostResult) {
	// Create a custom sorter type for HostResults
	sort.Slice(hosts, func(i, j int) bool {
		ip1 := net.ParseIP(hosts[i].Host)
		ip2 := net.ParseIP(hosts[j].Host)

		// Handle nil cases
		if ip1 == nil || ip2 == nil {
			return hosts[i].Host < hosts[j].Host
		}

		// Convert to 4-byte representation
		ip1 = ip1.To4()
		ip2 = ip2.To4()
		if ip1 == nil || ip2 == nil {
			return hosts[i].Host < hosts[j].Host
		}

		// Compare each byte
		for k := 0; k < 4; k++ {
			if ip1[k] != ip2[k] {
				return ip1[k] < ip2[k]
			}
		}
		return false
	})
}
