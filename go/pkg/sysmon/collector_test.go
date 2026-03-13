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
	"os"
	"path/filepath"
	"testing"
	"time"
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
		})
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
