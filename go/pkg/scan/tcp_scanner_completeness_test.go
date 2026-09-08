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
	"hash/fnv"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func uniqueLoopbackHost(t *testing.T, ctx context.Context) string {
	t.Helper()

	h := fnv.New32a()
	_, _ = io.WriteString(h, t.Name())
	seed := h.Sum32()

	lc := net.ListenConfig{}

	for i := range 16 {
		n := seed + uint32(i)*7919
		host := net.IPv4(127, byte(2+(n/65534)%53), byte(n/256), byte(1+n%254)).String()

		ln, err := lc.Listen(ctx, "tcp", net.JoinHostPort(host, "0"))
		if err != nil {
			// macOS often only has 127.0.0.1 configured on lo0.
			continue
		}

		require.NoError(t, ln.Close())

		return host
	}

	return "127.0.0.1"
}

func tcpAddr(host string, port int) string {
	return net.JoinHostPort(host, strconv.Itoa(port))
}

func portClosed(ctx context.Context, host string, port int) bool {
	d := net.Dialer{Timeout: 50 * time.Millisecond}

	conn, err := d.DialContext(ctx, "tcp", tcpAddr(host, port))
	if err != nil {
		return true
	}

	_ = conn.Close()

	return false
}

// listenTCP starts a TCP listener on a random port using the context-aware ListenConfig.
func listenTCP(t *testing.T, ctx context.Context, host string) net.Listener {
	t.Helper()

	lc := net.ListenConfig{}

	ln, err := lc.Listen(ctx, "tcp", net.JoinHostPort(host, "0"))
	require.NoError(t, err)

	t.Cleanup(func() { _ = ln.Close() })

	return ln
}

// closedPortTCP returns a port with nothing listening on host.
//
// Binding and immediately releasing is what makes the port closed: the kernel
// has just told us nothing else holds it. Guessing an offset instead -- these
// tests used openPort+10000 and fixed values like 19991 -- only assumes it.
//
// Releasing still races: a sibling t.Parallel() listenTCP on the same host can
// be given the just-freed port, which is how TestTCPScanner_AllPortsChecked
// failed in CI with "Port 34289 should be unavailable (no listener)". Isolate
// each test on a unique 127.x.y.z when the OS allows it, and re-check Dial
// after close so a 0.0.0.0 thief is not accepted.
func closedPortTCP(t *testing.T, ctx context.Context, host string) int {
	t.Helper()

	lc := net.ListenConfig{}

	for range 32 {
		ln, err := lc.Listen(ctx, "tcp", net.JoinHostPort(host, "0"))
		require.NoError(t, err)

		port := ln.Addr().(*net.TCPAddr).Port
		require.NoError(t, ln.Close())

		if portClosed(ctx, host, port) {
			return port
		}
	}

	t.Fatal("could not reserve a TCP port that stays closed")

	return 0
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

	host := uniqueLoopbackHost(t, ctx)

	// Start listeners on multiple ports to have some succeed and some fail
	ports := make([]int, 3)
	for i := range 3 {
		ln := listenTCP(t, ctx, host)
		ports[i] = ln.Addr().(*net.TCPAddr).Port
	}

	// Create targets for two hosts, each with all three ports
	// Host 1 has all ports listening (will succeed), host 2 has none (will fail)
	targets := make([]models.Target, 0, 8)

	// Host 1: all ports open
	for _, port := range ports {
		targets = append(targets, models.Target{
			Host: host,
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	// Host 2: no ports open. Reserve-and-release so they really are closed.
	closedPorts := []int{closedPortTCP(t, ctx, host), closedPortTCP(t, ctx, host), closedPortTCP(t, ctx, host)}
	for _, port := range closedPorts {
		targets = append(targets, models.Target{
			Host: host,
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
		key := targetKey{host: host, port: port}
		r, exists := resultMap[key]
		assert.True(t, exists, "Missing result for open port %d", port)
		assert.True(t, r.Available, "Port %d should be available (listener running)", port)
	}

	// All closed ports should have results and be unavailable
	for _, port := range closedPorts {
		key := targetKey{host: host, port: port}
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

	host := uniqueLoopbackHost(t, ctx)

	// Start a listener on one port only
	ln := listenTCP(t, ctx, host)

	openPort := ln.Addr().(*net.TCPAddr).Port
	closedPort1 := closedPortTCP(t, ctx, host)
	closedPort2 := closedPortTCP(t, ctx, host)

	// Create targets: one open port sandwiched between closed ports
	targets := []models.Target{
		{Host: host, Port: closedPort1, Mode: models.ModeTCP},
		{Host: host, Port: openPort, Mode: models.ModeTCP},
		{Host: host, Port: closedPort2, Mode: models.ModeTCP},
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

	host := uniqueLoopbackHost(t, ctx)

	// Start listeners on 2 out of 20 ports
	ln1 := listenTCP(t, ctx, host)
	ln2 := listenTCP(t, ctx, host)

	openPort1 := ln1.Addr().(*net.TCPAddr).Port
	openPort2 := ln2.Addr().(*net.TCPAddr).Port

	// Create 20 targets: 2 open, 18 closed
	targets := make([]models.Target, 0, 20)
	targets = append(targets, models.Target{Host: host, Port: openPort1, Mode: models.ModeTCP})
	targets = append(targets, models.Target{Host: host, Port: openPort2, Mode: models.ModeTCP})

	for range 18 {
		targets = append(targets, models.Target{
			Host: host,
			Port: closedPortTCP(t, ctx, host),
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

	// localhost and 127.0.0.1 must share a listener, so this test stays on
	// 127.0.0.1 rather than a unique 127.x.y.z alias.
	host := "127.0.0.1"

	// Start a listener
	ln := listenTCP(t, ctx, host)

	openPort := ln.Addr().(*net.TCPAddr).Port
	closedPort := closedPortTCP(t, ctx, host)

	// Two "hosts" (both 127.0.0.1 but with different conceptual targets)
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
