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
	"math/rand/v2"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unsafe"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// loopbackScanTarget takes the scanner's connect() path, so these scans need
// no raw sockets; port 1 refuses at once.
func loopbackScanTarget() []models.Target {
	return []models.Target{{Host: "127.0.0.1", Port: 1, Mode: models.ModeTCP}}
}

func newGatedTestScanner(gate *scanGate) *SYNScanner {
	scanner := &SYNScanner{
		// The teardown waits timeout/4 (at most 200ms) for late replies, which
		// is the window in which a scan is still listening.
		timeout:       800 * time.Millisecond,
		concurrency:   1,
		logger:        logger.NewTestLogger(),
		sendBatchSize: defaultSendBatchSize,
		portAlloc:     NewPortAllocator(40000, 40001),
		rand:          rand.New(rand.NewPCG(1, 2)),
		gate:          gate,
	}
	scanner.SetRateLimit(0, 0)

	return scanner
}

func TestScanGateAdmitsOneScanAtATime(t *testing.T) {
	t.Parallel()

	gate := newScanGate()
	require.NoError(t, gate.acquire(context.Background()))

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	require.ErrorIs(t, gate.acquire(ctx), context.DeadlineExceeded)

	gate.release()
	require.NoError(t, gate.acquire(context.Background()))
	gate.release()
}

func TestScanGateRefusesACancelledContextEvenWhenFree(t *testing.T) {
	t.Parallel()

	gate := newScanGate()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	require.ErrorIs(t, gate.acquire(ctx), context.Canceled)

	// The refusal took nothing, so the gate is still free.
	freeCtx, freeCancel := context.WithTimeout(context.Background(), time.Second)
	defer freeCancel()
	require.NoError(t, gate.acquire(freeCtx))
	gate.release()
}

func TestSYNScannerScanWaitsForTheScanAheadOfIt(t *testing.T) {
	t.Parallel()

	gate := newScanGate()
	scanner := newGatedTestScanner(gate)

	// Another scanner's scan holds the gate.
	require.NoError(t, gate.acquire(context.Background()))

	started := make(chan (<-chan models.Result), 1)

	go func() {
		results, err := scanner.Scan(context.Background(), loopbackScanTarget())
		assert.NoError(t, err)
		started <- results
	}()

	select {
	case <-started:
		t.Fatal("scan started while another scan held the gate")
	case <-time.After(100 * time.Millisecond):
	}

	gate.release()

	var results <-chan models.Result
	select {
	case results = <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("scan did not start after the gate was released")
	}

	require.Len(t, drainChannel(results), 1)

	// The finished scan's teardown hands the gate on.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	require.NoError(t, gate.acquire(ctx))
	gate.release()
}

func TestSYNScannerScanCancelledWhileWaitingTakesNoGate(t *testing.T) {
	t.Parallel()

	gate := newScanGate()
	scanner := newGatedTestScanner(gate)
	require.NoError(t, gate.acquire(context.Background()))

	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)

	go func() {
		results, err := scanner.Scan(ctx, loopbackScanTarget())
		assert.Nil(t, results)
		errCh <- err
	}()

	cancel()

	select {
	case err := <-errCh:
		require.ErrorIs(t, err, context.Canceled)
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled scan did not return")
	}

	gate.release()

	// The cancelled scan neither kept the gate nor marked the scanner busy.
	results, err := scanner.Scan(context.Background(), loopbackScanTarget())
	require.NoError(t, err)
	require.Len(t, drainChannel(results), 1)
}

func TestSYNScannerRingsListenOnlyWhileScanning(t *testing.T) {
	t.Parallel()

	replyFilter, err := buildReplyFilterIPv4(net.IPv4(192, 0, 2, 10), 40000, 40001)
	require.NoError(t, err)
	require.Greater(t, len(replyFilter), len(idleCaptureFilter()))

	// UDP sockets stand in for the packet sockets: they take the same socket
	// filters without needing raw-socket privileges.
	scanner := newGatedTestScanner(newScanGate())
	scanner.replyFilter = replyFilter
	scanner.ringPollTimeoutMs = 1

	ringFDs := make([]int, 0, 2)

	for range 2 {
		fd := newFilterTestSocket(t)
		require.NoError(t, attachSocketFilter(fd, idleCaptureFilter())) // as NewSYNScanner leaves a ring
		ringFDs = append(ringFDs, fd)
		scanner.rings = append(scanner.rings, &ringBuf{fd: fd, mem: make([]byte, 64*2), blockSize: 64, blockNr: 2})
	}

	var (
		mu     sync.Mutex
		during []int
	)

	scanner.SetResultCallback(func(models.Result) {
		mu.Lock()
		defer mu.Unlock()

		for _, fd := range ringFDs {
			during = append(during, attachedFilterLen(t, fd))
		}
	})

	results, err := scanner.Scan(context.Background(), loopbackScanTarget())
	require.NoError(t, err)
	require.Len(t, drainChannel(results), 1)

	mu.Lock()
	assert.Equal(t, []int{len(replyFilter), len(replyFilter)}, during, "rings carry the reply filter mid-scan")
	mu.Unlock()

	for _, fd := range ringFDs {
		assert.Equal(t, len(idleCaptureFilter()), attachedFilterLen(t, fd), "rings are idle again after the scan")
	}
}

func TestRingReleaseReadyBlocksStopsAtTheFirstKernelOwnedBlock(t *testing.T) {
	t.Parallel()

	const (
		blockSize = 64
		blockNr   = 4
	)

	tests := []struct {
		name         string
		cursor       uint32
		ready        []uint32
		wantReleased int
		wantCursor   uint32
	}{
		{name: "releases from the cursor", cursor: 1, ready: []uint32{1, 2}, wantReleased: 2, wantCursor: 3},
		{name: "wraps around the ring", cursor: 3, ready: []uint32{3, 0}, wantReleased: 2, wantCursor: 1},
		{name: "nothing ready", cursor: 2, wantReleased: 0, wantCursor: 2},
		{name: "every block ready", cursor: 0, ready: []uint32{0, 1, 2, 3}, wantReleased: 4, wantCursor: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			ring := &ringBuf{fd: -1, mem: make([]byte, blockSize*blockNr), blockSize: blockSize, blockNr: blockNr, cursor: tt.cursor}
			for _, idx := range tt.ready {
				markRingBlockReady(t, ring, idx)
			}

			assert.Equal(t, tt.wantReleased, ring.releaseReadyBlocks())
			assert.Equal(t, tt.wantCursor, atomic.LoadUint32(&ring.cursor))

			for idx := uint32(0); idx < blockNr; idx++ {
				assert.Zero(t, loadU32(ring.block(idx), h1_status_off)&tpStatusUser, "block %d still held", idx)
			}
		})
	}
}

func TestRingLayoutDefaultsGiveReadersTimeSlack(t *testing.T) {
	t.Parallel()

	layout := computeRingLayout(nil, defaultRingCount, 4096)

	// A block retires on the timer once it is that old, however empty, so the
	// ring holds blockCount retire timeouts of trickling replies before the
	// kernel drops any.
	slack := time.Duration(layout.blockCount) * time.Duration(defaultRetireTovMs) * time.Millisecond
	assert.GreaterOrEqual(t, slack, 600*time.Millisecond)
	assert.Equal(t, uint32(8<<20), layout.blockSize*layout.blockCount, "a ring stays at 8 MiB")
	assert.False(t, layout.adjusted())
}

func TestRingLayoutDefaultsAlignToLargePages(t *testing.T) {
	t.Parallel()

	layout := computeRingLayout(nil, defaultRingCount, 64<<10)

	assert.Zero(t, layout.blockSize%(64<<10))
	assert.Equal(t, uint32(defaultBlockSize), layout.blockSize)
	assert.Equal(t, uint32(defaultBlockCount), layout.blockCount)
}

func TestRingLayoutHonorsConfiguredGeometry(t *testing.T) {
	t.Parallel()

	layout := computeRingLayout(&SYNScannerOptions{RingBlockSize: 1 << 20, RingBlockCount: 8}, defaultRingCount, 4096)

	assert.Equal(t, uint32(1<<20), layout.blockSize)
	assert.Equal(t, uint32(8), layout.blockCount)
	assert.False(t, layout.adjusted())
}

func TestRingLayoutFitsTheGlobalMemoryCap(t *testing.T) {
	t.Parallel()

	layout := computeRingLayout(&SYNScannerOptions{GlobalRingMemoryMB: 8}, 4, 4096)

	assert.Equal(t, uint32(2<<20), layout.perRingBytes)
	assert.Equal(t, uint32(128<<10), layout.blockSize)
	assert.Equal(t, uint32(16), layout.blockCount)
	assert.True(t, layout.adjusted())
}

func TestRingLayoutShrinksABlockThatFillsTheWholeBudget(t *testing.T) {
	t.Parallel()

	done := make(chan ringLayout, 1)

	go func() {
		// One 8 MiB block against a 1 MiB per-ring budget.
		done <- computeRingLayout(&SYNScannerOptions{RingBlockSize: 8 << 20, GlobalRingMemoryMB: 4}, 4, 4096)
	}()

	select {
	case layout := <-done:
		assert.Equal(t, uint32(2), layout.blockCount)
		assert.Equal(t, uint32(512<<10), layout.blockSize)
		assert.LessOrEqual(t, layout.blockSize*layout.blockCount, layout.perRingBytes)
	case <-time.After(5 * time.Second):
		t.Fatal("computeRingLayout did not return")
	}
}

func newFilterTestSocket(t *testing.T) int {
	t.Helper()

	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	require.NoError(t, err)
	t.Cleanup(func() { _ = unix.Close(fd) })

	return fd
}

// attachedFilterLen returns the instruction count of the classic BPF program
// attached to fd; SO_GET_FILTER with a zero length asks for only that.
func attachedFilterLen(t *testing.T, fd int) int {
	t.Helper()

	var optlen uint32

	_, _, errno := unix.Syscall6(unix.SYS_GETSOCKOPT,
		uintptr(fd),
		uintptr(unix.SOL_SOCKET),
		uintptr(unix.SO_GET_FILTER),
		0,
		uintptr(unsafe.Pointer(&optlen)),
		0)
	require.Zero(t, errno, "SO_GET_FILTER")

	return int(optlen)
}
