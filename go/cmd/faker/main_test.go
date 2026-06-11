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
			{ID: 4, IPAddress: "10.0.0.4"},
			{ID: 5, IPAddress: "10.0.0.5"},
			{ID: 6, IPAddress: "10.0.0.6"},
			{ID: 7, IPAddress: "10.0.0.7"},
			{ID: 8, IPAddress: "10.0.0.8"},
			{ID: 9, IPAddress: "10.0.0.9"},
			{ID: 10, IPAddress: "10.0.0.10"},
		},
		usedIPs: map[string]struct{}{
			"10.0.0.1":  {},
			"10.0.0.2":  {},
			"10.0.0.3":  {},
			"10.0.0.4":  {},
			"10.0.0.5":  {},
			"10.0.0.6":  {},
			"10.0.0.7":  {},
			"10.0.0.8":  {},
			"10.0.0.9":  {},
			"10.0.0.10": {},
		},
	}

	before := collectPrimaryIPSet(gen.allDevices)
	swapped := swapDevicePrimaryIPs(gen, 20, false)
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

func TestGenerateMACCountIsDeterministic(t *testing.T) {
	// Sample one index from each distribution bucket plus boundaries.
	for _, idx := range []int{0, 7, 59, 60, 84, 85, 94, 95, 98, 99, 49999} {
		first := generateMACCount(idx)
		second := generateMACCount(idx)
		require.Equal(t, first, second,
			"MAC count must be stable across invocations (device index %d)", idx)
	}
}

func TestGenerateMACAddressesIsDeterministic(t *testing.T) {
	for _, seed := range []int{0, 1, 42, 1337, 49999} {
		count := generateMACCount(seed)

		first := generateMACAddresses(seed, count)
		second := generateMACAddresses(seed, count)

		require.Len(t, first, count)
		require.Equal(t, first, second,
			"same seed+count must produce identical MAC lists across invocations (seed %d)", seed)
	}
}

func TestGenerateMACAddressesDiffersAcrossSeeds(t *testing.T) {
	const count = 10

	require.NotEqual(t, generateMACAddresses(1, count), generateMACAddresses(2, count),
		"different seeds must produce different MAC lists")
}

func TestSaveLoadRoundTripPreservesMacAddresses(t *testing.T) {
	originalTotal := totalDevices
	originalConfig := config
	originalGen := deviceGen
	t.Cleanup(func() {
		totalDevices = originalTotal
		config = originalConfig
		deviceGen = originalGen
	})

	totalDevices = 25
	config = &Config{}
	config.Storage.DataDir = t.TempDir()
	config.Storage.DevicesFile = "fake_armis_devices.json"
	config.Storage.PersistChanges = true

	gen := NewDeviceGenerator()
	deviceGen = gen
	gen.allDevices = gen.generateAllDevices()
	require.Len(t, gen.allDevices, totalDevices)
	gen.saveToStorage()

	reloaded := NewDeviceGenerator()
	require.True(t, reloaded.loadFromStorage(), "expected persisted devices to load")
	require.Len(t, reloaded.allDevices, totalDevices)

	for i, original := range gen.allDevices {
		got := reloaded.allDevices[i]
		require.Equal(t, original.MacAddress, got.MacAddress, "device %d MacAddress mismatch", i)
		require.NotEmpty(t, got.MacAddresses, "device %d MacAddresses must be rehydrated on load", i)
		require.Equal(t, original.MacAddresses, got.MacAddresses,
			"device %d MAC set must survive the save/load round trip", i)
	}
}
