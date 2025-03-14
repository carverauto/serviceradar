package scan

import (
	"encoding/binary"
	"net"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// IPToUint32 converts an IPv4 address string to a uint32.
func IPToUint32(ipStr string) uint32 {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return 0
	}
	ip = ip.To4()
	if ip == nil {
		return 0
	}
	return binary.BigEndian.Uint32(ip)
}

// Uint32ToIP converts a uint32 back to an IPv4 net.IP.
func Uint32ToIP(n uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, n)
	return ip
}

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

// MergeResults combines results from multiple channels into a single channel.
// Closes the output channel when all input channels are closed.
func MergeResults(chans ...<-chan models.Result) <-chan models.Result {
	out := make(chan models.Result, 100)
	go func() {
		defer close(out)
		var wg sync.WaitGroup
		wg.Add(len(chans))
		for _, ch := range chans {
			go func(c <-chan models.Result) {
				defer wg.Done()
				for r := range c {
					out <- r
				}
			}(ch)
		}
		wg.Wait()
	}()
	return out
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

// DefaultTimeout returns a default timeout if the provided one is zero.
func DefaultTimeout(t time.Duration, defaultVal time.Duration) time.Duration {
	if t == 0 {
		return defaultVal
	}
	return t
}
