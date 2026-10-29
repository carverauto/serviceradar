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

package sysmon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/hostinventory"
	gopsutilnet "github.com/shirou/gopsutil/v3/net"
)

func TestDefaultConfig(t *testing.T) {
	cfg := DefaultConfig()

	if !cfg.Enabled {
		t.Error("expected Enabled to be true")
	}

	if cfg.SampleInterval != "10s" {
		t.Errorf("expected SampleInterval to be '10s', got %q", cfg.SampleInterval)
	}

	if !cfg.CollectCPU {
		t.Error("expected CollectCPU to be true")
	}

	if !cfg.CollectMemory {
		t.Error("expected CollectMemory to be true")
	}

	if !cfg.CollectDisk {
		t.Error("expected CollectDisk to be true")
	}

	if cfg.CollectNetwork {
		t.Error("expected CollectNetwork to be false by default")
	}

	if cfg.CollectProcesses {
		t.Error("expected CollectProcesses to be false by default")
	}

	if cfg.ProcessLimit != DefaultProcessLimit {
		t.Errorf("expected ProcessLimit to be %d by default, got %d", DefaultProcessLimit, cfg.ProcessLimit)
	}

	if len(cfg.DiskPaths) != 0 {
		t.Errorf("expected DiskPaths to be empty by default, got %v", cfg.DiskPaths)
	}

	if len(cfg.DiskExcludePaths) != 0 {
		t.Errorf("expected DiskExcludePaths to be empty by default, got %v", cfg.DiskExcludePaths)
	}
}

func TestConfigParse(t *testing.T) {
	tests := []struct {
		name           string
		config         Config
		expectErr      bool
		expectInterval time.Duration
	}{
		{
			name:           "default interval",
			config:         Config{Enabled: true},
			expectInterval: DefaultSampleInterval,
		},
		{
			name:           "custom interval",
			config:         Config{Enabled: true, SampleInterval: "5s"},
			expectInterval: 5 * time.Second,
		},
		{
			name:           "minimum interval clamp",
			config:         Config{Enabled: true, SampleInterval: "10ms"},
			expectInterval: MinSampleInterval,
		},
		{
			name:           "maximum interval clamp",
			config:         Config{Enabled: true, SampleInterval: "10m"},
			expectInterval: MaxSampleInterval,
		},
		{
			name:      "invalid interval",
			config:    Config{Enabled: true, SampleInterval: "invalid"},
			expectErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parsed, err := tt.config.Parse()

			if tt.expectErr {
				if err == nil {
					t.Error("expected error, got nil")
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if parsed.SampleInterval != tt.expectInterval {
				t.Errorf("expected interval %v, got %v", tt.expectInterval, parsed.SampleInterval)
			}

			if parsed.ProcessLimit != 0 {
				t.Errorf("expected unlimited process limit, got %d", parsed.ProcessLimit)
			}
		})
	}
}

func TestConfigParseCustomProcessLimit(t *testing.T) {
	cfg := Config{Enabled: true, ProcessLimit: 25}

	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if parsed.ProcessLimit != 25 {
		t.Errorf("expected process limit 25, got %d", parsed.ProcessLimit)
	}
}

func TestConfigParseNegativeProcessLimitUsesDefault(t *testing.T) {
	cfg := Config{Enabled: true, ProcessLimit: -1}

	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if parsed.ProcessLimit != DefaultProcessLimit {
		t.Errorf("expected default process limit %d, got %d", DefaultProcessLimit, parsed.ProcessLimit)
	}
}

func TestCollectMemory(t *testing.T) {
	ctx := context.Background()

	mem, err := CollectMemory(ctx)
	if err != nil {
		t.Fatalf("CollectMemory failed: %v", err)
	}

	if mem.TotalBytes == 0 {
		t.Error("expected TotalBytes > 0")
	}

	if mem.UsedBytes == 0 {
		t.Error("expected UsedBytes > 0")
	}

	if mem.UsedBytes > mem.TotalBytes {
		t.Errorf("UsedBytes (%d) should not exceed TotalBytes (%d)", mem.UsedBytes, mem.TotalBytes)
	}
}

func TestCollectDisks(t *testing.T) {
	ctx := context.Background()

	// Test with root path - in containers this may be overlay filesystem
	disks, err := CollectDisks(ctx, []string{"/"}, nil)
	if err != nil {
		t.Fatalf("CollectDisks failed: %v", err)
	}

	// If no disks found with specific path, try collecting all disks
	// This handles CI environments where "/" may not be directly accessible
	if len(disks) == 0 {
		disks, err = CollectDisks(ctx, nil, nil)
		if err != nil {
			t.Fatalf("CollectDisks (all) failed: %v", err)
		}
	}

	if len(disks) == 0 {
		t.Skip("no accessible disk metrics found - may be running in a minimal container")
	}

	for _, disk := range disks {
		if disk.MountPoint == "" {
			t.Error("expected non-empty MountPoint")
		}
		if disk.TotalBytes == 0 {
			t.Errorf("expected TotalBytes > 0 for %s", disk.MountPoint)
		}
	}
}

func TestCollectDisksExcludePaths(t *testing.T) {
	ctx := context.Background()

	disks, err := CollectDisks(ctx, []string{"/"}, []string{"/"})
	if err != nil {
		t.Fatalf("CollectDisks failed: %v", err)
	}

	for _, disk := range disks {
		if disk.MountPoint == "/" {
			t.Errorf("expected excluded mount point to be omitted: %s", disk.MountPoint)
		}
	}
}

func TestIsMountpointDir(t *testing.T) {
	dir := t.TempDir()
	if !isMountpointDir(dir) {
		t.Errorf("expected temp dir to be recognized as directory: %s", dir)
	}

	filePath := filepath.Join(dir, "mountpoint.txt")
	if err := os.WriteFile(filePath, []byte("data"), 0o644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	if isMountpointDir(filePath) {
		t.Errorf("expected file path to be treated as non-directory: %s", filePath)
	}
}

func TestCollectNetwork(t *testing.T) {
	ctx := context.Background()

	network, err := CollectNetwork(ctx)
	if err != nil {
		t.Fatalf("CollectNetwork failed: %v", err)
	}

	// Should have at least one non-loopback interface on most systems
	// but this may vary, so we just check it doesn't error
	t.Logf("found %d network interfaces", len(network))
}

func TestFilterNetworkCountersUsesHostInventory(t *testing.T) {
	inventory := []hostinventory.Interface{
		{Interface: net.Interface{Name: "lo", Flags: net.FlagLoopback}, Kind: hostinventory.KindLoopback},
		{Interface: net.Interface{Name: "eno1"}, Kind: hostinventory.KindPhysical},
		{Interface: net.Interface{Name: "bond0"}, Kind: hostinventory.KindBond},
		{Interface: net.Interface{Name: "eno1.20"}, Kind: hostinventory.KindVLAN},
		{Interface: net.Interface{Name: "vmbr0"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "br0"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "docker0"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "br-0123456789ab"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "virbr0"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "cni0"}, Kind: hostinventory.KindBridge},
		{Interface: net.Interface{Name: "veth1a2b"}, Kind: hostinventory.KindVirtual},
		{Interface: net.Interface{Name: "tap100i0"}, Kind: hostinventory.KindVirtual},
		{Interface: net.Interface{Name: "wg0"}, Kind: hostinventory.KindTunnel},
	}

	counters := []gopsutilnet.IOCountersStat{
		{Name: "lo", BytesRecv: 10},
		{Name: "eno1", BytesRecv: 100, BytesSent: 200},
		{Name: "bond0", BytesRecv: 300, BytesSent: 400},
		{Name: "eno1.20", BytesRecv: 500, BytesSent: 600},
		{Name: "vmbr0", BytesRecv: 700, BytesSent: 800},
		{Name: "br0", BytesRecv: 900, BytesSent: 1000},
		{Name: "docker0", BytesRecv: 11},
		{Name: "br-0123456789ab", BytesRecv: 12},
		{Name: "virbr0", BytesRecv: 13},
		{Name: "cni0", BytesRecv: 14},
		{Name: "veth1a2b", BytesRecv: 15},
		{Name: "tap100i0", BytesRecv: 16},
		{Name: "wg0", BytesRecv: 17},
		{Name: "vnet0", BytesRecv: 18},
		{Name: "tun0", BytesRecv: 19},
		{Name: "bridge0", BytesRecv: 20},
		{Name: "en0", BytesRecv: 1100, BytesSent: 1200},
	}

	metrics := filterNetworkCounters(counters, inventory, func(name string) hostinventory.Interface {
		return hostinventory.Interface{Interface: net.Interface{Name: name}, Kind: hostinventory.KindUnspecified}
	})

	got := make([]string, 0, len(metrics))
	for _, m := range metrics {
		got = append(got, m.Interface)
	}
	want := []string{"eno1", "bond0", "eno1.20", "vmbr0", "br0", "wg0", "en0"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filterNetworkCounters interfaces = %v, want %v", got, want)
	}
}

func TestFirstUsableIPv4FromInventoryUsesHostInventory(t *testing.T) {
	cidr := func(text string) net.Addr {
		ip, ipNet, err := net.ParseCIDR(text)
		if err != nil {
			t.Fatal(err)
		}
		ipNet.IP = ip
		return ipNet
	}

	ifaces := []hostinventory.Interface{
		{
			Interface: net.Interface{Name: "lo", Flags: net.FlagUp | net.FlagLoopback},
			Kind:      hostinventory.KindLoopback,
			Addrs:     []net.Addr{cidr("127.0.0.1/8")},
		},
		{
			Interface: net.Interface{Name: "docker0", Flags: net.FlagUp},
			Kind:      hostinventory.KindBridge,
			Addrs:     []net.Addr{cidr("198.51.100.10/24")},
		},
		{
			Interface: net.Interface{Name: "veth1a2b", Flags: net.FlagUp},
			Kind:      hostinventory.KindVirtual,
			Addrs:     []net.Addr{cidr("198.51.100.11/24")},
		},
		{
			Interface: net.Interface{Name: "wg0", Flags: net.FlagUp},
			Kind:      hostinventory.KindTunnel,
			Addrs:     []net.Addr{cidr("198.51.100.12/24")},
		},
		{
			Interface: net.Interface{Name: "eno1", Flags: net.FlagUp},
			Kind:      hostinventory.KindPhysical,
			Addrs:     []net.Addr{cidr("172.17.0.1/16")},
		},
		{
			Interface: net.Interface{Name: "vmbr0", Flags: net.FlagUp},
			Kind:      hostinventory.KindBridge,
			Addrs:     []net.Addr{cidr("192.0.2.25/24")},
		},
	}

	if got := firstUsableIPv4FromInventory(ifaces); got != "192.0.2.25" {
		t.Fatalf("firstUsableIPv4FromInventory() = %q, want 192.0.2.25", got)
	}
}

func TestNewCollector(t *testing.T) {
	cfg := DefaultConfig()
	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("failed to parse config: %v", err)
	}

	collector, err := NewCollector(parsed, WithAgentID("test-agent"))
	if err != nil {
		t.Fatalf("failed to create collector: %v", err)
	}

	if collector == nil {
		t.Fatal("expected non-nil collector")
	}
}

func TestCollectorCollect(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping test in short mode - requires CPU sampling")
	}

	cfg := DefaultConfig()
	cfg.SampleInterval = "100ms" // Fast for testing
	cfg.CollectProcesses = true
	cfg.CollectNetwork = true

	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("failed to parse config: %v", err)
	}

	collector, err := NewCollector(parsed, WithAgentID("test-agent"))
	if err != nil {
		t.Fatalf("failed to create collector: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	sample, err := collector.Collect(ctx)
	if err != nil {
		t.Fatalf("Collect failed: %v", err)
	}

	if sample == nil {
		t.Fatal("expected non-nil sample")
		return
	}

	if sample.Timestamp == "" {
		t.Error("expected non-empty Timestamp")
	}

	if sample.HostID == "" {
		t.Error("expected non-empty HostID")
	}

	if len(sample.CPUs) == 0 {
		t.Error("expected at least one CPU metric")
	}

	if sample.Memory.TotalBytes == 0 {
		t.Error("expected non-zero memory total")
	}

	// Verify JSON serialization works
	data, err := json.Marshal(sample)
	if err != nil {
		t.Fatalf("failed to marshal sample: %v", err)
	}

	t.Logf("sample JSON: %s", string(data))
}

func TestCollectorStartStop(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping test in short mode - requires CPU sampling")
	}

	cfg := DefaultConfig()
	cfg.SampleInterval = "100ms" // Fast for testing

	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("failed to parse config: %v", err)
	}

	collector, err := NewCollector(parsed)
	if err != nil {
		t.Fatalf("failed to create collector: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start the collector
	if err := collector.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	// Wait for at least one collection cycle (CPU sampling takes ~100ms)
	time.Sleep(500 * time.Millisecond)

	// Check we have a latest sample
	latest := collector.Latest()
	if latest == nil {
		t.Log("Latest() returned nil, waiting a bit longer...")
		time.Sleep(500 * time.Millisecond)
		latest = collector.Latest()
	}
	if latest == nil {
		t.Error("expected non-nil Latest() after start")
	}

	// Stop the collector
	if err := collector.Stop(); err != nil {
		t.Fatalf("Stop failed: %v", err)
	}

	// Verify it's stopped (Start should be idempotent)
	if err := collector.Stop(); err != nil {
		t.Fatalf("second Stop failed: %v", err)
	}
}

func TestMetricSampleJSONCompatibility(t *testing.T) {
	// Verify our JSON output matches the expected format from Rust sysmon
	sample := &MetricSample{
		Timestamp: "2025-01-13T12:00:00.000000000Z",
		HostID:    "test-host",
		HostIP:    "192.168.1.100",
		AgentID:   "test-agent",
		CPUs: []CPUMetric{
			{CoreID: 0, Label: "CPU0", UsagePercent: 25.5, FrequencyHz: 2400000000},
			{CoreID: 1, Label: "CPU1", UsagePercent: 30.2, FrequencyHz: 2400000000},
		},
		Disks: []DiskMetric{
			{MountPoint: "/", UsedBytes: 10737418240, TotalBytes: 107374182400},
		},
		Memory: MemoryMetric{
			UsedBytes:  4294967296,
			TotalBytes: 17179869184,
		},
		Processes: []ProcessMetric{
			{PID: 1234, Name: "nginx", CPUUsage: 2.5, MemoryUsage: 104857600, Status: "Running", StartTime: "2025-01-13T10:00:00Z"},
		},
	}

	data, err := json.MarshalIndent(sample, "", "  ")
	if err != nil {
		t.Fatalf("failed to marshal sample: %v", err)
	}

	// Verify we can unmarshal it back
	var parsed MetricSample
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("failed to unmarshal sample: %v", err)
	}

	if parsed.HostID != sample.HostID {
		t.Errorf("HostID mismatch: got %q, want %q", parsed.HostID, sample.HostID)
	}

	if len(parsed.CPUs) != len(sample.CPUs) {
		t.Errorf("CPU count mismatch: got %d, want %d", len(parsed.CPUs), len(sample.CPUs))
	}

	t.Logf("JSON output:\n%s", string(data))
}

func TestInjectSpike(t *testing.T) {
	cfg := DefaultConfig()
	parsed, err := cfg.Parse()
	if err != nil {
		t.Fatalf("parse config: %v", err)
	}
	collector, err := NewCollector(parsed, WithAgentID("test-agent"))
	if err != nil {
		t.Fatalf("new collector: %v", err)
	}

	// CPU spike: 4 consecutive samples at 95%.
	n, err := collector.InjectSpike("cpu", 95.0, 4)
	if err != nil {
		t.Fatalf("inject cpu: %v", err)
	}
	if n != 4 {
		t.Fatalf("wrote %d cpu samples, want 4", n)
	}
	cpuSamples := collector.Drain()
	if len(cpuSamples) != 4 {
		t.Fatalf("drained %d cpu samples, want 4", len(cpuSamples))
	}
	for _, s := range cpuSamples {
		if len(s.CPUs) == 0 || s.CPUs[0].UsagePercent != 95.0 {
			t.Fatalf("cpu sample not spiked: %+v", s.CPUs)
		}
	}

	// Memory spike: used/total ~= 90%.
	if _, err := collector.InjectSpike("memory", 90.0, 2); err != nil {
		t.Fatalf("inject memory: %v", err)
	}
	memSamples := collector.Drain()
	if len(memSamples) != 2 {
		t.Fatalf("drained %d mem samples, want 2", len(memSamples))
	}
	for _, s := range memSamples {
		if s.Memory.TotalBytes == 0 {
			t.Fatalf("memory total not set: %+v", s.Memory)
		}
		ratio := float64(s.Memory.UsedBytes) / float64(s.Memory.TotalBytes) * 100.0
		if ratio < 89.9 || ratio > 90.1 {
			t.Fatalf("memory used ratio = %.2f, want ~90", ratio)
		}
	}

	// Default count (0 -> 6) and an unsupported metric.
	if n, err := collector.InjectSpike("cpu", 80.0, 0); err != nil || n != 6 {
		t.Fatalf("default count = %d, err=%v; want 6, nil", n, err)
	}
	_ = collector.Drain()
	if _, err := collector.InjectSpike("disk", 99.0, 1); err == nil {
		t.Fatal("expected error for unsupported spike metric")
	}
}
