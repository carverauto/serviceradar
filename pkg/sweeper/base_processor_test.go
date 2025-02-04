package sweeper

import (
	"fmt"
	"log"
	"math/big"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBaseProcessor_Cleanup(t *testing.T) {
	// Initialize the processor with a sample config
	config := &models.Config{
		Ports: []int{443, 8080, 80}, // Using some ports, including 443 and 8080
	}
	processor := NewBaseProcessor(config)

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
	assert.Equal(t, 1, processor.portCounts[443], "Expected port 443 to have 1 count")
	assert.Equal(t, 1, processor.portCounts[8080], "Expected port 8080 to have 1 count")

	// Call cleanup
	processor.cleanup()

	// Verify that portCounts are cleared after cleanup
	assert.Empty(t, processor.portCounts, "Expected portCounts to be empty after cleanup")
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

	processor := NewBaseProcessor(config)
	defer processor.cleanup()

	// Consider removing or reducing frequency of forced GC
	// runtime.GC() // Force garbage collection before test

	var memBefore runtime.MemStats

	runtime.ReadMemStats(&memBefore)

	// Process 1000 hosts with only 1-2 ports each
	for i := 0; i < 1000; i++ {
		host := createHost(i%255, i%2+1)
		err := processor.Process(host)
		require.NoError(t, err)
	}

	time.Sleep(time.Millisecond * 100)

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

	processor := NewBaseProcessor(config)
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

	processor := NewBaseProcessor(config)

	runtime.GC() // Force GC before test

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

	processor.cleanup() // Call cleanup
	runtime.GC()        // Force GC after cleanup

	var memAfter runtime.MemStats

	runtime.ReadMemStats(&memAfter)

	memDiff := new(big.Int).Sub(
		new(big.Int).SetUint64(memAfter.HeapAlloc),
		new(big.Int).SetUint64(memBefore.HeapAlloc),
	)

	t.Logf("Memory difference after cleanup: %s bytes", memDiff.String())
	assert.Negative(t, memDiff.Cmp(big.NewInt(1*1024*1024)), "Memory should be mostly released after cleanup")
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

	processor := NewBaseProcessor(config)
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
		assert.Len(t, processor.hostMap, numHosts, "Should have expected number of hosts")

		for _, host := range processor.hostMap {
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
		processor := NewBaseProcessor(config)

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
		assert.NotEmpty(t, processor.hostMap)
		assert.NotEmpty(t, processor.portCounts)

		// Cleanup
		processor.cleanup()

		// Verify everything is cleaned up
		assert.Empty(t, processor.hostMap)
		assert.Empty(t, processor.portCounts)
		assert.Empty(t, processor.firstSeenTimes)
		assert.True(t, processor.lastSweepTime.IsZero())
	})

	t.Run("Pool Reuse", func(t *testing.T) {
		processor := NewBaseProcessor(config)
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
			allocatedHosts[processor.hostMap[result.Target.Host]] = struct{}{}
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
			if _, exists := allocatedHosts[processor.hostMap[result.Target.Host]]; exists {
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
		processor := NewBaseProcessor(initialConfig)
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
		processor.mu.RLock()
		initialHosts := len(processor.hostMap)

		var initialCapacity int

		for _, host := range processor.hostMap {
			initialCapacity = cap(host.PortResults)
			break
		}
		processor.mu.RUnlock()

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
		processor.mu.RLock()
		defer processor.mu.RUnlock()

		assert.Len(t, processor.hostMap, 20, "Should have 20 hosts total")

		// Check port result capacities
		for _, host := range processor.hostMap {
			assert.LessOrEqual(t, cap(host.PortResults), 2300,
				"Host port results capacity should not exceed new config port count")
		}
	})
}
