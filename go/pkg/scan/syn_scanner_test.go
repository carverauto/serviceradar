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
	"math/rand/v2"
	"net"
	"os"
	"strings"
	"sync/atomic"
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
	require.ErrorIs(t, err, ErrShortIPv6Header)

	notIPv6 := append([]byte(nil), packet...)
	notIPv6[0] = 0x45
	_, _, err = parseIPv6(notIPv6)
	require.ErrorIs(t, err, ErrNotIPv6)
}

func TestSYNScannerCapabilitiesReportRawIPv6Disabled(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{
		sendSocket: 42,
		sourceIP:   net.IPv4(192, 0, 2, 10),
	}

	caps := scanner.Capabilities()
	assert.True(t, caps.RawSYNIPv4)
	assert.False(t, caps.RawSYNIPv6)
	assert.Contains(t, caps.Diagnostics["raw_syn_ipv6"], "unavailable")
}

func TestSYNScannerCapabilitiesReportRawIPv6Enabled(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{
		sendSocket6: 43,
		sourceIP6:   net.ParseIP("2001:db8::10"),
	}

	caps := scanner.Capabilities()
	assert.False(t, caps.RawSYNIPv4)
	assert.True(t, caps.RawSYNIPv6)
	assert.Equal(t, "enabled", caps.Diagnostics["raw_syn_ipv6"])
}

func TestSYNScannerUsesDistinctFanoutGroups(t *testing.T) {
	log := logger.NewTestLogger()
	opts := &SYNScannerOptions{
		RouteDiscoveryHost: "127.0.0.1:9",
		RingReaders:        2,
		GlobalRingMemoryMB: 4,
	}

	first, err := NewSYNScanner(100*time.Millisecond, 1, log, opts)
	if permissionError(err) {
		t.Skipf("SYN scanning unavailable without packet socket privileges: %v", err)
	}
	require.NoError(t, err)
	require.NotNil(t, first)
	t.Cleanup(func() {
		require.NoError(t, first.Stop())
	})

	second, err := NewSYNScanner(100*time.Millisecond, 1, log, opts)
	require.NoError(t, err)
	require.NotNil(t, second)
	t.Cleanup(func() {
		require.NoError(t, second.Stop())
	})

	assert.NotEqual(t, first.fanoutGroup, second.fanoutGroup,
		"independent scanners must not load-balance each other's replies")
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
					require.ErrorIs(t, result.Error, tt.wantErr)
				} else {
					require.NoError(t, result.Error)
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

func TestProcessEthernetFrameIPv6IgnoresReusedSourcePortWrongTargetPort(t *testing.T) {
	t.Parallel()

	local := net.ParseIP("2001:db8::10")
	remote := net.ParseIP("2001:db8::20")
	ourSrc := uint16(40000)
	staleReplyPort := uint16(80)
	key := net.JoinHostPort(remote.String(), "443")

	resultCh := make(chan models.Result, 1)
	scanner := newTestSYNScannerForIPv6Reply(key, remote.String(), resultCh)

	scanner.processEthernetFrame(buildTCPReplyFrameIPv6(local, remote, ourSrc, staleReplyPort, synFlag|ackFlag))

	select {
	case result := <-resultCh:
		t.Fatalf("unexpected result from reused source port with wrong target port: %#v", result)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestProcessEthernetFrameICMPv6Errors(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		icmpTyp uint8
		wantErr error
	}{
		{name: "destination unreachable", icmpTyp: icmpv6DstUnreach, wantErr: ErrPortClosed},
		{name: "packet too big", icmpTyp: icmpv6PacketTooBig, wantErr: ErrICMPv6PacketTooBig},
		{name: "time exceeded", icmpTyp: icmpv6TimeExceeded, wantErr: ErrICMPv6TimeExceeded},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			local := net.ParseIP("2001:db8::10")
			remote := net.ParseIP("2001:db8::20")
			router := net.ParseIP("2001:db8::1")
			ourSrc := uint16(40000)
			targetPort := uint16(443)
			key := net.JoinHostPort(remote.String(), "443")

			resultCh := make(chan models.Result, 1)
			scanner := newTestSYNScannerForIPv6Reply(key, remote.String(), resultCh)

			scanner.processEthernetFrame(buildICMPv6ErrorFrame(local, remote, router, ourSrc, targetPort, tt.icmpTyp))

			select {
			case result := <-resultCh:
				assert.False(t, result.Available)
				require.ErrorIs(t, result.Error, tt.wantErr)
			case <-time.After(time.Second):
				t.Fatal("timed out waiting for ICMPv6 error result")
			}
		})
	}
}

func TestProcessEthernetFrameICMPv6IgnoresWrongEmbeddedTarget(t *testing.T) {
	t.Parallel()

	local := net.ParseIP("2001:db8::10")
	remote := net.ParseIP("2001:db8::20")
	wrongRemote := net.ParseIP("2001:db8::21")
	router := net.ParseIP("2001:db8::1")
	ourSrc := uint16(40000)
	targetPort := uint16(443)
	key := net.JoinHostPort(remote.String(), "443")

	resultCh := make(chan models.Result, 1)
	scanner := newTestSYNScannerForIPv6Reply(key, remote.String(), resultCh)

	scanner.processEthernetFrame(buildICMPv6ErrorFrame(local, wrongRemote, router, ourSrc, targetPort, icmpv6DstUnreach))

	select {
	case result := <-resultCh:
		t.Fatalf("unexpected result from wrong embedded IPv6 target: %#v", result)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestScanStreamBatchedKeepsTargetBatchesBounded(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	targets := make(chan models.Target)

	var batches [][]models.Target
	scanBatch := func(_ context.Context, batch []models.Target) (<-chan models.Result, error) {
		copied := append([]models.Target(nil), batch...)
		batches = append(batches, copied)

		results := make(chan models.Result, len(batch))
		for _, target := range batch {
			results <- models.Result{Target: target}
		}
		close(results)

		return results, nil
	}

	resultCh, errCh, err := scanStreamBatched(ctx, targets, StreamOptions{BatchSize: 2}, scanBatch)
	require.NoError(t, err)

	go func() {
		defer close(targets)

		targets <- models.Target{Host: "2001:db8::1", Port: 22, Mode: models.ModeTCP}
		targets <- models.Target{Host: "2001:db8::2", Port: 22, Mode: models.ModeICMP}
		targets <- models.Target{Host: "2001:db8::3", Port: 443, Mode: models.ModeTCP}
		targets <- models.Target{Host: "2001:db8::4", Port: 8443, Mode: models.ModeTCP}
		targets <- models.Target{Host: "2001:db8::5", Port: 3389, Mode: models.ModeTCP}
		targets <- models.Target{Host: "2001:db8::6", Port: 8080, Mode: models.ModeTCP}
	}()

	var got []models.Result
	for result := range resultCh {
		got = append(got, result)
	}

	require.Len(t, batches, 3)
	assert.Len(t, batches[0], 2)
	assert.Len(t, batches[1], 2)
	assert.Len(t, batches[2], 1)
	assert.Len(t, got, 5)

	for _, batch := range batches {
		assert.LessOrEqual(t, len(batch), 2)
		for _, target := range batch {
			assert.Equal(t, models.ModeTCP, target.Mode)
		}
	}

	select {
	case err := <-errCh:
		require.NoError(t, err)
	default:
	}
}

func TestProcessEthernetFrameICMPv6IgnoresWrongEmbeddedTargetPort(t *testing.T) {
	t.Parallel()

	local := net.ParseIP("2001:db8::10")
	remote := net.ParseIP("2001:db8::20")
	router := net.ParseIP("2001:db8::1")
	ourSrc := uint16(40000)
	staleTargetPort := uint16(80)
	key := net.JoinHostPort(remote.String(), "443")

	resultCh := make(chan models.Result, 1)
	scanner := newTestSYNScannerForIPv6Reply(key, remote.String(), resultCh)

	scanner.processEthernetFrame(buildICMPv6ErrorFrame(local, remote, router, ourSrc, staleTargetPort, icmpv6DstUnreach))

	select {
	case result := <-resultCh:
		t.Fatalf("unexpected ICMPv6 result from reused source port with wrong target port: %#v", result)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestSYNScannerRetryAndRateMetricAccounting(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{
		retryAttempts:  3,
		retryMinJitter: time.Millisecond,
		retryMaxJitter: time.Millisecond,
		retryCh:        make(chan retryItem, 8),
		rand:           rand.New(rand.NewPCG(1, 2)),
	}

	scanner.enqueueRetriesForBatch([]models.Target{
		{Host: "2001:db8::20", Port: 443, Mode: models.ModeTCP},
	})
	scanner.recordRateLimitWait(25 * time.Millisecond)
	scanner.recordSourcePortWait(10 * time.Millisecond)

	stats := scanner.GetStats()
	assert.Equal(t, uint64(0), stats.RetriesAttempted)
	assert.Len(t, scanner.retryCh, 2)
	assert.Equal(t, uint64(0), stats.RetriesDropped)
	assert.Equal(t, uint64(2), stats.RateLimitDeferrals)
	assert.Equal(t, uint64(1), stats.RateLimitWaits)
	assert.Equal(t, uint64(1), stats.SourcePortWaits)
	assert.Equal(t, uint64(25*time.Millisecond), stats.RateLimitWaitNanos)
	assert.Equal(t, uint64(10*time.Millisecond), stats.SourcePortWaitNanos)
}

func TestSYNScannerRateLimiterAllowsDisabledAndLowRateShards(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{concurrency: 64}
	scanner.SetRateLimit(0, 0)
	assert.Equal(t, 10, scanner.allowN(10))
	scanner.SetRateLimit(10, 10)
	scanner.SetRateLimit(0, 0)
	assert.Equal(t, 10, scanner.allowN(10))

	limiter := newShardedTokenBucket(64, 1, 1)
	require.Len(t, limiter.buckets, 64)
	for _, bucket := range limiter.buckets {
		require.NotNil(t, bucket)
	}

	for i := 0; i < 128; i++ {
		assert.GreaterOrEqual(t, limiter.AllowN(1), 0)
	}
}

func TestSYNScannerRetryAccountingCountsDroppedEnqueues(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{
		retryAttempts:  3,
		retryMinJitter: time.Millisecond,
		retryMaxJitter: time.Millisecond,
		retryCh:        make(chan retryItem, 1),
		rand:           rand.New(rand.NewPCG(1, 2)),
	}

	scanner.enqueueRetriesForBatch([]models.Target{
		{Host: "2001:db8::20", Port: 443, Mode: models.ModeTCP},
	})

	stats := scanner.GetStats()
	assert.Equal(t, uint64(0), stats.RetriesAttempted)
	assert.Equal(t, uint64(1), stats.RetriesDropped)
	assert.Len(t, scanner.retryCh, 1)
}

func TestSYNScannerScanResetsStatsAtStart(t *testing.T) {
	t.Parallel()

	scanner := &SYNScanner{
		timeout:       10 * time.Millisecond,
		concurrency:   1,
		logger:        logger.NewTestLogger(),
		sendBatchSize: defaultSendBatchSize,
		portAlloc:     NewPortAllocator(40000, 40001),
		rand:          rand.New(rand.NewPCG(1, 2)),
	}
	scanner.SetRateLimit(0, 0)

	atomic.StoreUint64(&scanner.stats.PacketsSent, 99)
	atomic.StoreUint64(&scanner.stats.PacketsRecv, 88)
	atomic.StoreUint64(&scanner.stats.RetriesAttempted, 77)
	atomic.StoreUint64(&scanner.stats.DialsStarted, 66)
	atomic.StoreUint64(&scanner.stats.MaxQueueDepth, 55)
	atomic.StoreInt64(&scanner.stats.LastStatsReset, 1)

	results, err := scanner.Scan(context.Background(), []models.Target{
		{Host: "127.0.0.1", Port: 1, Mode: models.ModeTCP},
	})
	require.NoError(t, err)
	_ = drainChannel(results)

	stats := scanner.GetStats()
	assert.Zero(t, stats.PacketsSent)
	assert.Zero(t, stats.PacketsRecv)
	assert.Zero(t, stats.RetriesAttempted)
	assert.Zero(t, stats.DialsStarted)
	assert.Zero(t, stats.MaxQueueDepth)
	assert.Greater(t, stats.LastStatsReset, int64(1))
}

func TestSYNScannerRunRingReaderPersistsCursor(t *testing.T) {
	t.Parallel()

	const (
		blockSize = 64
		blockNr   = 3
	)

	scanner := &SYNScanner{
		ringPollTimeoutMs: 1,
		logger:            logger.NewTestLogger(),
	}
	ring := &ringBuf{
		fd:        -1,
		mem:       make([]byte, blockSize*blockNr),
		blockSize: blockSize,
		blockNr:   blockNr,
		cursor:    1,
	}

	markRingBlockReady(t, ring, 1)
	runSyntheticRingReaderUntil(t, scanner, ring, func() bool {
		return atomic.LoadUint32(&ring.cursor) == 2 &&
			atomic.LoadUint64(&scanner.stats.RingBlocksProcessed) == 1 &&
			loadU32(ring.block(1), h1_status_off)&tpStatusUser == 0
	})

	markRingBlockReady(t, ring, 2)
	runSyntheticRingReaderUntil(t, scanner, ring, func() bool {
		return atomic.LoadUint32(&ring.cursor) == 0 &&
			atomic.LoadUint64(&scanner.stats.RingBlocksProcessed) == 2 &&
			loadU32(ring.block(2), h1_status_off)&tpStatusUser == 0
	})
}

func markRingBlockReady(t *testing.T, ring *ringBuf, idx uint32) {
	t.Helper()

	blk := ring.block(idx)
	require.NotNil(t, blk)
	require.GreaterOrEqual(t, len(blk), int(h1_first_pkt_off+uint32Size))

	storeU32(blk, h1_status_off, tpStatusUser)
	hostEndian.PutUint32(blk[h1_num_pkts_off:h1_num_pkts_off+uint32Size], 0)
	hostEndian.PutUint32(blk[h1_first_pkt_off:h1_first_pkt_off+uint32Size], h1_first_pkt_off+uint32Size)
}

func runSyntheticRingReaderUntil(t *testing.T, scanner *SYNScanner, ring *ringBuf, ready func() bool) {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		defer close(done)
		scanner.runRingReader(ctx, ring)
	}()

	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for synthetic ring reader to stop")
		}
	}()

	require.Eventually(t, ready, time.Second, 10*time.Millisecond)
}

func newTestSYNScannerForIPv6Reply(
	key string,
	targetIP string,
	resultCh chan<- models.Result,
) *SYNScanner {
	const (
		ourSrc     uint16 = 40000
		targetPort uint16 = 443
	)

	scanner := &SYNScanner{
		portTargetMap: map[uint16]string{ourSrc: key},
		targetPorts:   map[string][]uint16{key: []uint16{ourSrc}},
		targetIP:      map[string]string{key: targetIP},
		results: map[string]models.Result{key: {
			Target:    models.Target{Host: targetIP, Port: int(targetPort), Mode: models.ModeTCP},
			FirstSeen: time.Now(),
			LastSeen:  time.Now(),
		}},
		portAlloc: NewPortAllocator(ourSrc, ourSrc),
		logger:    logger.NewTestLogger(),
	}
	scanner.resultCallback = func(result models.Result) {
		resultCh <- result
	}

	return scanner
}

func permissionError(err error) bool {
	if err == nil {
		return false
	}

	return errors.Is(err, syscall.EPERM) ||
		errors.Is(err, syscall.EACCES) ||
		strings.Contains(err.Error(), "requires root")
}

func buildICMPv6ErrorFrame(localIP, remoteIP, routerIP net.IP, srcPort, dstPort uint16, icmpType uint8) []byte {
	embedded := buildSYNPacketIPv6(localIP, remoteIP, srcPort, dstPort, 0x10203040)
	frame := make([]byte, ethernetHeaderSize+ipv6HeaderSize+icmpv6HeaderSize+len(embedded))

	eth := frame[:ethernetHeaderSize]
	binary.BigEndian.PutUint16(eth[12:], etherTypeIPv6)

	ip := frame[ethernetHeaderSize : ethernetHeaderSize+ipv6HeaderSize]
	ip[0] = 0x60
	binary.BigEndian.PutUint16(ip[4:], uint16(icmpv6HeaderSize+len(embedded)))
	ip[6] = ipProtoICMPv6
	ip[7] = defaultTTL
	copy(ip[8:24], routerIP.To16())
	copy(ip[24:40], localIP.To16())

	icmp := frame[ethernetHeaderSize+ipv6HeaderSize:]
	icmp[0] = icmpType
	copy(icmp[icmpv6HeaderSize:], embedded)

	return frame
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
