/*-
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewSweepService(t *testing.T) {
	tests := []struct {
		name    string
		config  *models.Config
		wantErr bool
	}{
		{
			name: "valid config",
			config: &models.Config{
				Networks: []string{"192.168.1.0/24"},
				Ports:    []int{80, 443},
				SweepModes: []models.SweepMode{
					models.ModeTCP,
					models.ModeICMP,
				},
			},
			wantErr: false,
		},
		{
			name:    "nil config",
			config:  nil,
			wantErr: false, // Should apply defaults
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc, err := NewSweepService(tt.config)
			if tt.wantErr {
				require.Error(t, err)
				assert.Nil(t, svc)

				return
			}

			require.NoError(t, err)
			assert.NotNil(t, svc)

			// Test service name
			assert.Equal(t, "network_sweep", svc.Name())
		})
	}
}

func TestApplyDefaultConfig(t *testing.T) {
	tests := []struct {
		name   string
		input  *models.Config
		verify func(*testing.T, *models.Config)
	}{
		{
			name:  "nil config",
			input: nil,
			verify: func(t *testing.T, config *models.Config) {
				t.Helper()

				assert.NotNil(t, config)
				assert.Equal(t, 5*time.Second, config.Timeout)
				assert.Equal(t, 25, config.Concurrency)
				assert.Equal(t, 2, config.ICMPCount)
				assert.Equal(t, 15*time.Minute, config.Interval)
				assert.Equal(t, 5, config.MaxIdle)
				assert.Equal(t, 10*time.Minute, config.MaxLifetime)
				assert.Equal(t, 30*time.Second, config.IdleTimeout)
				assert.Len(t, config.SweepModes, 2)
			},
		},
		{
			name: "custom values preserved",
			input: &models.Config{
				Timeout:     10 * time.Second,
				Concurrency: 50,
				ICMPCount:   5,
				Interval:    30 * time.Minute,
			},
			verify: func(t *testing.T, config *models.Config) {
				t.Helper()
				assert.Equal(t, 10*time.Second, config.Timeout)
				assert.Equal(t, 50, config.Concurrency)
				assert.Equal(t, 5, config.ICMPCount)
				assert.Equal(t, 30*time.Minute, config.Interval)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := applyDefaultConfig(tt.input)
			tt.verify(t, result)
		})
	}
}

func TestGenerateTargets(t *testing.T) {
	tests := []struct {
		name      string
		config    *models.Config
		wantCount int
		wantErr   bool
	}{
		{
			name: "single host",
			config: &models.Config{
				Networks: []string{"192.168.1.1/32"},
				Ports:    []int{80},
				SweepModes: []models.SweepMode{
					models.ModeTCP,
					models.ModeICMP,
				},
			},
			wantCount: 2, // 1 ICMP + 1 TCP target
			wantErr:   false,
		},
		{
			name: "small network",
			config: &models.Config{
				Networks: []string{"192.168.1.0/30"},
				Ports:    []int{80, 443},
				SweepModes: []models.SweepMode{
					models.ModeTCP,
				},
			},
			wantCount: 4, // 2 usable IPs * 2 ports
			wantErr:   false,
		},
		{
			name: "invalid CIDR",
			config: &models.Config{
				Networks: []string{"invalid"},
				Ports:    []int{80},
				SweepModes: []models.SweepMode{
					models.ModeTCP,
				},
			},
			wantCount: 0,
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			svc, err := NewSweepService(tt.config)
			require.NoError(t, err)

			sweepSvc, ok := svc.(*SweepService)
			require.True(t, ok)

			targets, err := sweepSvc.generateTargets()
			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			assert.Len(t, targets, tt.wantCount)

			// Verify target properties
			for _, target := range targets {
				assert.NotEmpty(t, target.Host)
				assert.Contains(t, target.Metadata, "network")
				assert.Contains(t, target.Metadata, "total_hosts")
			}
		})
	}
}

func TestUpdateStats(t *testing.T) {
	stats := newScanStats()

	// Test ICMP success
	result1 := &models.Result{
		Available: true,
		Target: models.Target{
			Host: "192.168.1.1",
			Mode: models.ModeICMP,
		},
	}
	updateStats(stats, result1)
	assert.Equal(t, 1, stats.totalResults)
	assert.Equal(t, 1, stats.successCount)
	assert.Equal(t, 1, stats.icmpSuccess)
	assert.Equal(t, 0, stats.tcpSuccess)
	assert.Len(t, stats.uniqueHosts, 1)

	// Test TCP success
	result2 := &models.Result{
		Available: true,
		Target: models.Target{
			Host: "192.168.1.2",
			Mode: models.ModeTCP,
			Port: 80,
		},
	}
	updateStats(stats, result2)
	assert.Equal(t, 2, stats.totalResults)
	assert.Equal(t, 2, stats.successCount)
	assert.Equal(t, 1, stats.icmpSuccess)
	assert.Equal(t, 1, stats.tcpSuccess)
	assert.Len(t, stats.uniqueHosts, 2)

	// Test failed result
	result3 := &models.Result{
		Available: false,
		Target: models.Target{
			Host: "192.168.1.3",
			Mode: models.ModeTCP,
		},
	}
	updateStats(stats, result3)
	assert.Equal(t, 3, stats.totalResults)
	assert.Equal(t, 2, stats.successCount)
	assert.Equal(t, 1, stats.icmpSuccess)
	assert.Equal(t, 1, stats.tcpSuccess)
	assert.Len(t, stats.uniqueHosts, 2)
}

func TestCalculateNetworkSize(t *testing.T) {
	tests := []struct {
		name     string
		ones     int
		bits     int
		expected int
	}{
		{
			name:     "single host (/32)",
			ones:     32,
			bits:     32,
			expected: 1,
		},
		{
			name:     "two hosts (/31)",
			ones:     31,
			bits:     32,
			expected: 2, // Special case: RFC 3021 allows both addresses to be used
		},
		{
			name:     "four hosts (/30)",
			ones:     30,
			bits:     32,
			expected: 2, // Network + broadcast = 2 usable addresses
		},
		{
			name:     "typical subnet (/24)",
			ones:     24,
			bits:     32,
			expected: 254, // 256 - 2 (network + broadcast)
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			size := calculateNetworkSize(tt.ones, tt.bits)
			assert.Equal(t, tt.expected, size)
		})
	}
}
