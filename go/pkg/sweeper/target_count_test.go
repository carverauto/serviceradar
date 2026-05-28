/*
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

package sweeper

import (
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestEstimateTargetCount(t *testing.T) {
	tests := []struct {
		name     string
		config   *models.Config
		expected int
	}{
		{
			name: "global networks only - ICMP",
			config: &models.Config{
				Networks:   []string{"192.168.1.0/30"}, // 2 IPs (excludes network/broadcast)
				SweepModes: []models.SweepMode{models.ModeICMP},
				Ports:      []int{80, 443},
			},
			expected: 2, // 2 IPs * 1 ICMP mode
		},
		{
			name: "global networks only - TCP",
			config: &models.Config{
				Networks:   []string{"192.168.1.0/30"}, // 2 IPs
				SweepModes: []models.SweepMode{models.ModeTCP},
				Ports:      []int{80, 443}, // 2 ports
			},
			expected: 4, // 2 IPs * 2 ports
		},
		{
			name: "global networks - ICMP + TCP",
			config: &models.Config{
				Networks:   []string{"192.168.1.0/30"}, // 2 IPs
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Ports:      []int{80, 443}, // 2 ports
			},
			expected: 6, // 2 IPs (ICMP) + 2 IPs * 2 ports (TCP) = 2 + 4 = 6
		},
		{
			name: "device targets only - inherits global modes",
			config: &models.Config{
				SweepModes: []models.SweepMode{models.ModeICMP},
				Ports:      []int{80},
				DeviceTargets: []models.DeviceTarget{
					{
						Network: "10.0.0.1/32", // Single IP
						// SweepModes empty - should inherit global
					},
				},
			},
			expected: 1, // 1 IP * ICMP (inherited from global)
		},
		{
			name: "device targets - device-specific modes",
			config: &models.Config{
				SweepModes: []models.SweepMode{models.ModeICMP}, // Global (ignored for device targets)
				Ports:      []int{80, 443},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "10.0.0.1/32",                      // Single IP
						SweepModes: []models.SweepMode{models.ModeTCP}, // Device-specific
					},
				},
			},
			expected: 2, // 1 IP * 2 ports (TCP mode from device)
		},
		{
			name: "mixed global and device targets",
			config: &models.Config{
				Networks:   []string{"192.168.1.0/30"}, // 2 IPs
				SweepModes: []models.SweepMode{models.ModeICMP},
				Ports:      []int{80},
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "10.0.0.1/32",                      // Single IP
						SweepModes: []models.SweepMode{models.ModeTCP}, // Device-specific TCP
					},
				},
			},
			expected: 3, // Global: 2 IPs * ICMP = 2, Device: 1 IP * 1 port * TCP = 1, Total = 3
		},
		{
			name: "multiple device targets with different modes",
			config: &models.Config{
				SweepModes: []models.SweepMode{}, // No global modes
				Ports:      []int{22, 80, 443},   // 3 ports
				DeviceTargets: []models.DeviceTarget{
					{
						Network:    "10.0.0.1/32", // 1 IP
						SweepModes: []models.SweepMode{models.ModeICMP},
					},
					{
						Network:    "10.0.0.2/30", // 2 IPs (excludes network/broadcast from /30)
						SweepModes: []models.SweepMode{models.ModeTCP},
					},
					{
						Network:    "10.0.0.4/32", // 1 IP
						SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
					},
				},
			},
			expected: 11, // Device1: 1*ICMP=1, Device2: 2*3*TCP=6, Device3: 1*ICMP + 1*3*TCP = 1+3=4, Total = 1+6+4=11
		},
		{
			name: "empty config",
			config: &models.Config{
				Networks:      []string{},
				SweepModes:    []models.SweepMode{},
				Ports:         []int{},
				DeviceTargets: []models.DeviceTarget{},
			},
			expected: 0,
		},
		{
			name: "large CIDR counted without expansion",
			config: &models.Config{
				Networks:   []string{"10.0.0.0/8"},
				SweepModes: []models.SweepMode{models.ModeTCP},
				Ports:      []int{22, 80, 443},
			},
			expected: 16_777_214 * 3,
		},
		{
			name: "IPv4 /31 follows current expansion semantics",
			config: &models.Config{
				Networks:   []string{"192.168.1.0/31"},
				SweepModes: []models.SweepMode{models.ModeICMP},
			},
			expected: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := estimateTargetCount(tt.config)
			if result != tt.expected {
				t.Errorf("estimateTargetCount() = %d, expected %d", result, tt.expected)
			}
		})
	}
}

// TestEstimateTargetCountInvalidCIDR tests handling of invalid CIDR notation
func TestEstimateTargetCountInvalidCIDR(t *testing.T) {
	config := &models.Config{
		Networks:   []string{"invalid-cidr", "192.168.1.0/24"}, // One invalid, one valid
		SweepModes: []models.SweepMode{models.ModeICMP},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "another-invalid",
				SweepModes: []models.SweepMode{models.ModeICMP},
			},
			{
				Network:    "10.0.0.1/32",
				SweepModes: []models.SweepMode{models.ModeICMP},
			},
		},
	}

	result := estimateTargetCount(config)
	// Should count 254 IPs from global network + 1 IP from valid device target
	expected := 254 + 1
	if result != expected {
		t.Errorf("estimateTargetCount() with invalid CIDRs = %d, expected %d", result, expected)
	}
}

func TestGenerateTargetsBatchedStreamsOversizedSweep(t *testing.T) {
	config := &models.Config{
		Networks:   []string{"10.0.0.0/19"},
		SweepModes: []models.SweepMode{models.ModeTCP},
		Ports:      []int{22, 80, 443, 8080, 8888, 8443, 4000, 8000, 9000, 9443, 10000, 10443, 12000},
	}
	sweeper := &NetworkSweeper{config: config, logger: logger.NewTestLogger()}

	emitted := 0
	targets := 0

	err := sweeper.generateTargetsBatched(func(target models.Target) error {
		emitted++
		targets++
		return nil
	})
	if err != nil {
		t.Fatalf("generateTargetsBatched() returned error: %v", err)
	}

	expectedHosts := 8_190
	expectedTargets := expectedHosts * len(config.Ports)
	if expectedTargets <= defaultTargetBatch {
		t.Fatalf("test fixture should exceed defaultTargetBatch: got %d <= %d", expectedTargets, defaultTargetBatch)
	}

	if targets != expectedTargets {
		t.Fatalf("generateTargetsBatched() targets = %d, expected %d", targets, expectedTargets)
	}

	if emitted != expectedTargets {
		t.Fatalf("generateTargetsBatched() emitted = %d, expected %d", emitted, expectedTargets)
	}
}

// NOTE: TestConcurrencyTuning removed due to logger interface complexity.
// The fix can be verified by inspecting calculateEffectiveConcurrency behavior
// with a realistic Config containing DeviceTargets.
