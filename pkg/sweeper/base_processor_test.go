package sweeper

import (
	"fmt"
	"log"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func getMemStats() runtime.MemStats {
	var mem runtime.MemStats

	runtime.ReadMemStats(&mem)

	return mem
}

func TestBaseProcessor_MemoryManagement(t *testing.T) {
	// Create a large port configuration
	config := &models.Config{
		Ports: make([]int, 2300),
	}
	for i := range config.Ports {
		config.Ports[i] = i + 1
	}

	t.Run("Memory Usage with Many Hosts Few Ports", func(t *testing.T) {
		processor := NewBaseProcessor(config)
		defer processor.cleanup()

		// Force garbage collection before test
		runtime.GC()

		// Record initial memory usage
		var memBefore runtime.MemStats

		runtime.ReadMemStats(&memBefore)

		// Process 1000 hosts with only 1-2 ports each
		for i := 0; i < 1000; i++ {
			host := &models.Result{
				Target: models.Target{
					Host: fmt.Sprintf("192.168.1.%d", i%255),
					Port: i%2 + 1,
					Mode: models.ModeTCP,
				},
				Available: true,
				RespTime:  time.Millisecond * 10,
			}
			err := processor.Process(host)
			require.NoError(t, err)
		}

		// Force garbage collection before measurement
		runtime.GC()

		// Get memory usage after processing
		var memAfter runtime.MemStats

		runtime.ReadMemStats(&memAfter)

		// Check memory growth - should be relatively small despite many hosts
		memGrowth := memAfter.Alloc - memBefore.Alloc
		t.Logf("Memory growth: %d bytes", memGrowth)
		assert.Less(t, memGrowth, uint64(10*1024*1024), "Memory growth should be less than 10MB")
	})

	t.Run("Memory Usage with Few Hosts Many Ports", func(t *testing.T) {
		processor := NewBaseProcessor(config)
		defer processor.cleanup()

		// Force garbage collection before test
		runtime.GC()

		var memBefore runtime.MemStats

		runtime.ReadMemStats(&memBefore)

		// Process 10 hosts with many ports each
		for i := 0; i < 10; i++ {
			for port := 1; port <= 1000; port++ {
				host := &models.Result{
					Target: models.Target{
						Host: fmt.Sprintf("192.168.1.%d", i),
						Port: port,
						Mode: models.ModeTCP,
					},
					Available: true,
					RespTime:  time.Millisecond * 10,
				}
				err := processor.Process(host)
				require.NoError(t, err)
			}

			// Force intermediate GC to prevent memory spikes
			if i%2 == 0 {
				runtime.GC()
			}
		}

		// Force garbage collection before measurement
		runtime.GC()

		var memAfter runtime.MemStats

		runtime.ReadMemStats(&memAfter)

		// Use HeapAlloc for more accurate memory measurement
		memGrowth := memAfter.HeapAlloc - memBefore.HeapAlloc
		t.Logf("Memory growth with many ports: %d bytes", memGrowth)

		// Increased the limit slightly since we're dealing with many ports
		const maxMemoryGrowth = 75 * 1024 * 1024 // 75MB

		assert.Less(t, memGrowth, uint64(maxMemoryGrowth),
			"Memory growth should be less than 75MB")
	})

	t.Run("Memory Release After Cleanup", func(t *testing.T) {
		processor := NewBaseProcessor(config)

		// Force GC before test
		runtime.GC()

		var memBefore runtime.MemStats

		runtime.ReadMemStats(&memBefore)

		// Process a moderate amount of data
		for i := 0; i < 100; i++ {
			for port := 1; port <= 100; port++ {
				host := &models.Result{
					Target: models.Target{
						Host: fmt.Sprintf("192.168.1.%d", i),
						Port: port,
						Mode: models.ModeTCP,
					},
					Available: true,
					RespTime:  time.Millisecond * 10,
				}
				err := processor.Process(host)
				require.NoError(t, err)
			}
		}

		// Call cleanup
		processor.cleanup()

		// Force GC after cleanup
		runtime.GC()

		var memAfter runtime.MemStats

		runtime.ReadMemStats(&memAfter)

		// Memory should be mostly released
		memDiff := int64(memAfter.HeapAlloc - memBefore.HeapAlloc)

		t.Logf("Memory difference after cleanup: %d bytes", memDiff)
		assert.Less(t, memDiff, int64(1*1024*1024),
			"Memory should be mostly released after cleanup")
	})
}

func TestBaseProcessor_ConcurrentAccess(t *testing.T) {
	config := &models.Config{
		Ports: make([]int, 2300),
	}
	for i := range config.Ports {
		config.Ports[i] = i + 1
	}

	processor := NewBaseProcessor(config)
	defer processor.cleanup()

	t.Run("Concurrent Processing", func(t *testing.T) {
		var wg sync.WaitGroup
		numGoroutines := 100
		resultsPerRoutine := 100

		// Create a buffered channel to collect any errors
		errorChan := make(chan error, numGoroutines*resultsPerRoutine)

		// Launch multiple goroutines to process results concurrently
		for i := 0; i < numGoroutines; i++ {
			wg.Add(1)
			go func(routineID int) {
				defer wg.Done()
				for j := 0; j < resultsPerRoutine; j++ {
					result := &models.Result{
						Target: models.Target{
							Host: fmt.Sprintf("192.168.1.%d", routineID),
							Port: j%2300 + 1,
							Mode: models.ModeTCP,
						},
						Available: true,
						RespTime:  time.Millisecond * 10,
					}
					if err := processor.Process(result); err != nil {
						errorChan <- fmt.Errorf("routine %d, iteration %d: %w", routineID, j, err)
					}
				}
			}(i)
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
		assert.Len(t, processor.hostMap, numGoroutines, "Should have expected number of hosts")
		for _, host := range processor.hostMap {
			assert.NotNil(t, host)
			// Each host should have some port results
			assert.NotEmpty(t, host.PortResults)
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
			require.NoError(t, err)
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
		assert.Greater(t, reusedCount, 0, "Should reuse some objects from the pool")
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
			log.Printf("Processing result: %v", result)
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

		log.Printf("Updating config to: %v", newConfig)

		processor.UpdateConfig(newConfig)

		log.Printf("Updated config: %v", processor.config)

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

		assert.Equal(t, 20, len(processor.hostMap), "Should have 20 hosts total")

		// Check port result capacities
		for _, host := range processor.hostMap {
			assert.LessOrEqual(t, cap(host.PortResults), 2300,
				"Host port results capacity should not exceed new config port count")
		}
	})
}
