package scan

import (
    "context"
    "errors"
    "os"
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

    // freeCount tracks how many ports are currently free to avoid O(n)
    // scans when fully saturated. It is updated on successful Reserve/Release.
    freeCount atomic.Uint32

    // ports is a buffered channel holding currently-free ports. This becomes
    // the primary fast path for Reserve/Release under contention, avoiding
    // full-ring CAS scans.
    ports chan uint16
}

type portSlot struct {
	port  uint16
	state atomic.Uint32 // 0=free, 1=used
}

var (
	ErrNoPorts = errors.New("no ports available")
	errCtxDone = errors.New("context canceled")
)

const (
	// Allow the allocator to back off to a few milliseconds when fully saturated.
	spinMaxBackoff = 5 * time.Millisecond
	cursorSeed     = 997 // prime number for cursor initialization
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
		// Safe conversion: start + i is guaranteed to fit in uint16 since
		// cnt = end - start + 1, and both start and end are uint16 values
		// #nosec G115 - conversion is safe within port range
		slots[i].port = start + uint16(i)
	}

    a := &PortAllocator{
        start: start,
        end:   end,
        cnt:   cnt,
        slots: slots,
    }

    // Initially, all ports are free
    a.freeCount.Store(cnt)

    // Mode control via env: SR_PORT_ALLOCATOR=cas|chan (default: chan)
    mode := os.Getenv("SR_PORT_ALLOCATOR")
    if mode == "cas" {
        // CAS mode: do not create channel; Reserve will use CAS scan.
        a.ports = nil
    } else {
        // Channel mode (default)
        a.ports = make(chan uint16, cnt)
        for i := uint32(0); i < cnt; i++ {
            // enqueue all ports as free
            a.ports <- (start + uint16(i))
        }
    }

	// seed cursor with randomish value derived from GOMAXPROCS
	gomaxprocs := runtime.GOMAXPROCS(0)
	if gomaxprocs < 0 {
		gomaxprocs = 1
	}

	a.cursor.Store(uint32(gomaxprocs) * cursorSeed) // #nosec G115 - GOMAXPROCS is always positive

	return a
}

// Reserve attempts to obtain one free port. It spins up to cnt fast attempts,
// then backs off briefly; repeats until success or ctx is done.
func (a *PortAllocator) Reserve(ctx context.Context) (uint16, error) {
    if a.cnt == 0 {
        return 0, ErrNoPorts
    }

    // If channel mode is disabled, use CAS scan
    if a.ports == nil {
        tryOnce := func() (uint16, bool) {
            startIdx := a.cursor.Add(1) - 1
            for i := uint32(0); i < a.cnt; i++ {
                idx := (startIdx + i) % a.cnt
                s := &a.slots[idx]
                if s.state.CompareAndSwap(0, 1) {
                    a.freeCount.Add(^uint32(0)) // -1
                    return s.port, true
                }
            }
            return 0, false
        }

        backoff := time.Microsecond
        for {
            if p, ok := tryOnce(); ok {
                return p, nil
            }
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

    // Channel mode
    for {
        select {
        case p := <-a.ports:
            // Mark slot as used; guard against any accidental duplicates
            idx := uint32(p - a.start)
            if a.slots[idx].state.Swap(1) == 0 {
                a.freeCount.Add(^uint32(0)) // -1
                return p, nil
            }
            // If it was already 1, get another port
        case <-ctx.Done():
            return 0, errCtxDone
        }
    }
}

// Release marks a port free again. It’s safe to call multiple times.
func (a *PortAllocator) Release(port uint16) {
    if port < a.start || port > a.end {
        return
    }

    idx := uint32(port - a.start)
    // Only increment freeCount if we actually transitioned from used->free
    if a.slots[idx].state.Swap(0) == 1 {
        a.freeCount.Add(1)
        // Return to free list; non-blocking because capacity == cnt
        select {
        case a.ports <- port:
        default:
            // Should not happen; as a safety, drop silently to avoid blocking
        }
    }
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

// Free returns a fast, approximate count of free ports using the atomic
// counter. It does not scan the slots and is safe for concurrent use.
func (a *PortAllocator) Free() int {
    return int(a.freeCount.Load())
}
