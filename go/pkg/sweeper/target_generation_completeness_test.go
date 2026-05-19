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
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

// TestTargetGeneration_AllPortsForEveryIP verifies that createTargetsForIP
// generates a target for EVERY configured port and mode.
func TestTargetGeneration_AllPortsForEveryIP(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 80, 443, 8080, 8443},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	ip := "10.0.0.1"
	targets := sweeper.createTargetsForIP(ip, config.SweepModes, nil)

	// Should get: 1 ICMP + 5 TCP = 6 targets
	assert.Len(t, targets, 6,
		"Must generate 1 ICMP target + 1 TCP target per port (5 ports)")

	// Verify ICMP target
	icmpTargets := filterByMode(targets, models.ModeICMP)
	assert.Len(t, icmpTargets, 1, "Must have exactly 1 ICMP target")
	assert.Equal(t, ip, icmpTargets[0].Host)

	// Verify TCP targets - one for each port
	tcpTargets := filterByMode(targets, models.ModeTCP)
	assert.Len(t, tcpTargets, 5, "Must have exactly 5 TCP targets (one per port)")

	tcpPorts := make(map[int]bool)
	for _, t := range tcpTargets {
		tcpPorts[t.Port] = true
	}

	for _, port := range config.Ports {
		assert.True(t, tcpPorts[port],
			"Must have TCP target for port %d - no port should be skipped", port)
	}
}

// TestTargetGeneration_TCPOnlyMode verifies correct target generation when
// only TCP mode is configured (no ICMP).
func TestTargetGeneration_TCPOnlyMode(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 80, 443},
		SweepModes: []models.SweepMode{models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := sweeper.createTargetsForIP("10.0.0.1", config.SweepModes, nil)

	// Should get only TCP targets: 3 ports × 1 TCP = 3 targets
	assert.Len(t, targets, 3, "TCP-only mode should generate one target per port")

	icmpTargets := filterByMode(targets, models.ModeICMP)
	assert.Empty(t, icmpTargets, "Should have no ICMP targets in TCP-only mode")

	tcpTargets := filterByMode(targets, models.ModeTCP)
	assert.Len(t, tcpTargets, 3, "Should have one TCP target per configured port")
}

// TestTargetGeneration_ICMPOnlyMode verifies correct target generation when
// only ICMP mode is configured.
func TestTargetGeneration_ICMPOnlyMode(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 80, 443},
		SweepModes: []models.SweepMode{models.ModeICMP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := sweeper.createTargetsForIP("10.0.0.1", config.SweepModes, nil)

	// ICMP only: 1 target
	assert.Len(t, targets, 1, "ICMP-only mode should generate exactly 1 target per IP")

	icmpTargets := filterByMode(targets, models.ModeICMP)
	assert.Len(t, icmpTargets, 1)

	tcpTargets := filterByMode(targets, models.ModeTCP)
	assert.Empty(t, tcpTargets, "Should have no TCP targets in ICMP-only mode")
}

// TestTargetGeneration_AllModesIncludingTCPConnect verifies all three scan modes.
func TestTargetGeneration_AllModesIncludingTCPConnect(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 80},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP, models.ModeTCPConnect},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := sweeper.createTargetsForIP("10.0.0.1", config.SweepModes, nil)

	// 1 ICMP + 2 TCP + 2 TCPConnect = 5 targets
	assert.Len(t, targets, 5)

	icmpTargets := filterByMode(targets, models.ModeICMP)
	tcpTargets := filterByMode(targets, models.ModeTCP)
	tcpConnectTargets := filterByMode(targets, models.ModeTCPConnect)

	assert.Len(t, icmpTargets, 1, "1 ICMP target")
	assert.Len(t, tcpTargets, 2, "2 TCP targets (one per port)")
	assert.Len(t, tcpConnectTargets, 2, "2 TCP Connect targets (one per port)")
	assert.Equal(t, "ipv4", icmpTargets[0].Metadata["address_family"])
	assert.Equal(t, "icmp", icmpTargets[0].Metadata["effective_sweep_mode"])
	assert.Equal(t, false, icmpTargets[0].Metadata["ipv6_raw_syn_fallback"])
}

func TestTargetGeneration_IPv6KeepsICMPAndUsesTCPConnect(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 443},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := sweeper.createTargetsForIP("2001:470:c0b5:2::100", config.SweepModes, nil)

	assert.Len(t, targets, 3)
	icmpTargets := filterByMode(targets, models.ModeICMP)
	require.Len(t, icmpTargets, 1)
	assert.Equal(t, "ipv6", icmpTargets[0].Metadata["address_family"])
	assert.Equal(t, "icmp", icmpTargets[0].Metadata["requested_sweep_mode"])
	assert.Equal(t, "icmp", icmpTargets[0].Metadata["effective_sweep_mode"])
	assert.Equal(t, "icmp", icmpTargets[0].Metadata["scanner_path"])
	assert.Equal(t, false, icmpTargets[0].Metadata["ipv6_raw_syn_fallback"])

	assert.Empty(t, filterByMode(targets, models.ModeTCP))

	tcpConnectTargets := filterByMode(targets, models.ModeTCPConnect)
	require.Len(t, tcpConnectTargets, 2)

	for _, target := range tcpConnectTargets {
		assert.Equal(t, "2001:470:c0b5:2::100", target.Host)
		assert.Equal(t, "ipv6", target.Metadata["address_family"])
		assert.Equal(t, []string{"icmp", "tcp"}, target.Metadata["requested_sweep_modes"])
		assert.Equal(t, "tcp", target.Metadata["requested_sweep_mode"])
		assert.Equal(t, "tcp_connect", target.Metadata["effective_sweep_mode"])
		assert.Equal(t, "tcp_connect_ipv6_raw_syn_fallback", target.Metadata["scanner_path"])
		assert.Equal(t, true, target.Metadata["ipv6_raw_syn_fallback"])
	}
}

func TestTargetGeneration_IPv6UsesRawSYNWhenCapabilityAvailable(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 443},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
		tcpScanner: statsCapabilityScanner{
			caps: scan.ScannerCapabilities{RawSYNIPv6: true},
		},
	}

	targets := sweeper.createTargetsForIP("2001:470:c0b5:2::100", config.SweepModes, nil)

	assert.Len(t, targets, 3)
	tcpTargets := filterByMode(targets, models.ModeTCP)
	require.Len(t, tcpTargets, 2)
	assert.Empty(t, filterByMode(targets, models.ModeTCPConnect))

	for _, target := range tcpTargets {
		assert.Equal(t, "ipv6", target.Metadata["address_family"])
		assert.Equal(t, "tcp", target.Metadata["requested_sweep_mode"])
		assert.Equal(t, "tcp", target.Metadata["effective_sweep_mode"])
		assert.Equal(t, "tcp", target.Metadata["scanner_path"])
		assert.Equal(t, false, target.Metadata["ipv6_raw_syn_fallback"])
	}
}

func TestTargetGeneration_IPv6DoesNotDuplicateTCPConnect(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22, 443},
		SweepModes: []models.SweepMode{models.ModeTCP, models.ModeTCPConnect},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := sweeper.createTargetsForIP("2001:db8::42", config.SweepModes, nil)

	assert.Len(t, targets, 2)
	assert.Empty(t, filterByMode(targets, models.ModeTCP))
	assert.Len(t, filterByMode(targets, models.ModeTCPConnect), 2)
}

func TestTargetGeneration_TargetMetadataIsPerTarget(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	baseMetadata := map[string]interface{}{"source": "test"}
	targets := sweeper.createTargetsForIP("2001:db8::42", config.SweepModes, baseMetadata)

	require.Len(t, targets, 2)

	targets[0].Metadata["source"] = "mutated"
	assert.Equal(t, "test", targets[1].Metadata["source"])
	assert.Equal(t, "test", baseMetadata["source"])
}

func TestTargetGeneration_RouteSummaryCountsIPv6Fallbacks(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports:      []int{22},
		SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets := append(
		sweeper.createTargetsForIP("192.0.2.10", config.SweepModes, nil),
		sweeper.createTargetsForIP("2001:db8::42", config.SweepModes, nil)...,
	)

	summary := summarizeTargetRoutes(targets)
	assert.Equal(t, 2, summary.ipv4Targets)
	assert.Equal(t, 2, summary.ipv6Targets)
	assert.Equal(t, 1, summary.ipv6TCPConnectFallbackTargets)
}

func TestTargetGeneration_BroadIPv6CIDRRejected(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Networks:   []string{"2001:db8::/64"},
		SweepModes: []models.SweepMode{models.ModeICMP},
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets, err := sweeper.generateTargets()
	require.Error(t, err)
	assert.Nil(t, targets)
	assert.Contains(t, err.Error(), "IPv6 CIDR")
}

// TestTargetGeneration_DeviceTargetsGetAllPorts verifies that device targets
// from sync service get all configured ports.
func TestTargetGeneration_DeviceTargetsGetAllPorts(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports: []int{22, 80, 443, 3306, 5432},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "192.168.1.10/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Metadata: map[string]string{
					"agent_id":   "test-agent",
					"gateway_id": "test-gw",
				},
			},
			{
				Network:    "10.0.0.5/32",
				SweepModes: []models.SweepMode{models.ModeTCP}, // TCP only
				Metadata: map[string]string{
					"agent_id":   "test-agent",
					"gateway_id": "test-gw",
				},
			},
		},
		Interval:  time.Minute,
		AgentID:   "test-agent",
		GatewayID: "test-gw",
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets, err := sweeper.generateTargets()
	require.NoError(t, err)

	// Device 1 (192.168.1.10): 1 ICMP + 5 TCP = 6 targets
	// Device 2 (10.0.0.5): 5 TCP only = 5 targets
	// Total: 11 targets

	device1Targets := filterByHost(targets, "192.168.1.10")
	device2Targets := filterByHost(targets, "10.0.0.5")

	assert.Len(t, device1Targets, 6,
		"Device 1 (ICMP+TCP) must have 1 ICMP + 5 TCP = 6 targets")
	assert.Len(t, device2Targets, 5,
		"Device 2 (TCP-only) must have 5 TCP targets (one per port)")

	// Verify all 5 ports are represented for device 2
	device2Ports := make(map[int]bool)
	for _, t := range device2Targets {
		device2Ports[t.Port] = true
	}

	for _, port := range config.Ports {
		assert.True(t, device2Ports[port],
			"Device 2 must have a target for port %d", port)
	}
}

// TestTargetGeneration_MultiIPDevice verifies that when a device has multiple IPs,
// each IP gets its own DeviceTarget entry (from the gateway/sync service),
// and each entry generates targets for ALL configured ports.
// Note: The sweeper intentionally uses only the primary network CIDR per DeviceTarget.
// Multi-IP expansion is handled at the gateway level with separate DeviceTarget entries.
func TestTargetGeneration_MultiIPDevice(t *testing.T) {
	t.Parallel()

	config := &models.Config{
		Ports: []int{22, 80, 443},
		DeviceTargets: []models.DeviceTarget{
			{
				Network:    "192.168.1.10/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Metadata: map[string]string{
					"armis_device_id": "device-123",
					"agent_id":        "test-agent",
					"gateway_id":      "test-gw",
					"partition":       "default",
				},
			},
			{
				Network:    "10.0.0.10/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Metadata: map[string]string{
					"armis_device_id": "device-123",
					"agent_id":        "test-agent",
					"gateway_id":      "test-gw",
					"partition":       "default",
				},
			},
			{
				Network:    "172.16.0.10/32",
				SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCP},
				Metadata: map[string]string{
					"armis_device_id": "device-123",
					"agent_id":        "test-agent",
					"gateway_id":      "test-gw",
					"partition":       "default",
				},
			},
		},
		Interval:  time.Minute,
		AgentID:   "test-agent",
		GatewayID: "test-gw",
	}

	sweeper := &NetworkSweeper{
		config: config,
		logger: logger.NewTestLogger(),
	}

	targets, err := sweeper.generateTargets()
	require.NoError(t, err)

	// 3 IPs × (1 ICMP + 3 TCP) = 3 × 4 = 12 targets
	assert.Len(t, targets, 12,
		"3 IPs × (1 ICMP + 3 TCP ports) = 12 total targets")

	// Verify each IP has all targets
	for _, ip := range []string{"192.168.1.10", "10.0.0.10", "172.16.0.10"} {
		ipTargets := filterByHost(targets, ip)
		assert.Len(t, ipTargets, 4,
			"IP %s must have 4 targets (1 ICMP + 3 TCP)", ip)

		icmpTargets := filterByMode(ipTargets, models.ModeICMP)
		assert.Len(t, icmpTargets, 1, "IP %s must have 1 ICMP target", ip)

		tcpTargets := filterByMode(ipTargets, models.ModeTCP)
		assert.Len(t, tcpTargets, 3, "IP %s must have 3 TCP targets", ip)

		tcpPorts := make(map[int]bool)
		for _, t := range tcpTargets {
			tcpPorts[t.Port] = true
		}

		for _, port := range config.Ports {
			assert.True(t, tcpPorts[port],
				"IP %s must have TCP target for port %d", ip, port)
		}
	}

	// Verify all targets share the same armis_device_id for aggregation
	for _, target := range targets {
		deviceID, _ := target.Metadata["armis_device_id"].(string)
		assert.Equal(t, "device-123", deviceID,
			"All targets should have the same device ID for aggregation")
	}
}

func filterByMode(targets []models.Target, mode models.SweepMode) []models.Target {
	var filtered []models.Target
	for _, t := range targets {
		if t.Mode == mode {
			filtered = append(filtered, t)
		}
	}

	return filtered
}

func filterByHost(targets []models.Target, host string) []models.Target {
	var filtered []models.Target
	for _, t := range targets {
		if t.Host == host {
			filtered = append(filtered, t)
		}
	}

	return filtered
}
