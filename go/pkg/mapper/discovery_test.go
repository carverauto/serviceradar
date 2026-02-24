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

package mapper

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestNewDiscoveryEngine(t *testing.T) {
	tests := []struct {
		name        string
		config      *Config
		expectError bool
	}{
		{
			name:        "nil config",
			config:      nil,
			expectError: true,
		},
		{
			name: "invalid workers",
			config: &Config{
				Workers:       0,
				MaxActiveJobs: 1,
			},
			expectError: true,
		},
		{
			name: "invalid max active jobs",
			config: &Config{
				Workers:       1,
				MaxActiveJobs: 0,
			},
			expectError: true,
		},
		{
			name: "valid config",
			config: &Config{
				Workers:         2,
				MaxActiveJobs:   5,
				Timeout:         30 * time.Second,
				ResultRetention: 24 * time.Hour,
			},
			expectError: false,
		},
		{
			name: "default timeout",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
			},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockPublisher := new(MockPublisher)
			mockLogger := logger.NewTestLogger()
			engine, err := NewDiscoveryEngine(tt.config, mockPublisher, mockLogger)

			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, engine)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, engine)

				// Verify default values are set when needed
				if tt.config != nil && tt.config.Timeout <= 0 {
					assert.Equal(t, defaultTimeout, tt.config.Timeout)
				}

				if tt.config != nil && tt.config.ResultRetention <= 0 {
					assert.Equal(t, defaultResultRetention, tt.config.ResultRetention)
				}
			}
		})
	}
}

func TestStartDiscovery(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with empty seeds
	ctx := context.Background()
	params := &DiscoveryParams{
		Seeds: []string{},
		Type:  DiscoveryTypeBasic,
	}
	_, err = engine.StartDiscovery(ctx, params)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no seeds provided")

	// Test with valid params
	params.Seeds = []string{"192.168.1.1"}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Verify job was created and enqueued
	discoveryEngine := engine.(*DiscoveryEngine)
	assert.Contains(t, discoveryEngine.activeJobs, discoveryID)
}

func TestGetDiscoveryStatus(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	status, err := engine.GetDiscoveryStatus(ctx, "non-existent-id")
	require.Error(t, err)
	assert.Nil(t, status)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Get status of the job
	status, err = engine.GetDiscoveryStatus(ctx, discoveryID)
	require.NoError(t, err)
	assert.NotNil(t, status)
	assert.Equal(t, DiscoveryStatusPending, status.Status)
}

func TestGetDiscoveryResults(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	results, err := engine.GetDiscoveryResults(ctx, "non-existent-id", false)
	require.Error(t, err)
	assert.Nil(t, results)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}

	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Move job to completed jobs for testing
	discoveryEngine := engine.(*DiscoveryEngine)
	job := discoveryEngine.activeJobs[discoveryID]
	job.Status.Status = DiscoveryStatusCompleted
	discoveryEngine.completedJobs[discoveryID] = job.Results
	delete(discoveryEngine.activeJobs, discoveryID)

	// Get results of the job
	results, err = engine.GetDiscoveryResults(ctx, discoveryID, false)
	require.NoError(t, err)
	assert.NotNil(t, results)
	assert.Equal(t, DiscoveryStatusCompleted, results.Status.Status)
}

func TestCancelDiscovery(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	// Test with non-existent discovery ID
	ctx := context.Background()
	err = engine.CancelDiscovery(ctx, "non-existent-id")
	require.Error(t, err)

	// Start a discovery job
	params := &DiscoveryParams{
		Seeds: []string{"192.168.1.1"},
		Type:  DiscoveryTypeBasic,
	}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)
	assert.NotEmpty(t, discoveryID)

	// Cancel the job
	err = engine.CancelDiscovery(ctx, discoveryID)
	require.NoError(t, err)

	// Verify job was canceled
	discoveryEngine := engine.(*DiscoveryEngine)
	_, exists := discoveryEngine.activeJobs[discoveryID]
	assert.False(t, exists)

	// Verify job status was updated
	results, err := engine.GetDiscoveryResults(ctx, discoveryID, false)
	require.NoError(t, err)
	assert.Equal(t, DiscoverStatusCanceled, results.Status.Status)
}

func TestValidateConfig(t *testing.T) {
	tests := []struct {
		name        string
		config      *Config
		expectError bool
	}{
		{
			name:        "nil config",
			config:      nil,
			expectError: true,
		},
		{
			name: "invalid workers",
			config: &Config{
				Workers:       0,
				MaxActiveJobs: 1,
			},
			expectError: true,
		},
		{
			name: "invalid max active jobs",
			config: &Config{
				Workers:       1,
				MaxActiveJobs: 0,
			},
			expectError: true,
		},
		{
			name: "valid config",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
				Timeout:       30 * time.Second,
			},
			expectError: false,
		},
		{
			name: "invalid scheduled job",
			config: &Config{
				Workers:       2,
				MaxActiveJobs: 5,
				ScheduledJobs: []*ScheduledJob{
					{
						Name:    "",
						Enabled: true,
					},
				},
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateConfig(tt.config)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestValidateScheduledJob(t *testing.T) {
	tests := []struct {
		name        string
		job         *ScheduledJob
		expectError bool
	}{
		{
			name: "missing name",
			job: &ScheduledJob{
				Name:    "",
				Enabled: true,
			},
			expectError: true,
		},
		{
			name: "disabled job",
			job: &ScheduledJob{
				Name:    "test",
				Enabled: false,
			},
			expectError: false,
		},
		{
			name: "invalid interval",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "invalid",
			},
			expectError: true,
		},
		{
			name: "no seeds",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{},
			},
			expectError: true,
		},
		{
			name: "invalid type",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{"192.168.1.1"},
				Type:     "invalid",
			},
			expectError: true,
		},
		{
			name: "valid job",
			job: &ScheduledJob{
				Name:     "test",
				Enabled:  true,
				Interval: "1h",
				Seeds:    []string{"192.168.1.1"},
				Type:     "basic",
			},
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateScheduledJob(tt.job)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestInitializeDevice(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Test initializing a device
	target := "192.168.1.1"
	device := discoveryEngine.initializeDevice(target)

	assert.NotNil(t, device)
	assert.Equal(t, target, device.IP)
	assert.Empty(t, device.DeviceID)  // DeviceID should be empty initially
	assert.Empty(t, device.Hostname)  // Hostname should be empty initially
	assert.NotNil(t, device.Metadata) // Metadata should be initialized
}

func TestDetermineConcurrency(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Create a job with no concurrency specified
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Concurrency: 0,
		},
	}

	// Test with small target list
	concurrency := discoveryEngine.determineConcurrency(job, 5)
	assert.Equal(t, 5, concurrency) // Should match target count

	// Test with large target list
	concurrency = discoveryEngine.determineConcurrency(job, 100)
	assert.Equal(t, discoveryEngine.workers, concurrency) // Should match worker count

	// Test with specified concurrency
	job.Params.Concurrency = 10
	concurrency = discoveryEngine.determineConcurrency(job, 100)
	assert.Equal(t, 10, concurrency) // Should match specified concurrency
}

func TestEnsureDeviceID(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Test with empty DeviceID
	device := &DiscoveredDevice{
		IP: "192.168.1.1",
	}
	discoveryEngine.ensureDeviceID(device)
	assert.NotEmpty(t, device.DeviceID)

	// Test with existing DeviceID
	device = &DiscoveredDevice{
		IP:       "192.168.1.1",
		DeviceID: "existing-id",
	}
	discoveryEngine.ensureDeviceID(device)
	assert.Equal(t, "existing-id", device.DeviceID) // DeviceID should not change
}

func TestAddOrUpdateDeviceToResultsCanonicalizesSameIPIdentity(t *testing.T) {
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	existing := &DiscoveredDevice{
		DeviceID: "mac-f492bf75c721",
		IP:       "152.117.116.178",
		MAC:      "f4:92:bf:75:c7:21",
		Hostname: "farm01",
		Metadata: map[string]string{"source": "unifi-api"},
	}

	job := &DiscoveryJob{
		ID:      "job-1",
		Results: &DiscoveryResults{Devices: []*DiscoveredDevice{existing}},
		deviceMap: map[string]*DeviceInterfaceMap{
			existing.DeviceID: {
				DeviceID: existing.DeviceID,
				IPs:      map[string]struct{}{existing.IP: {}},
				MACs:     map[string]struct{}{existing.MAC: {}},
			},
		},
	}

	incomingSNMP := &DiscoveredDevice{
		DeviceID: "mac-f692bf75c721",
		IP:       "152.117.116.178",
		MAC:      "f6:92:bf:75:c7:21",
		Hostname: "farm01",
		Metadata: map[string]string{"source": "snmp"},
	}

	engine.addOrUpdateDeviceToResults(job, incomingSNMP)

	require.Len(t, job.Results.Devices, 1)
	assert.Equal(t, "mac-f492bf75c721", job.Results.Devices[0].DeviceID)
	assert.Equal(t, "f4:92:bf:75:c7:21", job.Results.Devices[0].MAC)
	assert.Equal(t, "1", job.Results.Devices[0].Metadata["alt_mac:f692bf75c721"])
}

func TestHandleEmptyTargetList(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)
	assert.NotNil(t, engine)

	discoveryEngine := engine.(*DiscoveryEngine)

	// Create a job
	job := &DiscoveryJob{
		Status: &DiscoveryStatus{
			Status: DiscoveryStatusPending,
		},
	}

	// Handle empty target list
	discoveryEngine.handleEmptyTargetList(job)

	// Verify job status was updated
	assert.Equal(t, DiscoveryStatusFailed, job.Status.Status)
	assert.Contains(t, job.Status.Error, "No valid targets")
}

func TestGenerateDiscoveryID(t *testing.T) {
	// Test that generated IDs are unique
	id1 := generateDiscoveryID()
	id2 := generateDiscoveryID()

	assert.NotEmpty(t, id1)
	assert.NotEmpty(t, id2)
	assert.NotEqual(t, id1, id2)
}

func TestCollectRecursiveSNMPTargets(t *testing.T) {
	mockPublisher := new(MockPublisher)
	mockLogger := logger.NewTestLogger()
	config := &Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}

	engine, err := NewDiscoveryEngine(config, mockPublisher, mockLogger)
	require.NoError(t, err)

	discoveryEngine := engine.(*DiscoveryEngine)
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			TopologyLinks: []*TopologyLink{
				{NeighborMgmtAddr: "192.168.1.87"},
				{NeighborMgmtAddr: "192.168.10.154"},
				{NeighborMgmtAddr: "not-an-ip"},
				{NeighborMgmtAddr: "192.168.1.87"},
			},
		},
	}

	known := map[string]bool{"192.168.1.87": true}
	targets := discoveryEngine.collectRecursiveSNMPTargets(job, known)

	assert.Len(t, targets, 1)
	assert.True(t, targets["192.168.10.154"])
	assert.False(t, targets["192.168.1.87"])
}

func TestTopologyStageReadyRequiresIdentityAndEnrichmentCompletion(t *testing.T) {
	transitions := []DiscoveryStageTransition{
		{Stage: DiscoveryStagePrepare, Status: DiscoveryStageStatusCompleted},
		{Stage: DiscoveryStageIdentity, Status: DiscoveryStageStatusCompleted},
	}
	assert.False(t, topologyStageReady(transitions))

	transitions = append(transitions, DiscoveryStageTransition{
		Stage:  DiscoveryStageEnrich,
		Status: DiscoveryStageStatusCompleted,
	})
	assert.True(t, topologyStageReady(transitions))
}

func TestDeduplicateDevicesDoesNotMergeTopologyAdjacency(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{DeviceID: "mac-aa", IP: "10.0.0.1", MAC: "aa:aa:aa:aa:aa:aa", Metadata: map[string]string{}},
				{DeviceID: "mac-bb", IP: "10.0.0.2", MAC: "bb:bb:bb:bb:bb:bb", Metadata: map[string]string{}},
			},
			TopologyLinks: []*TopologyLink{
				{LocalDeviceIP: "10.0.0.1", NeighborMgmtAddr: "10.0.0.2"},
			},
		},
		deviceMap: map[string]*DeviceInterfaceMap{
			"mac-aa": {
				DeviceID: "mac-aa",
				MACs:     map[string]struct{}{"aa:aa:aa:aa:aa:aa": {}},
				IPs:      map[string]struct{}{"10.0.0.1": {}},
			},
			"mac-bb": {
				DeviceID: "mac-bb",
				MACs:     map[string]struct{}{"bb:bb:bb:bb:bb:bb": {}},
				IPs:      map[string]struct{}{"10.0.0.2": {}},
			},
		},
	}

	engine.deduplicateDevices(job)
	assert.Len(t, job.Results.Devices, 2)
}

type countingProber struct {
	mu    sync.Mutex
	calls int
}

func (p *countingProber) Probe(_ context.Context, _ string) error {
	p.mu.Lock()
	p.calls++
	p.mu.Unlock()
	return nil
}

func (*countingProber) Close() error { return nil }

func TestStartWorkersUsesSharedHostProber(t *testing.T) {
	prober := &countingProber{}
	engine := &DiscoveryEngine{hostProber: prober, done: make(chan struct{}), logger: logger.NewTestLogger()}
	job := &DiscoveryJob{
		ID: "job-1",
		Results: &DiscoveryResults{
			Contract: DiscoveryContract{},
		},
		ctx: context.Background(),
	}

	targetChan := make(chan string, 3)
	resultChan := make(chan bool, 3)
	for _, target := range []string{"10.0.0.1", "10.0.0.2", "10.0.0.3"} {
		targetChan <- target
	}
	close(targetChan)

	var wg sync.WaitGroup
	engine.startWorkers(job, &wg, targetChan, resultChan, 2, func(_ *DiscoveryJob, _ string) {})
	wg.Wait()
	close(resultChan)

	assert.Equal(t, 3, prober.calls)
	assert.Equal(t, 3, job.Results.Contract.ProbeSummary.Attempts)
}

func BenchmarkStartWorkersProbeComparison(b *testing.B) {
	bench := func(b *testing.B, useProber bool) { //nolint:thelper // not a standalone test helper
		for i := 0; i < b.N; i++ {
			engine := &DiscoveryEngine{done: make(chan struct{}), logger: logger.NewTestLogger()}
			if useProber {
				engine.hostProber = &countingProber{}
			}
			job := &DiscoveryJob{
				ID: fmt.Sprintf("job-%d", i),
				Results: &DiscoveryResults{
					Contract: DiscoveryContract{},
				},
				ctx: context.Background(),
			}

			targetChan := make(chan string, 50)
			resultChan := make(chan bool, 50)
			for t := 0; t < 50; t++ {
				targetChan <- fmt.Sprintf("10.0.0.%d", t+1)
			}
			close(targetChan)

			var wg sync.WaitGroup
			engine.startWorkers(job, &wg, targetChan, resultChan, 10, func(_ *DiscoveryJob, _ string) {})
			wg.Wait()
			close(resultChan)
		}
	}

	b.Run("without_prober", func(b *testing.B) { bench(b, false) })
	b.Run("with_shared_prober", func(b *testing.B) { bench(b, true) })
}

func TestMaybeExportDebugBundle(t *testing.T) {
	mockLogger := logger.NewTestLogger()
	engine := &DiscoveryEngine{logger: mockLogger}
	exportDir := t.TempDir()

	job := &DiscoveryJob{
		ID: "job-debug-1",
		Params: &DiscoveryParams{
			Options: map[string]string{
				mapperDebugBundleOption:     "true",
				mapperDebugBundlePathOption: exportDir,
			},
		},
		Status: &DiscoveryStatus{
			Status:   DiscoveryStatusCompleted,
			Progress: 100,
		},
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{DeviceID: "mac-a", IP: "192.168.1.10"},
			},
			Interfaces: []*DiscoveredInterface{
				{DeviceID: "mac-a", DeviceIP: "192.168.1.10", IfIndex: 1, IfName: "eth0"},
			},
			TopologyLinks: []*TopologyLink{
				{LocalDeviceID: "mac-a", LocalDeviceIP: "192.168.1.10", NeighborMgmtAddr: "192.168.1.1"},
			},
			Contract: DiscoveryContract{
				AgentID: "agent-dusk",
			},
		},
	}

	engine.maybeExportDebugBundle(job)

	expectedPath := filepath.Join(exportDir, "job-debug-1-debug-bundle.json")
	_, err := os.Stat(expectedPath)
	require.NoError(t, err)
	assert.Equal(t, expectedPath, job.Results.Contract.DebugBundle.ExportPath)
	assert.Equal(t, 1, job.Results.Contract.DebugBundle.DeviceCount)
	assert.Equal(t, 1, job.Results.Contract.DebugBundle.InterfaceCount)
	assert.Equal(t, 1, job.Results.Contract.DebugBundle.TopologyCount)
	assert.Empty(t, job.Results.Contract.DebugBundle.Error)
}

func TestApplySourceAdapterVersion(t *testing.T) {
	tests := []struct {
		name     string
		link     *TopologyLink
		expected string
		family   string
	}{
		{
			name: "unifi source",
			link: &TopologyLink{
				Protocol: "UniFi-API",
				Metadata: map[string]string{"source": "unifi-api-uplink"},
			},
			expected: sourceAdapterUniFiV1,
			family:   "unifi",
		},
		{
			name: "lldp protocol",
			link: &TopologyLink{
				Protocol: "LLDP",
				Metadata: map[string]string{},
			},
			expected: sourceAdapterLLDPV1,
			family:   "lldp",
		},
		{
			name: "cdp protocol",
			link: &TopologyLink{
				Protocol: "CDP",
				Metadata: map[string]string{},
			},
			expected: sourceAdapterCDPV1,
			family:   "cdp",
		},
		{
			name: "snmp inferred",
			link: &TopologyLink{
				Protocol: "SNMP-L2",
				Metadata: map[string]string{"source": "snmp-arp-fdb"},
			},
			expected: sourceAdapterSNMPV1,
			family:   "snmp",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			applySourceAdapterVersion(tt.link)
			assert.Equal(t, tt.expected, tt.link.Metadata["source_adapter_version"])
			assert.Equal(t, tt.family, tt.link.Metadata["source_adapter_family"])
		})
	}
}

func TestAttachTopologyObservationV2(t *testing.T) {
	link := &TopologyLink{
		Protocol:           "LLDP",
		LocalDeviceIP:      "192.168.10.1",
		LocalDeviceID:      "mac-001122334455",
		LocalIfIndex:       23,
		LocalIfName:        "eth4",
		NeighborMgmtAddr:   "192.168.10.154",
		NeighborChassisID:  "0c:ea:14:32:d2:77",
		NeighborPortID:     "eth4",
		NeighborSystemName: "tonka01",
		Metadata: map[string]string{
			"discovery_id":           "job-1",
			"source":                 "snmp-lldp",
			"evidence_class":         "direct",
			"confidence_tier":        "high",
			"source_adapter_version": sourceAdapterLLDPV1,
		},
	}

	attachTopologyObservationV2(link)

	require.NotNil(t, link.Observation)
	assert.Equal(t, topologyContractV2, link.Observation.ContractVersion)
	assert.Equal(t, "topology_link", link.Observation.ObservationType)
	assert.Equal(t, "lldp", link.Observation.SourceProtocol)
	assert.Equal(t, sourceAdapterLLDPV1, link.Observation.SourceAdapter)
	assert.Equal(t, topologyContractV2, link.Metadata["observation_contract_version"])
	require.NotEmpty(t, link.Metadata["observation_v2_json"])

	var parsed TopologyObservationV2
	require.NoError(t, json.Unmarshal([]byte(link.Metadata["observation_v2_json"]), &parsed))
	assert.Equal(t, "mac-001122334455", parsed.SourceEndpoint.UID)
	assert.Equal(t, "0c:ea:14:32:d2:77", parsed.TargetEndpoint.UID)
}
