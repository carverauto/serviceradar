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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/stretchr/testify/require"
)

var (
	errConfigNotEnabled  = errors.New("config not enabled")
	errConfigSourceEmpty = errors.New("config source empty")
)

// BenchmarkConfigHash benchmarks the config hash computation.
func BenchmarkConfigHash(b *testing.B) {
	cfg := sysmon.DefaultConfig()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = computeConfigHash(cfg)
	}
}

// BenchmarkConfigParse benchmarks parsing sysmon config.
func BenchmarkConfigParse(b *testing.B) {
	cfg := sysmon.Config{
		Enabled:          true,
		SampleInterval:   "10s",
		CollectCPU:       true,
		CollectMemory:    true,
		CollectDisk:      true,
		CollectNetwork:   true,
		CollectProcesses: true,
		DiskPaths:        []string{"/", "/var", "/home", "/data"},
		Thresholds: map[string]string{
			"cpu_warning":     "75",
			"cpu_critical":    "90",
			"memory_warning":  "80",
			"memory_critical": "95",
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := cfg.Parse()
		if err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkConfigLoadFromFile benchmarks loading config from file.
func BenchmarkConfigLoadFromFile(b *testing.B) {
	// Create a temporary config file
	tmpDir := b.TempDir()
	configPath := tmpDir + "/sysmon.json"

	cfg := sysmon.Config{
		Enabled:          true,
		SampleInterval:   "10s",
		CollectCPU:       true,
		CollectMemory:    true,
		CollectDisk:      true,
		CollectNetwork:   false,
		CollectProcesses: false,
		DiskPaths:        []string{"/"},
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		b.Fatal(err)
	}

	if err := os.WriteFile(configPath, data, 0644); err != nil {
		b.Fatal(err)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := sysmon.LoadConfigFromFile(configPath)
		if err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkSysmonServiceStart benchmarks starting the sysmon service.
func BenchmarkSysmonServiceStart(b *testing.B) {
	tmpDir := b.TempDir()
	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a config file
	configPath := tmpDir + "/sysmon.json"
	configData := `{
		"enabled": true,
		"sample_interval": "60s",
		"collect_cpu": true,
		"collect_memory": true,
		"collect_disk": false,
		"collect_network": false,
		"collect_processes": false
	}`
	if err := os.WriteFile(configPath, []byte(configData), 0644); err != nil {
		b.Fatal(err)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		svc, err := NewSysmonService(SysmonServiceConfig{
			AgentID:   fmt.Sprintf("bench-agent-%d", i),
			ConfigDir: tmpDir,
			Logger:    log,
		})
		if err != nil {
			b.Fatal(err)
		}

		if err := svc.Start(ctx); err != nil {
			b.Fatal(err)
		}

		if err := svc.Stop(ctx); err != nil {
			b.Fatal(err)
		}
	}
}

// TestConcurrentConfigLoad tests concurrent config loading with many agents.
// This simulates various agent counts (1K, 5K, 10K) fetching config simultaneously.
// Designed to validate performance for deployments that could scale to 100K+ agents.
func TestConcurrentConfigLoad(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping concurrent config load test in short mode")
	}

	tests := []struct {
		name      string
		numAgents int
		maxAvgMs  int64 // max acceptable average latency in milliseconds
		maxMaxMs  int64 // max acceptable max latency in milliseconds
	}{
		{name: "1K_agents", numAgents: 1000, maxAvgMs: 120, maxMaxMs: 500},
		{name: "5K_agents", numAgents: 5000, maxAvgMs: 180, maxMaxMs: 1000},
		{name: "10K_agents", numAgents: 10000, maxAvgMs: 240, maxMaxMs: 2000},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			runConcurrentConfigLoadTest(t, tc.numAgents, tc.maxAvgMs, tc.maxMaxMs)
		})
	}
}

// runConcurrentConfigLoadTest runs a concurrent config load test with the specified agent count.
func runConcurrentConfigLoadTest(t *testing.T, numAgents int, maxAvgMs, maxMaxMs int64) {
	t.Helper()

	tmpDir := t.TempDir()
	log := logger.NewTestLogger()

	// Create a config file
	configPath := tmpDir + "/sysmon.json"
	configData := `{
		"enabled": true,
		"sample_interval": "10s",
		"collect_cpu": true,
		"collect_memory": true,
		"collect_disk": true,
		"collect_network": false,
		"collect_processes": false
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	// Track timing
	var wg sync.WaitGroup
	latencies := make([]time.Duration, numAgents)
	errors := make([]error, numAgents)

	startTime := time.Now()

	// Simulate agents loading config concurrently
	for i := 0; i < numAgents; i++ {
		wg.Add(1)
		go func(agentIdx int) {
			defer wg.Done()

			agentStart := time.Now()

			svc, err := NewSysmonService(SysmonServiceConfig{
				AgentID:   fmt.Sprintf("agent-%d", agentIdx),
				ConfigDir: tmpDir,
				Logger:    log,
			})
			if err != nil {
				errors[agentIdx] = err
				return
			}

			// Load config (this is what we're measuring)
			ctx := context.Background()
			cfg, source, err := svc.loadConfig(ctx)
			if err != nil {
				errors[agentIdx] = err
				return
			}

			// Verify config was loaded correctly
			if !cfg.Enabled {
				errors[agentIdx] = errConfigNotEnabled
				return
			}
			if source == "" {
				errors[agentIdx] = errConfigSourceEmpty
				return
			}

			latencies[agentIdx] = time.Since(agentStart)
		}(i)
	}

	wg.Wait()
	totalDuration := time.Since(startTime)

	// Check for errors
	errorCount := 0
	for _, err := range errors {
		if err != nil {
			errorCount++
			if errorCount <= 10 { // Only log first 10 errors
				t.Logf("Error: %v", err)
			}
		}
	}

	// Calculate statistics
	var totalLatency time.Duration
	var minLatency = time.Hour
	var maxLatency time.Duration

	for _, lat := range latencies {
		if lat > 0 {
			totalLatency += lat
			if lat < minLatency {
				minLatency = lat
			}
			if lat > maxLatency {
				maxLatency = lat
			}
		}
	}

	successCount := numAgents - errorCount
	var avgLatency time.Duration
	if successCount > 0 {
		avgLatency = totalLatency / time.Duration(successCount)
	}

	t.Logf("=== Config Fetch Performance Test (Task 5.5) ===")
	t.Logf("Number of agents: %d", numAgents)
	t.Logf("Errors: %d (%.2f%%)", errorCount, float64(errorCount)/float64(numAgents)*100)
	t.Logf("Total time: %v", totalDuration)
	t.Logf("Min latency: %v", minLatency)
	t.Logf("Max latency: %v", maxLatency)
	t.Logf("Avg latency: %v", avgLatency)
	t.Logf("Throughput: %.2f configs/sec", float64(numAgents)/totalDuration.Seconds())

	// Assert reasonable performance
	require.Zero(t, errorCount, "should have no errors")
	require.Less(t, avgLatency, time.Duration(maxAvgMs)*time.Millisecond,
		"average latency should be under %dms", maxAvgMs)
	require.Less(t, maxLatency, time.Duration(maxMaxMs)*time.Millisecond,
		"max latency should be under %dms", maxMaxMs)
}

// BenchmarkConcurrentConfigLoad benchmarks concurrent config loading.
func BenchmarkConcurrentConfigLoad(b *testing.B) {
	tmpDir := b.TempDir()
	log := logger.NewTestLogger()

	// Create a config file
	configPath := tmpDir + "/sysmon.json"
	configData := `{
		"enabled": true,
		"sample_interval": "10s",
		"collect_cpu": true,
		"collect_memory": true,
		"collect_disk": true,
		"collect_network": false,
		"collect_processes": false
	}`
	if err := os.WriteFile(configPath, []byte(configData), 0644); err != nil {
		b.Fatal(err)
	}

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		agentID := 0
		for pb.Next() {
			svc, err := NewSysmonService(SysmonServiceConfig{
				AgentID:   fmt.Sprintf("agent-%d", agentID),
				ConfigDir: tmpDir,
				Logger:    log,
			})
			if err != nil {
				b.Fatal(err)
			}

			ctx := context.Background()
			_, _, err = svc.loadConfig(ctx)
			if err != nil {
				b.Fatal(err)
			}
			agentID++
		}
	})
}
