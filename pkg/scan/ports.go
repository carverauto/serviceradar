package scan

import (
	"context"
	"errors"
	"runtime"
	"sync/atomic"
	"time"
)

// PortAllocator hands out ephemeral TCP source ports without reuse until Release.
// It is MPMC and lock-free: selection uses a round-robin cursor and each slot
// has an atomic state flag (0=free, 1=reserved).
type PortAllocator struct {
	start uint16
	end   uint16
	cnt   uint32 // total ports (inclusive)

	cursor atomic.Uint32 // round-robin index used for the next probe

	// one entry per port; index 0 -> start, index cnt-1 -> end
	slots []portSlot
}

type portSlot struct {
	port  uint16
	state atomic.Uint32 // 0=free, 1=used
}

var (
	ErrNoPorts     = errors.New("no ports available")
	errCtxDone     = errors.New("context canceled")
	spinMaxBackoff = 200 * time.Microsecond
)

// NewPortAllocator builds an allocator for [start, end] inclusive.
// Panics if start > end or range size is 0.
func NewPortAllocator(start, end uint16) *PortAllocator {
	if start == 0 || end == 0 || start > end {
		panic("NewPortAllocator: invalid port range")
	}

	cnt := uint32(end - start + 1)
	slots := make([]portSlot, cnt)

	for i := uint32(0); i < cnt; i++ {
		slots[i].port = uint16(uint32(start) + i)
	}

	a := &PortAllocator{
		start: start,
		end:   end,
		cnt:   cnt,
		slots: slots,
	}

	// seed cursor with randomish value derived from GOMAXPROCS
	a.cursor.Store(uint32(runtime.GOMAXPROCS(0)) * 997)

	return a
}

// Reserve attempts to obtain one free port. It spins up to cnt fast attempts,
// then backs off briefly; repeats until success or ctx is done.
func (a *PortAllocator) Reserve(ctx context.Context) (uint16, error) {
	if a.cnt == 0 {
		return 0, ErrNoPorts
	}

	// Fast path: one pass over the ring starting at a cursor
	tryOnce := func() (uint16, bool) {
		startIdx := a.cursor.Add(1) - 1

		for i := uint32(0); i < a.cnt; i++ {
			idx := (startIdx + i) % a.cnt
			s := &a.slots[idx]

			// Claim if free
			if s.state.CompareAndSwap(0, 1) {
				return s.port, true
			}
		}

		return 0, false
	}

	// Loop with tiny backoff on full contention
	backoff := time.Microsecond

	for {
		if p, ok := tryOnce(); ok {
			return p, nil
		}

		// nothing free right now
		if ctx != nil {
			select {
			case <-ctx.Done():
				return 0, errCtxDone
			default:
			}
		}

		time.Sleep(backoff)
		if backoff < spinMaxBackoff {
			backoff *= 2
		}
	}
}

// Release marks a port free again. It’s safe to call multiple times.
func (a *PortAllocator) Release(port uint16) {
	if port < a.start || port > a.end {
		return
	}

	idx := uint32(port - a.start)
	a.slots[idx].state.Store(0)
}

// Available is a heuristic count of currently free ports (O(n)).
func (a *PortAllocator) Available() int {
	free := 0

	for i := range a.slots {
		if a.slots[i].state.Load() == 0 {
			free++
		}
	}

	return free
}
