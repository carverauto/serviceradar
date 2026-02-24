package models

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFilterIPsWithBlacklist(t *testing.T) {
	tests := []struct {
		name             string
		ips              []string
		blacklistCIDRs   []string
		expectedFiltered []string
		expectError      bool
	}{
		{
			name:             "no blacklist",
			ips:              []string{"192.168.1.1", "10.0.0.1", "172.16.0.1"},
			blacklistCIDRs:   []string{},
			expectedFiltered: []string{"192.168.1.1", "10.0.0.1", "172.16.0.1"},
			expectError:      false,
		},
		{
			name:             "single CIDR blacklist",
			ips:              []string{"192.168.1.1", "192.168.2.19", "10.0.0.1"},
			blacklistCIDRs:   []string{"192.168.2.19/32"},
			expectedFiltered: []string{"192.168.1.1", "10.0.0.1"},
			expectError:      false,
		},
		{
			name:             "multiple CIDR blacklist",
			ips:              []string{"192.168.1.1", "192.168.2.19", "10.0.0.1", "172.16.0.1"},
			blacklistCIDRs:   []string{"192.168.0.0/16", "10.0.0.0/8"},
			expectedFiltered: []string{"172.16.0.1"},
			expectError:      false,
		},
		{
			name:             "all IPs blacklisted",
			ips:              []string{"192.168.1.1", "192.168.2.19"},
			blacklistCIDRs:   []string{"192.168.0.0/16"},
			expectedFiltered: []string{},
			expectError:      false,
		},
		{
			name:             "invalid CIDR",
			ips:              []string{"192.168.1.1"},
			blacklistCIDRs:   []string{"invalid-cidr"},
			expectedFiltered: nil,
			expectError:      true,
		},
		{
			name:             "keep invalid IPs",
			ips:              []string{"192.168.1.1", "invalid-ip", "10.0.0.1"},
			blacklistCIDRs:   []string{"192.168.0.0/16"},
			expectedFiltered: []string{"invalid-ip", "10.0.0.1"},
			expectError:      false,
		},
		{
			name:             "CIDR notation IPs with blacklist",
			ips:              []string{"192.168.1.1/32", "192.168.2.19/32", "10.0.0.1/32"},
			blacklistCIDRs:   []string{"192.168.2.19/32"},
			expectedFiltered: []string{"192.168.1.1/32", "10.0.0.1/32"},
			expectError:      false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := FilterIPsWithBlacklist(tt.ips, tt.blacklistCIDRs)

			if tt.expectError {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
				assert.Equal(t, tt.expectedFiltered, result)
			}
		})
	}
}
