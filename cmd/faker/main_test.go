package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestGenerateAllDevicesHasUniqueIPsAndHostnames(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping full device generation in short mode")
	}

	originalTotal := totalDevices
	t.Cleanup(func() {
		totalDevices = originalTotal
	})
	totalDevices = 5000

	gen := NewDeviceGenerator()
	deviceGen = gen
	devices := gen.generateAllDevices()

	require.Len(t, devices, totalDevices)

	ipSet := make(map[string]struct{}, len(devices))
	nameSet := make(map[string]struct{}, len(devices))

	for _, d := range devices {
		ips := strings.Split(d.IPAddress, ",")
		require.Len(t, ips, 1)

		ip := strings.TrimSpace(ips[0])
		require.NotEmpty(t, ip)
		if _, exists := ipSet[ip]; exists {
			t.Fatalf("duplicate IP generated: %s", ip)
		}
		ipSet[ip] = struct{}{}

		name := strings.TrimSpace(d.Name)
		require.NotEmpty(t, name)
		if _, exists := nameSet[name]; exists {
			t.Fatalf("duplicate hostname generated: %s", name)
		}
		nameSet[name] = struct{}{}
	}
}

func TestSwapDevicePrimaryIPsPreservesCardinality(t *testing.T) {
	gen := &DeviceGenerator{
		allDevices: []ArmisDevice{
			{ID: 1, IPAddress: "10.0.0.1"},
			{ID: 2, IPAddress: "10.0.0.2"},
			{ID: 3, IPAddress: "10.0.0.3"},
		},
		usedIPs: map[string]struct{}{
			"10.0.0.1": {},
			"10.0.0.2": {},
			"10.0.0.3": {},
		},
	}

	before := collectPrimaryIPSet(gen.allDevices)
	swapped := swapDevicePrimaryIPs(gen, 5, false)
	require.Positive(t, swapped)

	after := collectPrimaryIPSet(gen.allDevices)
	require.Equal(t, before, after, "IP shuffle must not create or drop IPs")
}

func TestReassignIPsFromPoolPreservesUniqueness(t *testing.T) {
	gen := &DeviceGenerator{
		allDevices: []ArmisDevice{
			{ID: 1, IPAddress: "10.0.0.1"},
			{ID: 2, IPAddress: "10.0.0.2"},
		},
		usedIPs: map[string]struct{}{
			"10.0.0.1": {},
			"10.0.0.2": {},
		},
		freeIPs: []string{"10.0.0.3", "10.0.0.4"},
	}

	before := collectPrimaryIPSet(gen.allDevices)
	changed := reassignIPsFromPool(gen, 2, false)
	require.Positive(t, changed)

	after := collectPrimaryIPSet(gen.allDevices)
	require.Len(t, after, len(before))
	for ip := range after {
		if _, ok := before[ip]; ok {
			continue
		}
		require.Contains(t, gen.usedIPs, ip)
	}
}

func collectPrimaryIPSet(devices []ArmisDevice) map[string]struct{} {
	out := make(map[string]struct{}, len(devices))
	for _, d := range devices {
		ip := primaryIP(d.IPAddress)
		if ip == "" {
			continue
		}
		out[ip] = struct{}{}
	}
	return out
}
