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

package scan

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// listenTCP starts a TCP listener on a random port using the context-aware ListenConfig.
func listenTCP(t *testing.T, ctx context.Context) net.Listener {
	t.Helper()

	lc := net.ListenConfig{}

	ln, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	require.NoError(t, err)

	t.Cleanup(func() { _ = ln.Close() })

	return ln
}

// collectResults drains a result channel into a slice.
func collectResults(ch <-chan models.Result) []models.Result {
	results := make([]models.Result, 0)
	for r := range ch {
		results = append(results, r)
	}

	return results
}

// TestTCPScanner_AllPortsChecked verifies that every configured target is scanned.
// This is a critical guarantee: if ports [22, 80, 443] are configured, all three
// MUST be checked for every host, even if one succeeds early.
func TestTCPScanner_AllPortsChecked(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Start listeners on multiple ports to have some succeed and some fail
	ports := make([]int, 3)
	for i := range 3 {
		ln := listenTCP(t, ctx)
		ports[i] = ln.Addr().(*net.TCPAddr).Port
	}

	// Create targets for two hosts, each with all three ports
	// Host 1 has all ports listening (will succeed), host 2 has none (will fail)
	targets := make([]models.Target, 0, 8)

	// Host 1: all ports open (127.0.0.1 has listeners)
	for _, port := range ports {
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	// Host 2: no ports open (use a port that's definitely closed)
	closedPorts := []int{19991, 19992, 19993}
	for _, port := range closedPorts {
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	scanner := NewTCPSweeper(2*time.Second, 10, logger.NewTestLogger())

	resultCh, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	results := collectResults(resultCh)

	// CRITICAL: We must get exactly one result per target
	assert.Len(t, results, len(targets),
		"Must get exactly one result per target - no targets should be skipped")

	// Verify every target appears in results
	type targetKey struct {
		host string
		port int
	}

	resultMap := make(map[targetKey]models.Result)
	for _, r := range results {
		key := targetKey{host: r.Target.Host, port: r.Target.Port}
		resultMap[key] = r
	}

	// All open ports should have results and be available
	for _, port := range ports {
		key := targetKey{host: "127.0.0.1", port: port}
		r, exists := resultMap[key]
		assert.True(t, exists, "Missing result for open port %d", port)
		assert.True(t, r.Available, "Port %d should be available (listener running)", port)
	}

	// All closed ports should have results and be unavailable
	for _, port := range closedPorts {
		key := targetKey{host: "127.0.0.1", port: port}
		r, exists := resultMap[key]
		assert.True(t, exists, "Missing result for closed port %d - scanner skipped it!", port)
		assert.False(t, r.Available, "Port %d should be unavailable (no listener)", port)
	}
}

// TestTCPScanner_NoEarlyExitOnSuccess verifies that finding one open port
// does NOT cause the scanner to skip remaining ports for the same host.
func TestTCPScanner_NoEarlyExitOnSuccess(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Start a listener on one port only
	ln := listenTCP(t, ctx)

	openPort := ln.Addr().(*net.TCPAddr).Port
	closedPort1 := openPort + 10000 // very unlikely to be in use
	closedPort2 := openPort + 10001

	// Create targets: one open port sandwiched between closed ports
	targets := []models.Target{
		{Host: "127.0.0.1", Port: closedPort1, Mode: models.ModeTCP},
		{Host: "127.0.0.1", Port: openPort, Mode: models.ModeTCP},
		{Host: "127.0.0.1", Port: closedPort2, Mode: models.ModeTCP},
	}

	scanner := NewTCPSweeper(2*time.Second, 10, logger.NewTestLogger())

	resultCh, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	results := collectResults(resultCh)

	// Must get ALL three results, not just the one that succeeded
	assert.Len(t, results, 3,
		"Scanner must check ALL ports even after finding an open one")

	// Verify we have results for each specific port
	portResults := make(map[int]bool)
	for _, r := range results {
		portResults[r.Target.Port] = r.Available
	}

	assert.Contains(t, portResults, closedPort1, "Missing result for first closed port")
	assert.Contains(t, portResults, openPort, "Missing result for open port")
	assert.Contains(t, portResults, closedPort2, "Missing result for second closed port")

	assert.False(t, portResults[closedPort1], "Closed port 1 should be unavailable")
	assert.True(t, portResults[openPort], "Open port should be available")
	assert.False(t, portResults[closedPort2], "Closed port 2 should be unavailable")
}

// TestTCPScanner_LargePortList verifies all ports are checked even with many ports configured.
func TestTCPScanner_LargePortList(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// Start listeners on 2 out of 20 ports
	ln1 := listenTCP(t, ctx)
	ln2 := listenTCP(t, ctx)

	openPort1 := ln1.Addr().(*net.TCPAddr).Port
	openPort2 := ln2.Addr().(*net.TCPAddr).Port

	// Create 20 targets: 2 open, 18 closed
	targets := make([]models.Target, 0, 20)
	targets = append(targets, models.Target{Host: "127.0.0.1", Port: openPort1, Mode: models.ModeTCP})
	targets = append(targets, models.Target{Host: "127.0.0.1", Port: openPort2, Mode: models.ModeTCP})

	for i := range 18 {
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: 29000 + i, // unlikely to be in use
			Mode: models.ModeTCP,
		})
	}

	scanner := NewTCPSweeper(2*time.Second, 50, logger.NewTestLogger())

	resultCh, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	results := collectResults(resultCh)

	assert.Len(t, results, 20,
		"Must get results for ALL 20 ports - no port should be skipped")

	// Count available vs unavailable
	available := 0
	for _, r := range results {
		if r.Available {
			available++
		}
	}

	assert.Equal(t, 2, available, "Exactly 2 ports should be available")
	assert.Equal(t, 18, len(results)-available, "Exactly 18 ports should be unavailable")
}

// TestTCPScanner_MultiHostAllPortsChecked verifies that for multiple hosts,
// every host gets every port checked.
func TestTCPScanner_MultiHostAllPortsChecked(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Start a listener
	ln := listenTCP(t, ctx)

	openPort := ln.Addr().(*net.TCPAddr).Port
	closedPort := openPort + 10000

	// Two "hosts" (both 127.0.0.1 but with different conceptual targets)
	// We'll use localhost and 127.0.0.1 to represent different hosts
	hosts := []string{"127.0.0.1", "localhost"}
	portsToCheck := []int{openPort, closedPort}

	targets := make([]models.Target, 0, len(hosts)*len(portsToCheck))
	for _, host := range hosts {
		for _, port := range portsToCheck {
			targets = append(targets, models.Target{
				Host: host,
				Port: port,
				Mode: models.ModeTCP,
			})
		}
	}

	scanner := NewTCPSweeper(2*time.Second, 10, logger.NewTestLogger())

	resultCh, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	results := collectResults(resultCh)

	// Must get one result per target
	assert.Len(t, results, len(targets),
		"Must get results for every host x port combination")

	// Verify each host has results for each port
	type hostPort struct {
		host string
		port int
	}

	seen := make(map[hostPort]bool)
	for _, r := range results {
		key := hostPort{host: r.Target.Host, port: r.Target.Port}
		assert.False(t, seen[key], "Duplicate result for %s:%d", r.Target.Host, r.Target.Port)
		seen[key] = true
	}

	for _, host := range hosts {
		for _, port := range portsToCheck {
			key := hostPort{host: host, port: port}
			assert.True(t, seen[key],
				"Missing result for %s:%d - scanner skipped it!", host, port)
		}
	}
}
