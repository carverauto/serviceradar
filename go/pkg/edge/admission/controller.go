/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package admission is the scanner byte-pressure controller: it gates how much
// unresolved result state the agent may hold, connecting scanner admission to
// spool/network pressure. It reserves worst-case bytes per target window before
// scanning it, caps active result state by bytes, applies high/low-water
// hysteresis so bulk work pauses and only resumes after real relief, stops all
// non-recovery admission at hard-full, and reserves unborrowable floors so an
// interactive probe or a recovery/control frame is never starved by a large
// bulk sweep. This is the decision core of task 2.6; it holds no I/O.
package admission

import (
	"errors"
	"fmt"
	"sync"
)

// Class is a traffic class competing for the shared byte budget.
type Class uint8

const (
	// ClassBulk is large sweep/MTR result traffic; it pauses first under pressure
	// and may consume only the budget left after the interactive and recovery
	// reserves.
	ClassBulk Class = iota
	// ClassInteractive is latency-sensitive ad-hoc/on-demand traffic; it has an
	// unborrowable reserve that bulk can never occupy.
	ClassInteractive
	// ClassRecovery is loss-manifest/rollover/control traffic; it has the
	// minimum-free floor and may use the whole capacity in extremis.
	ClassRecovery
)

// Decision is the outcome of a reservation request.
type Decision uint8

const (
	// Admit means the bytes were reserved; the caller owns them until Commit or
	// Release.
	Admit Decision = iota
	// Defer means there is no room now but the request may succeed later (bulk
	// paused by hysteresis, or the class budget is momentarily full). The caller
	// should retry after relief; it must not treat the target as failed.
	Defer
	// Reject means the request cannot be satisfied at this capacity (it exceeds a
	// hard ceiling even when empty).
	Reject
)

// Limits configures the byte budget. Capacity is the hard ceiling across every
// lane. HighWater/LowWater drive bulk hysteresis and must satisfy
// LowWater < HighWater <= Capacity. InteractiveReserve and RecoveryReserve are
// unborrowable floors carved out of Capacity for their classes.
type Limits struct {
	Capacity           uint64
	HighWater          uint64
	LowWater           uint64
	InteractiveReserve uint64
	RecoveryReserve    uint64
}

// ErrInvalidLimits is returned by New when the limits are inconsistent.
var ErrInvalidLimits = errors.New("admission: invalid limits")

// ErrReservationConsumed is returned when a reservation is committed or released
// more than once.
var ErrReservationConsumed = errors.New("admission: reservation already consumed")

// ErrOverCommit is returned when a commit reports more bytes than were reserved.
// Allowing it would let committed bytes exceed the capacity the controller
// promised to enforce.
var ErrOverCommit = errors.New("admission: commit exceeds reserved bytes")

// Reservation is an opaque handle to admitted-but-not-yet-committed bytes. It
// records the class and the exact byte amount reserved, and may be committed or
// released exactly once. Callers must not fabricate one; only Reserve returns a
// valid handle.
type Reservation struct {
	class    Class
	bytes    uint64
	consumed bool
}

// Bytes reports how many bytes this reservation holds.
func (r *Reservation) Bytes() uint64 { return r.bytes }

// Controller tracks reserved and committed unresolved bytes and makes
// class-aware admission decisions. Safe for concurrent use.
type Controller struct {
	mu         sync.Mutex
	lim        Limits
	reserved   uint64
	used       uint64
	bulkPaused bool
}

// New validates the limits and returns a controller.
func New(lim Limits) (*Controller, error) {
	if lim.Capacity == 0 || lim.HighWater > lim.Capacity || lim.LowWater >= lim.HighWater {
		return nil, ErrInvalidLimits
	}
	if lim.InteractiveReserve+lim.RecoveryReserve > lim.Capacity {
		return nil, ErrInvalidLimits
	}
	return &Controller{lim: lim}, nil
}

// Reserve requests bytes for a class. On Admit it returns a Reservation holding
// exactly those bytes against the budget; the caller must later Commit (once
// durably spooled) or Release (if the window is abandoned) that handle. On Defer
// or Reject it returns a nil Reservation.
func (c *Controller) Reserve(class Class, bytes uint64) (*Reservation, Decision) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.updateHysteresisLocked()

	total := c.reserved + c.used
	switch class {
	case ClassRecovery:
		// Recovery may draw on the whole capacity, including other reserves.
		if bytes > c.lim.Capacity {
			return nil, Reject
		}
		if total+bytes > c.lim.Capacity {
			return nil, Defer
		}
	case ClassInteractive:
		// Interactive may use everything except the recovery floor.
		budget := c.lim.Capacity - c.lim.RecoveryReserve
		if bytes > budget {
			return nil, Reject
		}
		if total+bytes > budget {
			return nil, Defer
		}
	case ClassBulk:
		// Bulk may use only what is left after both floors, and is paused by
		// hysteresis until pressure relaxes.
		budget := c.lim.Capacity - c.lim.RecoveryReserve - c.lim.InteractiveReserve
		if bytes > budget {
			return nil, Reject
		}
		if c.bulkPaused || total+bytes > budget {
			return nil, Defer
		}
	default:
		return nil, Reject
	}

	c.reserved += bytes
	c.updateHysteresisLocked()
	return &Reservation{class: class, bytes: bytes}, Admit
}

// Commit converts a reservation into committed (durably spooled, not yet
// resolved) bytes. actualBytes is the real encoded size and MUST NOT exceed the
// reserved amount, so committed bytes can never breach the reserved budget. Any
// reserved bytes beyond actualBytes are released. A reservation may be committed
// or released only once.
func (c *Controller) Commit(r *Reservation, actualBytes uint64) error {
	if r == nil {
		return ErrReservationConsumed
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if r.consumed {
		return ErrReservationConsumed
	}
	if actualBytes > r.bytes {
		return fmt.Errorf("%w: committed %d > reserved %d", ErrOverCommit, actualBytes, r.bytes)
	}
	r.consumed = true
	c.reserved = satSub(c.reserved, r.bytes)
	c.used += actualBytes
	c.updateHysteresisLocked()
	return nil
}

// Release returns a reservation's bytes for a window that was never spooled. A
// reservation may be committed or released only once.
func (c *Controller) Release(r *Reservation) error {
	if r == nil {
		return ErrReservationConsumed
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if r.consumed {
		return ErrReservationConsumed
	}
	r.consumed = true
	c.reserved = satSub(c.reserved, r.bytes)
	c.updateHysteresisLocked()
	return nil
}

// Resolve frees committed bytes once their frames are durably resolved by the
// gateway (spool watermark advanced).
func (c *Controller) Resolve(bytes uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.used = satSub(c.used, bytes)
	c.updateHysteresisLocked()
}

// BulkPaused reports whether bulk admission is currently paused by hysteresis.
func (c *Controller) BulkPaused() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bulkPaused
}

// Pressure returns the fraction of capacity currently held (reserved+committed).
func (c *Controller) Pressure() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return float64(c.reserved+c.used) / float64(c.lim.Capacity)
}

// InUse returns reserved and committed bytes.
func (c *Controller) InUse() (reserved, used uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reserved, c.used
}

func (c *Controller) updateHysteresisLocked() {
	total := c.reserved + c.used
	if !c.bulkPaused && total >= c.lim.HighWater {
		c.bulkPaused = true
	} else if c.bulkPaused && total <= c.lim.LowWater {
		c.bulkPaused = false
	}
}

func satSub(a, b uint64) uint64 {
	if b >= a {
		return 0
	}
	return a - b
}
