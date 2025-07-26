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
	"context"
	"fmt"
	"log"
	"math/big"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBaseProcessor_Cleanup(t *testing.T) {
	// Initialize the processor with a sample config
	config := &models.Config{
		Ports: []int{443, 8080, 80}, // Using some ports, including 443 and 8080
	}
	processor := NewBaseProcessor(config, logger.NewTestLogger())

	// Simulate processing of results for ports 443 and 8080
	result1 := &models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Port: 443,
			Mode: models.ModeTCP,
		},
		Available: true,
		RespTime:  time.Millisecond * 10,
	}

	result2 := &models.Result{
		Target: models.Target{
			Host: "192.168.1.2",
			Port: 8080,
			Mode: models.ModeTCP,
		},
		Available: true,
		RespTime:  time.Millisecond * 15,
	}

	// Process the results
	err := processor.Process(result1)
	require.NoError(t, err)

	err = processor.Process(result2)
	require.NoError(t, err)

	// Check the portCounts before cleanup
	portCounts := processor.GetPortCounts()
	assert.Equal(t, 1, portCounts[443], "Expected port 443 to have 1 count")
	assert.Equal(t, 1, portCounts[8080], "Expected port 8080 to have 1 count")

	// Call cleanup
	processor.cleanup()

	// Verify that portCounts are cleared after cleanup
	portCountsAfter := processor.GetPortCounts()
	assert.Empty(t, portCountsAfter, "Expected portCounts to be empty after cleanup")
}

func TestBaseProcessor_MemoryManagement(t *testing.T) {
	config := createLargePortConfig()

	t.Run("Memory Usage with Many Hosts Few Ports", func(t *testing.T) {
		testMemoryUsageWithManyHostsFewPorts(t, config)
	})

	t.Run("Memory Usage with Few Hosts Many Ports", func(t *testing.T) {
		testMemoryUsageWithFewHostsManyPorts(t, config)
	})

	t.Run("Memory Release After Cleanup", func(t *testing.T) {
		testMemoryReleaseAfterCleanup(t, config)
	})
}

func createLargePortConfig() *models.Config {
	config := &models.Config{
		Ports: make([]int, 2300),
	}

	for i := range config.Ports {
		config.Ports[i] = i + 1
	}

	return config
}

func testMemoryUsageWithManyHostsFewPorts(t *testing.T, config *models.Config) {
	t.Helper()

	processor := NewBaseProcessor(config, logger.NewTestLogger())
	defer processor.cleanup()

	// Consider removing or reducing frequency of forced GC
	// runtime.GC() // Force garbage collection before test

	var memBefore runtime.MemStats

	runtime.ReadMemStats(&memBefore)

	// Process 500 hosts with only 1-2 ports each
	for i := 0; i < 500; i++ {
		host := createHost(i%255, i%2+1)
		err := processor.Process(host)
		require.NoError(t, err)
	}

	// Consider removing or reducing frequency of forced GC
	// runtime.GC() // Force garbage collection before measurement

	var memAfter runtime.MemStats

	runtime.ReadMemStats(&memAfter)

	var memGrowth uint64

	if memAfter.Alloc < memBefore.Alloc {
		t.Logf("memAfter.Alloc (%d) is less than memBefore.Alloc (%d). Likely due to GC.", memAfter.Alloc, memBefore.Alloc)

		memGrowth = 0 // Treat this as zero growth
	} else {
		memGrowth = memAfter.Alloc - memBefore.Alloc
	}

	t.Logf("Memory growth: %d bytes", memGrowth)
	assert.Less(t, memGrowth, uint64(10*1024*1024), "Memory growth should be less than 10MB")
}

func testMemoryUsageWithFewHostsManyPorts(t *testing.T, config *models.Config) {
	t.Helper()

	processor := NewBaseProcessor(config, logger.NewTestLogger())
	defer processor.cleanup()

	var memBefore runtime.MemStats

	runtime.ReadMemStats(&memBefore)

	numHosts := 2
	numPorts := 100

	for i := 0; i < numHosts; i++ {
		for port := 1; port <= numPorts; port++ {
			host := createHost(i, port)
			err := processor.Process(host)
			require.NoError(t, err)
		}
	}

	var memAfter runtime.MemStats

	runtime.ReadMemStats(&memAfter)

	// Handle potential underflow
	var memGrowth uint64

	if memAfter.HeapAlloc < memBefore.HeapAlloc {
		t.Logf("HeapAlloc decreased after processing; likely due to garbage collection. memBefore: %d, memAfter: %d",
			memBefore.HeapAlloc, memAfter.HeapAlloc)

		memGrowth = 0 // Treat as zero growth
	} else {
		memGrowth = memAfter.HeapAlloc - memBefore.HeapAlloc
	}

	t.Logf("Memory growth with many ports: %d bytes", memGrowth)

	const maxMemoryGrowth = 75 * 1024 * 1024 // 75MB

	assert.Less(t, memGrowth, uint64(maxMemoryGrowth), "Memory growth should be less than 75MB")
}

func testMemoryReleaseAfterCleanup(t *testing.T, config *models.Config) {
	t.Helper()

	processor := NewBaseProcessor(config, logger.NewTestLogger())

	// Force GC and minimal wait
	runtime.GC()
	time.Sleep(10 * time.Millisecond)

	var memBefore runtime.MemStats

	runtime.ReadMemStats(&memBefore)

	// Process a moderate amount of data
	for i := 0; i < 100; i++ {
		for port := 1; port <= 100; port++ {
			host := createHost(i, port)
			err := processor.Process(host)
			require.NoError(t, err)
		}
	}

	// Capture memory after processing but before cleanup
	var memPeak runtime.MemStats

	runtime.ReadMemStats(&memPeak)

	processor.cleanup() // Call cleanup

	// Force GC after cleanup with minimal wait
	runtime.GC()
	time.Sleep(10 * time.Millisecond)

	var memAfter runtime.MemStats

	runtime.ReadMemStats(&memAfter)

	memDiff := new(big.Int).Sub(
		new(big.Int).SetUint64(memAfter.HeapAlloc),
		new(big.Int).SetUint64(memBefore.HeapAlloc),
	)

	memReduction := new(big.Int).Sub(
		new(big.Int).SetUint64(memPeak.HeapAlloc),
		new(big.Int).SetUint64(memAfter.HeapAlloc),
	)

	t.Logf("Memory before: %d bytes", memBefore.HeapAlloc)
	t.Logf("Memory at peak: %d bytes", memPeak.HeapAlloc)
	t.Logf("Memory after cleanup: %d bytes", memAfter.HeapAlloc)
	t.Logf("Memory difference from baseline: %s bytes", memDiff.String())
	t.Logf("Memory reduction from peak: %s bytes", memReduction.String())

	// Verify that cleanup actually happened by checking processor state
	hostMap := processor.GetHostMap()
	portCounts := processor.GetPortCounts()

	assert.Empty(t, hostMap, "Host map should be empty after cleanup")
	assert.Empty(t, portCounts, "Port counts should be empty after cleanup")

	// Memory growth assertions - be more lenient due to GC timing variability
	maxAllowedGrowth := big.NewInt(5 * 1024 * 1024) // Allow 5MB growth

	if memDiff.Cmp(big.NewInt(0)) <= 0 {
		t.Logf("Memory was released successfully (negative or zero growth)")
	} else if memDiff.Cmp(maxAllowedGrowth) <= 0 {
		t.Logf("Memory growth within acceptable limits: %s bytes", memDiff.String())
	} else {
		t.Errorf("Memory growth too high: %s bytes (limit: 5MB)", memDiff.String())
	}
}

func createHost(hostIndex, port int) *models.Result {
	return &models.Result{
		Target: models.Target{
			Host: fmt.Sprintf("192.168.1.%d", hostIndex),
			Port: port,
			Mode: models.ModeTCP,
		},
		Available: true,
		RespTime:  time.Millisecond * 10,
	}
}

func TestBaseProcessor_ConcurrentAccess(t *testing.T) {
	config := &models.Config{
		Ports: []int{80, 443, 8080}, // Reduced number of ports for testing
	}

	processor := NewBaseProcessor(config, logger.NewTestLogger())
	defer processor.cleanup()

	t.Run("Concurrent Processing", func(t *testing.T) {
		var wg sync.WaitGroup

		numHosts := 10
		resultsPerHost := 20 // Multiple results per host

		// Create a buffered channel to collect any errors
		errorChan := make(chan error, numHosts*resultsPerHost)

		// Test concurrent access for each host
		for i := 0; i < numHosts; i++ {
			host := fmt.Sprintf("192.168.1.%d", i)

			wg.Add(1)

			go func(host string) {
				defer wg.Done()

				for j := 0; j < resultsPerHost; j++ {
					result := &models.Result{
						Target: models.Target{
							Host: host,
							Port: config.Ports[j%len(config.Ports)], // Cycle through ports
							Mode: models.ModeTCP,
						},
						Available: true,
						RespTime:  time.Millisecond * time.Duration(j+1),
					}

					if err := processor.Process(result); err != nil {
						errorChan <- fmt.Errorf("host %s, iteration %d: %w", host, j, err)

						return // Stop processing this host on error
					}
				}
			}(host)
		}

		// Wait for all goroutines to complete
		wg.Wait()

		close(errorChan)

		// Check for any errors
		var errors []error

		for err := range errorChan {
			errors = append(errors, err)
		}

		assert.Empty(t, errors, "No errors should occur during concurrent processing")

		// Verify results
		hostMap := processor.GetHostMap()
		assert.Len(t, hostMap, numHosts, "Should have expected number of hosts")

		for _, host := range hostMap {
			assert.NotNil(t, host)
			assert.Len(t, host.PortResults, len(config.Ports), "Each host should have results for all configured ports")
		}
	})
}

func TestBaseProcessor_ResourceCleanup(t *testing.T) {
	config := &models.Config{
		Ports: make([]int, 2300),
	}

	for i := range config.Ports {
		config.Ports[i] = i + 1
	}

	t.Run("Cleanup After Processing", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())

		// Process some results
		for i := 0; i < 100; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i),
					Port: i%2300 + 1,
					Mode: models.ModeTCP,
				},
				Available: true,
				RespTime:  time.Millisecond * 10,
			}

			err := processor.Process(result)
			require.NoError(t, err) // Use require here, as we are in the main test goroutine
		}

		// Verify we have data
		hostMap := processor.GetHostMap()
		portCounts := processor.GetPortCounts()

		assert.NotEmpty(t, hostMap)
		assert.NotEmpty(t, portCounts)

		// Cleanup
		processor.cleanup()

		// Verify everything is cleaned up
		hostMapAfter := processor.GetHostMap()
		portCountsAfter := processor.GetPortCounts()

		assert.Empty(t, hostMapAfter)
		assert.Empty(t, portCountsAfter)

		firstSeenTimesAfter := processor.GetFirstSeenTimes()
		lastSweepTimeAfter := processor.GetLatestSweepTime()

		assert.Empty(t, firstSeenTimesAfter)
		assert.True(t, lastSweepTimeAfter.IsZero())
	})

	t.Run("Pool Reuse", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())
		defer processor.cleanup()

		// Process results and track allocated hosts
		allocatedHosts := make(map[*models.HostResult]struct{})

		// First batch
		for i := 0; i < 10; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i),
					Port: 80,
					Mode: models.ModeTCP,
				},
				Available: true,
			}

			err := processor.Process(result)
			require.NoError(t, err)

			// Track the allocated host
			hostMap := processor.GetHostMap()
			allocatedHosts[hostMap[result.Target.Host]] = struct{}{}
		}

		// Cleanup and process again
		processor.cleanup()

		// Second batch
		reusedCount := 0

		for i := 0; i < 10; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i),
					Port: 80,
					Mode: models.ModeTCP,
				},
				Available: true,
			}

			err := processor.Process(result)
			require.NoError(t, err)

			// Check if the host was reused
			hostMapAfter := processor.GetHostMap()
			if _, exists := allocatedHosts[hostMapAfter[result.Target.Host]]; exists {
				reusedCount++
			}
		}

		// We should see some reuse of objects from the pool
		assert.Positive(t, reusedCount, "Should reuse some objects from the pool")
	})
}

func TestBaseProcessor_ConfigurationUpdates(t *testing.T) {
	initialConfig := &models.Config{
		Ports: make([]int, 100), // Start with fewer ports
	}
	for i := range initialConfig.Ports {
		initialConfig.Ports[i] = i + 1
	}

	t.Run("Handle Config Updates", func(t *testing.T) {
		processor := NewBaseProcessor(initialConfig, logger.NewTestLogger())
		defer processor.cleanup()

		// Test initial configuration
		assert.Equal(t, 100, processor.portCount, "Initial port count should match config")

		// Process some results with initial config
		for i := 0; i < 10; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i),
					Port: i%100 + 1,
					Mode: models.ModeTCP,
				},
				Available: true,
			}

			err := processor.Process(result)
			require.NoError(t, err, "Processing with initial config should succeed")
		}

		// Verify initial state
		hostMap := processor.GetHostMap()
		initialHosts := len(hostMap)

		var initialCapacity int

		for _, host := range hostMap {
			initialCapacity = cap(host.PortResults)
			break
		}

		assert.Equal(t, 10, initialHosts, "Should have 10 hosts initially")
		assert.LessOrEqual(t, initialCapacity, 100, "Initial capacity should not exceed port count")

		log.Printf("Initial capacity: %d", initialCapacity)

		// Update to larger port count
		newConfig := &models.Config{
			Ports: make([]int, 2300),
		}

		for i := range newConfig.Ports {
			newConfig.Ports[i] = i + 1
		}

		processor.UpdateConfig(newConfig)

		// Verify config update
		assert.Equal(t, 2300, processor.portCount, "Port count should be updated")

		// Process more results with new config
		for i := 0; i < 10; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.2.%d", i), // Different subnet to avoid conflicts
					Port: i%2300 + 1,
					Mode: models.ModeTCP,
				},
				Available: true,
			}

			err := processor.Process(result)
			require.NoError(t, err, "Processing with new config should succeed")
		}

		// Verify final state
		hostMapFinal := processor.GetHostMap()
		assert.Len(t, hostMapFinal, 20, "Should have 20 hosts total")

		// Check port result capacities
		for _, host := range hostMapFinal {
			assert.LessOrEqual(t, cap(host.PortResults), 2300,
				"Host port results capacity should not exceed new config port count")
		}
	})
}

func TestBaseProcessor_GetSummaryStream(t *testing.T) {
	config := &models.Config{
		Ports: []int{22, 80, 443, 8080},
	}

	t.Run("Streaming Large Dataset", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())
		defer processor.cleanup()

		const numHosts = 100

		portsPerHost := len(config.Ports)

		// Process a dataset with multiple hosts and ports
		for i := 0; i < numHosts; i++ {
			hostIP := fmt.Sprintf("192.168.1.%d", i+1)

			// Add ICMP result first to mark host as available
			icmpResult := &models.Result{
				Target: models.Target{
					Host: hostIP,
					Port: 0,
					Mode: models.ModeICMP,
				},
				Available: true,
				RespTime:  time.Millisecond * 5,
			}

			err := processor.Process(icmpResult)
			require.NoError(t, err)

			// Add TCP results for each port
			for _, port := range config.Ports {
				result := &models.Result{
					Target: models.Target{
						Host: hostIP,
						Port: port,
						Mode: models.ModeTCP,
					},
					Available: true,
					RespTime:  time.Millisecond * 10,
				}
				err := processor.Process(result)
				require.NoError(t, err)
			}
		}

		// Test streaming summary
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		hostCh := make(chan models.HostResult, 50) // Buffered channel

		var streamedHosts []models.HostResult

		var hostCollectionDone sync.WaitGroup

		// Collect streamed hosts in background
		hostCollectionDone.Add(1)

		go func() {
			defer hostCollectionDone.Done()

			for host := range hostCh {
				streamedHosts = append(streamedHosts, host)
			}
		}()

		// Get streaming summary
		summary, err := processor.GetSummaryStream(ctx, hostCh)
		require.NoError(t, err)
		require.NotNil(t, summary)

		// Wait for all hosts to be collected
		hostCollectionDone.Wait()

		// Verify summary metadata
		assert.Equal(t, numHosts, summary.AvailableHosts, "Should have correct available hosts count")
		assert.Equal(t, numHosts, summary.TotalHosts, "Should have correct total hosts count")
		assert.Len(t, summary.Ports, len(config.Ports), "Should have correct number of ports")
		assert.Nil(t, summary.Hosts, "Hosts slice should be nil in streaming mode")

		// Verify all ports have correct counts
		for _, portCount := range summary.Ports {
			assert.Equal(t, numHosts, portCount.Available,
				"Port %d should have %d available hosts", portCount.Port, numHosts)
		}

		// Verify streamed hosts
		assert.Len(t, streamedHosts, numHosts, "Should stream all hosts")

		// Verify each streamed host has expected structure
		for _, host := range streamedHosts {
			assert.True(t, host.Available, "Host should be available")
			assert.NotNil(t, host.ICMPStatus, "Host should have ICMP status")
			assert.True(t, host.ICMPStatus.Available, "ICMP should be available")
			assert.Len(t, host.PortResults, portsPerHost, "Host should have all port results")

			// Verify all ports are available
			for _, portResult := range host.PortResults {
				assert.True(t, portResult.Available, "Port %d should be available", portResult.Port)
				assert.Contains(t, config.Ports, portResult.Port, "Port should be in config")
			}
		}
	})

	t.Run("Context Cancellation", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())
		defer processor.cleanup()

		// Add some test data
		for i := 0; i < 10; i++ {
			result := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i+1),
					Port: 80,
					Mode: models.ModeTCP,
				},
				Available: true,
				RespTime:  time.Millisecond * 10,
			}
			err := processor.Process(result)
			require.NoError(t, err)
		}

		// Create canceled context
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		hostCh := make(chan models.HostResult, 10)

		// Should return context error
		summary, err := processor.GetSummaryStream(ctx, hostCh)
		require.Error(t, err)
		assert.Equal(t, context.Canceled, err)
		assert.Nil(t, summary)
	})

	t.Run("Empty Dataset", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())
		defer processor.cleanup()

		ctx := context.Background()
		hostCh := make(chan models.HostResult, 10)

		var streamedHosts []models.HostResult

		var hostCollectionDone sync.WaitGroup

		// Collect streamed hosts
		hostCollectionDone.Add(1)

		go func() {
			defer hostCollectionDone.Done()

			for host := range hostCh {
				streamedHosts = append(streamedHosts, host)
			}
		}()

		summary, err := processor.GetSummaryStream(ctx, hostCh)
		require.NoError(t, err)
		require.NotNil(t, summary)

		// Wait for all hosts to be collected
		hostCollectionDone.Wait()

		// Should have empty results
		assert.Equal(t, 0, summary.AvailableHosts)
		assert.Equal(t, 0, summary.TotalHosts)
		assert.Empty(t, summary.Ports)
		assert.Empty(t, streamedHosts)
	})

	t.Run("Compare with Regular GetSummary", func(t *testing.T) {
		processor := NewBaseProcessor(config, logger.NewTestLogger())
		defer processor.cleanup()

		const numHosts = 50

		// Add identical test data
		for i := 0; i < numHosts; i++ {
			hostIP := fmt.Sprintf("192.168.1.%d", i+1)

			// ICMP result
			icmpResult := &models.Result{
				Target: models.Target{
					Host: hostIP,
					Port: 0,
					Mode: models.ModeICMP,
				},
				Available: true,
				RespTime:  time.Millisecond * 5,
			}

			err := processor.Process(icmpResult)
			require.NoError(t, err)

			// TCP results
			for _, port := range config.Ports {
				result := &models.Result{
					Target: models.Target{
						Host: hostIP,
						Port: port,
						Mode: models.ModeTCP,
					},
					Available: true,
					RespTime:  time.Millisecond * 10,
				}

				err := processor.Process(result)
				require.NoError(t, err)
			}
		}

		ctx := context.Background()

		// Get regular summary
		regularSummary, err := processor.GetSummary(ctx)
		require.NoError(t, err)

		// Get streaming summary
		hostCh := make(chan models.HostResult, 100)

		var streamedHosts []models.HostResult

		var hostCollectionDone sync.WaitGroup

		hostCollectionDone.Add(1)

		go func() {
			defer hostCollectionDone.Done()

			for host := range hostCh {
				streamedHosts = append(streamedHosts, host)
			}
		}()

		streamingSummary, err := processor.GetSummaryStream(ctx, hostCh)
		require.NoError(t, err)

		// Wait for all hosts to be collected
		hostCollectionDone.Wait()

		// Compare summaries (excluding hosts slice)
		assert.Equal(t, regularSummary.TotalHosts, streamingSummary.TotalHosts)
		assert.Equal(t, regularSummary.AvailableHosts, streamingSummary.AvailableHosts)
		assert.Equal(t, len(regularSummary.Ports), len(streamingSummary.Ports))

		// Compare port counts
		regularPortMap := make(map[int]int)
		for _, pc := range regularSummary.Ports {
			regularPortMap[pc.Port] = pc.Available
		}

		streamingPortMap := make(map[int]int)
		for _, pc := range streamingSummary.Ports {
			streamingPortMap[pc.Port] = pc.Available
		}

		assert.Equal(t, regularPortMap, streamingPortMap, "Port counts should match")

		// Compare hosts (regular summary has hosts, streaming sends via channel)
		assert.Len(t, regularSummary.Hosts, numHosts)
		assert.Len(t, streamedHosts, numHosts)
		assert.Nil(t, streamingSummary.Hosts)

		// Compare host data structure
		regularHostMap := make(map[string]models.HostResult)
		for _, host := range regularSummary.Hosts {
			regularHostMap[host.Host] = host
		}

		streamedHostMap := make(map[string]models.HostResult)
		for _, host := range streamedHosts {
			streamedHostMap[host.Host] = host
		}

		assert.Equal(t, len(regularHostMap), len(streamedHostMap))

		// Verify each host matches
		for hostIP, regularHost := range regularHostMap {
			streamedHost, exists := streamedHostMap[hostIP]
			assert.True(t, exists, "Host %s should exist in streamed results", hostIP)
			assert.Equal(t, regularHost.Available, streamedHost.Available)
			assert.Equal(t, len(regularHost.PortResults), len(streamedHost.PortResults))
		}
	})
}
