//go:build linux
// +build linux

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
	"encoding/binary"
	"errors"
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestBuildSYNPacketIPv6(t *testing.T) {
	t.Parallel()

	src := net.ParseIP("2001:db8::10")
	dst := net.ParseIP("2001:db8::20")
	packet := buildSYNPacketIPv6(src, dst, 40000, 443, 0x10203040)
	require.Len(t, packet, ipv6TcpPacketSize)

	ip, ipLen, err := parseIPv6(packet)
	require.NoError(t, err)
	assert.Equal(t, ipv6HeaderSize, ipLen)
	assert.Equal(t, uint8(syscall.IPPROTO_TCP), ip.NextHeader)
	assert.Equal(t, src.String(), ip.SrcIP.String())
	assert.Equal(t, dst.String(), ip.DstIP.String())
	assert.Equal(t, uint16(tcpHeaderMinSize), binary.BigEndian.Uint16(packet[4:6]))

	tcp, tcpLen, err := parseTCP(packet[ipLen:])
	require.NoError(t, err)
	assert.Equal(t, tcpHeaderMinSize, tcpLen)
	assert.Equal(t, uint16(40000), tcp.SrcPort)
	assert.Equal(t, uint16(443), tcp.DstPort)
	assert.Equal(t, uint32(0x10203040), tcp.Seq)
	assert.Equal(t, uint8(synFlag), tcp.Flags)

	checksum := binary.BigEndian.Uint16(packet[ipLen+16 : ipLen+18])
	assert.NotZero(t, checksum)
	assert.Equal(t, uint16(0), TCPChecksumIPv6New(src, dst, packet[ipLen:], nil))
}

func TestBuildSYNPacketIPv6RejectsIPv4(t *testing.T) {
	t.Parallel()

	packet := buildSYNPacketIPv6(net.ParseIP("192.0.2.10"), net.ParseIP("2001:db8::20"), 40000, 443, 1)
	assert.Nil(t, packet)
}

func TestParseIPv6(t *testing.T) {
	t.Parallel()

	packet := buildSYNPacketIPv6(net.ParseIP("2001:db8::10"), net.ParseIP("2001:db8::20"), 40000, 443, 1)
	ip, ipLen, err := parseIPv6(packet)
	require.NoError(t, err)
	assert.Equal(t, ipv6HeaderSize, ipLen)
	assert.Equal(t, uint8(syscall.IPPROTO_TCP), ip.NextHeader)

	_, _, err = parseIPv6(packet[:ipv6HeaderSize-1])
	assert.ErrorIs(t, err, ErrShortIPv6Header)

	notIPv6 := append([]byte(nil), packet...)
	notIPv6[0] = 0x45
	_, _, err = parseIPv6(notIPv6)
	assert.ErrorIs(t, err, ErrNotIPv6)
}

func TestProcessEthernetFrameIPv6TCPReply(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		flags     uint8
		available bool
		wantErr   error
	}{
		{
			name:      "syn ack",
			flags:     synFlag | ackFlag,
			available: true,
		},
		{
			name:      "rst",
			flags:     rstFlag,
			available: false,
			wantErr:   ErrPortClosed,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			local := net.ParseIP("2001:db8::10")
			remote := net.ParseIP("2001:db8::20")
			ourSrc := uint16(40000)
			targetPort := uint16(443)
			key := net.JoinHostPort(remote.String(), "443")

			resultCh := make(chan models.Result, 1)
			scanner := &SYNScanner{
				portTargetMap: map[uint16]string{ourSrc: key},
				targetPorts:   map[string][]uint16{key: []uint16{ourSrc}},
				targetIP:      map[string]string{key: remote.String()},
				results: map[string]models.Result{key: {
					Target:    models.Target{Host: remote.String(), Port: int(targetPort), Mode: models.ModeTCP},
					FirstSeen: time.Now(),
					LastSeen:  time.Now(),
				}},
				portAlloc: NewPortAllocator(ourSrc, ourSrc),
				logger:    logger.NewTestLogger(),
			}
			scanner.resultCallback = func(result models.Result) {
				resultCh <- result
			}

			scanner.processEthernetFrame(buildTCPReplyFrameIPv6(local, remote, ourSrc, targetPort, tt.flags))

			select {
			case result := <-resultCh:
				assert.Equal(t, tt.available, result.Available)
				if tt.wantErr != nil {
					assert.ErrorIs(t, result.Error, tt.wantErr)
				} else {
					assert.NoError(t, result.Error)
				}
			case <-time.After(time.Second):
				t.Fatal("timed out waiting for IPv6 TCP reply result")
			}
		})
	}
}

func TestProcessEthernetFrameIPv6IgnoresWrongSource(t *testing.T) {
	t.Parallel()

	local := net.ParseIP("2001:db8::10")
	remote := net.ParseIP("2001:db8::20")
	wrongRemote := net.ParseIP("2001:db8::21")
	ourSrc := uint16(40000)
	targetPort := uint16(443)
	key := net.JoinHostPort(remote.String(), "443")

	resultCh := make(chan models.Result, 1)
	scanner := &SYNScanner{
		portTargetMap: map[uint16]string{ourSrc: key},
		targetPorts:   map[string][]uint16{key: []uint16{ourSrc}},
		targetIP:      map[string]string{key: remote.String()},
		results: map[string]models.Result{key: {
			Target:    models.Target{Host: remote.String(), Port: int(targetPort), Mode: models.ModeTCP},
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}},
		portAlloc: NewPortAllocator(ourSrc, ourSrc),
		logger:    logger.NewTestLogger(),
	}
	scanner.resultCallback = func(result models.Result) {
		resultCh <- result
	}

	scanner.processEthernetFrame(buildTCPReplyFrameIPv6(local, wrongRemote, ourSrc, targetPort, synFlag|ackFlag))

	select {
	case result := <-resultCh:
		t.Fatalf("unexpected result from wrong IPv6 source: %#v", result)
	case <-time.After(50 * time.Millisecond):
	}
}

func permissionError(err error) bool {
	if err == nil {
		return false
	}

	return errors.Is(err, syscall.EPERM) ||
		errors.Is(err, syscall.EACCES) ||
		strings.Contains(err.Error(), "requires root")
}

func buildTCPReplyFrameIPv6(localIP, remoteIP net.IP, dstPort, srcPort uint16, flags uint8) []byte {
	frame := make([]byte, ethernetHeaderSize+ipv6HeaderSize+tcpHeaderMinSize)
	eth := frame[:ethernetHeaderSize]
	binary.BigEndian.PutUint16(eth[12:], etherTypeIPv6)

	ip := frame[ethernetHeaderSize : ethernetHeaderSize+ipv6HeaderSize]
	ip[0] = 0x60
	binary.BigEndian.PutUint16(ip[4:], tcpHeaderMinSize)
	ip[6] = syscall.IPPROTO_TCP
	ip[7] = defaultTTL
	copy(ip[8:24], remoteIP.To16())
	copy(ip[24:40], localIP.To16())

	tcp := frame[ethernetHeaderSize+ipv6HeaderSize:]
	binary.BigEndian.PutUint16(tcp[0:], srcPort)
	binary.BigEndian.PutUint16(tcp[2:], dstPort)
	binary.BigEndian.PutUint32(tcp[4:], 0xABCDEF01)
	binary.BigEndian.PutUint32(tcp[8:], 0)
	tcp[12] = 5 << 4
	tcp[13] = flags
	binary.BigEndian.PutUint16(tcp[14:], defaultTCPWindow)
	binary.BigEndian.PutUint16(tcp[16:], TCPChecksumIPv6New(remoteIP, localIP, tcp, nil))

	return frame
}

func TestNewSYNScanner(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping SYN scanner test in short mode")
	}

	// Check if running as root
	isRoot := os.Geteuid() == 0
	tests := []struct {
		name        string
		timeout     time.Duration
		concurrency int
		wantTimeout time.Duration
		wantConc    int
	}{
		{
			name:        "default values",
			timeout:     0,
			concurrency: 0,
			wantTimeout: 1 * time.Second,
			wantConc:    256,
		},
		{
			name:        "custom values",
			timeout:     500 * time.Millisecond,
			concurrency: 100,
			wantTimeout: 500 * time.Millisecond,
			wantConc:    100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := logger.NewTestLogger()
			scanner, err := NewSYNScanner(tt.timeout, tt.concurrency, log, nil)

			if err != nil {
				if !isRoot {
					require.Error(t, err)
					assert.Nil(t, scanner)
					t.Logf("SYN scanner correctly failed without root privileges: %v", err)

					return
				}

				if permissionError(err) {
					t.Skipf("Skipping SYN scanner test: raw sockets unavailable (%v)", err)
				}

				require.NoError(t, err)
			}

			assert.NotNil(t, scanner)
			assert.Equal(t, tt.wantTimeout, scanner.timeout)
			assert.Equal(t, tt.wantConc, scanner.concurrency)

			// Clean up
			err = scanner.Stop()
			require.NoError(t, err)
		})
	}
}

func TestSYNScanner_Scan_EmptyTargets(t *testing.T) {
	log := logger.NewTestLogger()

	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log, nil)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer func() {
		if err := scanner.Stop(); err != nil {
			t.Logf("Failed to stop scanner: %v", err)
		}
	}()

	ctx := context.Background()
	targets := []models.Target{}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)
	assert.NotNil(t, results)

	// Should get no results from empty channel
	resultSlice := drainChannel(results)
	assert.Empty(t, resultSlice)
}

func TestSYNScanner_Scan_NonTCPTargets(t *testing.T) {
	log := logger.NewTestLogger()

	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log, nil)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer func() {
		if err := scanner.Stop(); err != nil {
			t.Logf("Failed to stop scanner: %v", err)
		}
	}()

	ctx := context.Background()
	targets := []models.Target{
		{Host: "127.0.0.1", Mode: models.ModeICMP},
		{Host: "127.0.0.1", Mode: models.ModeICMP},
	}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)
	assert.NotNil(t, results)

	// Should get no results since no TCP targets
	resultSlice := drainChannel(results)
	assert.Empty(t, resultSlice)
}

func TestSYNScanner_Scan_TCPTargets(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping SYN scanner test in short mode")
	}

	log := logger.NewTestLogger()

	// Create SYN scanner (may require root)
	scanner, err := NewSYNScanner(1*time.Second, 10, log, nil)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer func() {
		if err := scanner.Stop(); err != nil {
			t.Logf("Failed to stop scanner: %v", err)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	targets := []models.Target{
		{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},   // SSH - likely open
		{Host: "127.0.0.1", Port: 9999, Mode: models.ModeTCP}, // High port - likely closed
		{Host: "127.0.0.1", Mode: models.ModeICMP},            // ICMP - should be filtered out
	}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)
	assert.NotNil(t, results)

	// Should get results for 2 TCP targets only
	resultSlice := drainChannel(results)
	assert.Len(t, resultSlice, 2)

	// Verify both results are for TCP targets
	for _, result := range resultSlice {
		assert.Equal(t, models.ModeTCP, result.Target.Mode)
		assert.Equal(t, "127.0.0.1", result.Target.Host)
		assert.Contains(t, []int{22, 9999}, result.Target.Port)
	}
}

func TestSYNScanner_ConcurrentScanning(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping SYN scanner test in short mode")
	}

	log := logger.NewTestLogger()

	// Create SYN scanner (should work with root)
	scanner, err := NewSYNScanner(100*time.Millisecond, 50, log, nil)
	if err != nil {
		t.Skip("SYN scanner requires root privileges")
		return
	}
	defer func() {
		if err := scanner.Stop(); err != nil {
			t.Logf("Failed to stop scanner: %v", err)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Create many targets to test concurrency
	var targets []models.Target
	for port := 20; port < 50; port++ {
		targets = append(targets, models.Target{
			Host: "127.0.0.1",
			Port: port,
			Mode: models.ModeTCP,
		})
	}

	start := time.Now()
	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	resultSlice := drainChannel(results)
	duration := time.Since(start)

	// Should complete faster than sequential scanning would take
	// With 30 targets and 100ms timeout each, sequential would take 3+ seconds
	// Concurrent should be much faster
	assert.Less(t, duration, 3*time.Second)
	assert.Len(t, resultSlice, len(targets))

	t.Logf("Scanned %d targets in %v (avg: %v per target)",
		len(targets), duration, duration/time.Duration(len(targets)))
}

func TestSYNScanner_ContextCancellation(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping SYN scanner test in short mode")
	}

	log := logger.NewTestLogger()

	// Create SYN scanner with very short timeout for faster cancellation
	scanner, err := NewSYNScanner(100*time.Millisecond, 10, log, nil)
	if err != nil {
		t.Skipf("SYN scanner requires root privileges: %v", err)
		return
	}
	defer func() {
		if err := scanner.Stop(); err != nil {
			t.Logf("Failed to stop scanner: %v", err)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	targets := []models.Target{
		{Host: "192.0.2.1", Port: 80, Mode: models.ModeTCP}, // Test IP that won't respond
	}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	// Cancel context after a short delay to allow scan to start
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()

	// Should complete due to cancellation or timeout
	start := time.Now()
	resultSlice := drainChannel(results)
	duration := time.Since(start)

	assert.Less(t, duration, 1*time.Second) // Should complete quickly due to short timeouts
	// May get 0 or 1 results depending on timing
	assert.LessOrEqual(t, len(resultSlice), 1)
}

// Helper function to drain all results from a channel
func drainChannel(ch <-chan models.Result) []models.Result {
	results := make([]models.Result, 0, 100) // Pre-allocate with reasonable capacity
	for result := range ch {
		results = append(results, result)
	}

	return results
}
