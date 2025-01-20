package scan

import (
	"net"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGenerateIPsFromCIDR(t *testing.T) {
	tests := []struct {
		name      string
		cidr      string
		wantCount int
		wantErr   bool
	}{
		{
			name:      "valid /30 network",
			cidr:      "192.168.1.0/30",
			wantCount: 2, // Excluding network and broadcast addresses
			wantErr:   false,
		},
		{
			name:      "invalid CIDR",
			cidr:      "invalid",
			wantCount: 0,
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ips, err := GenerateIPsFromCIDR(tt.cidr)

			if tt.wantErr {
				require.Error(t, err)
				return
			}

			require.NoError(t, err)
			assert.Len(t, ips, tt.wantCount)

			if len(ips) > 0 {
				// Verify they are valid IPs
				for _, ip := range ips {
					assert.NotNil(t, ip.To4())
				}
			}
		})
	}
}

func TestInc(t *testing.T) {
	tests := []struct {
		name string
		ip   net.IP
		want net.IP
	}{
		{
			name: "normal increment",
			ip:   net.ParseIP("192.168.1.1"),
			want: net.ParseIP("192.168.1.2"),
		},
		{
			name: "increment with rollover",
			ip:   net.ParseIP("192.168.1.255"),
			want: net.ParseIP("192.168.2.0"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ipCopy := make(net.IP, len(tt.ip))
			copy(ipCopy, tt.ip)

			Inc(ipCopy)
			assert.Equal(t, tt.want.String(), ipCopy.String())
		})
	}
}

func TestIsFirstOrLastAddress(t *testing.T) {
	tests := []struct {
		name    string
		ip      string
		network string
		want    bool
	}{
		{
			name:    "network address",
			ip:      "192.168.1.0",
			network: "192.168.1.0/24",
			want:    true,
		},
		{
			name:    "broadcast address",
			ip:      "192.168.1.255",
			network: "192.168.1.0/24",
			want:    true,
		},
		{
			name:    "regular address",
			ip:      "192.168.1.100",
			network: "192.168.1.0/24",
			want:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ip := net.ParseIP(tt.ip)
			_, network, err := net.ParseCIDR(tt.network)
			require.NoError(t, err)

			got := IsFirstOrLastAddress(ip, network)
			assert.Equal(t, tt.want, got)
		})
	}
}
