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
// hysteresis so bulk work pauses and only resumes after real relief (including
// across a restart, which resumes nothing by itself), stops all
// non-recovery admission at hard-full, and reserves unborrowable floors so an
// interactive probe or a recovery/control frame is never starved by a large
// bulk sweep. This is the decision core of task 2.6; it holds no I/O.
//
// # Scope: this package is byte accounting, not durability
//
// It charges bytes to an immutable slot identity and releases them ONLY when the
// durable journal/coverage owner authorizes it. That is the whole boundary.
//
// The corrected defect (task 2.17) was that `Resolve(bytes)` freed committed
// bytes when the GATEWAY resolved them. A gateway PubAck says the gateway holds
// the record; it says nothing about whether the agent durably recorded that
// outcome, so freeing there returns budget while the spool still holds data whose
// fate was never recorded locally. It was also a byte DELTA, which cannot be
// idempotent: an aggregate "free N bytes" cannot distinguish a duplicate
// notification from a second record.
//
// Deliberately NOT here, because these belong to components whose ABI does not
// exist yet:
//
//   - producing the reclaim authorization, and proving it survives a crash --
//     task 2.28. This package consumes an authorization it cannot construct;
//     it does not compute coverage, and it does not verify the claim.
//   - spool generation lifecycle: identity issuance, lane binding, open/sealed
//     rotation, retirement -- task 2.21. SpoolID is an opaque identifier here.
//   - restart classification of a slot over redundant commit evidence (intact
//     evidence, ambiguous allocated slot, discardable preparation) -- task 2.23.
//   - the reserve and allocation capacity primitives -- task 2.26.
//
// Modelling any of those here would mean inventing semantics for an owner that
// does not exist, then having to keep two definitions in numeric agreement.
package admission

import (
	"errors"
	"fmt"
	"math"
	"math/bits"
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
	// paused by hysteresis, the class budget is momentarily full, or the controller
	// has not yet been restored). The caller should retry after relief; it must not
	// treat the target as failed.
	Defer
	// Reject means the request cannot be satisfied at this capacity (it exceeds a
	// hard ceiling even when empty, or it is malformed).
	Reject
)

// SpoolID identifies one spool generation. It is OPAQUE to this package: issuing
// generation identities, binding them to lanes, and retiring them is task 2.21's.
// All this package does with it is keep one generation's accounting from touching
// another's.
type SpoolID string

// SlotKey is the immutable identity a byte charge is bound to.
//
// A bare sequence is not an identity: lanes run concurrently, each with an
// independent sequence space, so two live generations legitimately both hold
// sequence 1. The frozen physical key is
// (network_scope_id, authenticated_agent_id, spool_id, sequence); a controller
// serves one authenticated agent in one network scope, so those two components
// are invariant here and enforced upstream.
type SlotKey struct {
	Spool SpoolID
	Seq   uint64
}

func (k SlotKey) String() string { return fmt.Sprintf("%s/%d", k.Spool, k.Seq) }

// ReclaimAuthorization is the ONLY thing that releases charged bytes.
//
// It is an OPAQUE CARRIER: a struct whose every field is unexported, so no
// package outside this one can build a populated value. Composite literals are
// rejected by the compiler, conversion from a same-shaped struct is rejected
// because non-exported field names in different packages are always distinct,
// and the zero value is refused at the door.
//
// It was an interface sealed by an unexported method, which does NOT work: an
// external type can embed the interface -- a nil one is enough -- to promote the
// sealing method, then override the exported accessors. That forged value passed
// every seal test and released all charged bytes. Calling the sealing method
// would only turn the forgery into a nil-pointer panic, trading a correctness
// hole for a denial of service.
//
// Today there is deliberately NO exported constructor, so no production caller
// can release anything. That is the correct state for a package whose release
// authority belongs to a component that does not exist yet: no signal of any
// kind can reach the release path by accident. When the durable journal/coverage
// owner lands (task 2.28), giving it a way to mint one is a deliberate,
// reviewable act.
//
// Admission does not validate the claim, and cannot: verifying that a terminal
// record reached disk and that a segment is covered requires evidence this
// package never sees. What it does is apply the authorization MONOTONICALLY per
// generation, and do the arithmetic exactly.
type ReclaimAuthorization struct {
	spool   SpoolID
	through uint64
	serial  uint64
}

// valid reports whether the carrier holds a real claim. The zero value -- the
// only value an external package can produce -- is not one.
func (a ReclaimAuthorization) valid() bool { return a.spool != "" && a.serial != 0 }

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

// ErrNotRestored is returned by every state-changing call before a snapshot has
// been installed. A fresh controller does not know what the spool is holding, so
// it must not act as though the answer is zero.
var ErrNotRestored = errors.New("admission: controller has not been restored")

// ErrAlreadyRestored is returned when Restore is called on a live controller.
// Restoration is a STARTUP act: swapping reconstructed state under a running
// controller discards whatever it accepted in the meantime.
var ErrAlreadyRestored = errors.New("admission: controller is already restored")

// ErrReservationConsumed is returned when a reservation is committed or released
// more than once, including through a COPY of the handle.
var ErrReservationConsumed = errors.New("admission: reservation already consumed")

// ErrStaleReservation is returned when a handle issued before a restoration is
// presented after it.
var ErrStaleReservation = errors.New("admission: reservation predates restoration")

// ErrOverCommit is returned when a commit reports more bytes than were reserved.
var ErrOverCommit = errors.New("admission: commit exceeds reserved bytes")

// ErrEmptySlot is returned for a zero-byte reservation or charge. No valid edge
// record is zero bytes, and an uncharged slot would add controller state that
// neither pressure nor capacity can see.
var ErrEmptySlot = errors.New("admission: zero-byte slot")

// ErrEmptySpool is returned for an empty generation identifier.
var ErrEmptySpool = errors.New("admission: empty spool generation id")

// ErrUnknownSpool is returned when an authorization names a generation this
// controller holds no charges for.
var ErrUnknownSpool = errors.New("admission: unknown spool generation")

// ErrUnknownSlot is returned for a slot the controller is not holding.
var ErrUnknownSlot = errors.New("admission: unknown slot")

// ErrDuplicateSlot is returned when a slot identity is charged twice. Charges are
// immutable: a second charge for one identity would mean two records occupy one
// physical slot.
var ErrDuplicateSlot = errors.New("admission: slot is already charged")

// ErrReclaimedSlot is returned when a slot at or below a generation's authorized
// watermark is charged. Its bytes were already released.
var ErrReclaimedSlot = errors.New("admission: slot is at or below the reclaim watermark")

// ErrUnauthorized is returned when the reclaim carrier holds no claim. The zero
// value is the only one an external package can produce, so this is what an
// attempted forgery gets.
var ErrUnauthorized = errors.New("admission: reclaim authorization carries no claim")

// ErrAuthorizationRegression is returned when an authorization would move a
// generation's serial or watermark backwards.
var ErrAuthorizationRegression = errors.New("admission: reclaim authorization must be monotonic")

// ErrForeignReservation is returned when a reservation is presented to a
// controller that did not issue it.
var ErrForeignReservation = errors.New("admission: reservation belongs to another controller")

// ErrOverflow is returned when byte arithmetic would wrap, which would silently
// defeat the hard capacity.
var ErrOverflow = errors.New("admission: byte arithmetic overflow")

// ErrInvalidSnapshot is returned when a restoration snapshot is inconsistent.
var ErrInvalidSnapshot = errors.New("admission: invalid snapshot")

// Reservation is an opaque handle to admitted-but-not-yet-charged bytes.
//
// It deliberately carries NO accounting of its own: only an owner and a token
// naming controller-held state. A Go struct is copyable and there is no way to
// stop `cp := *r`, so any consumption flag living IN the handle is per-copy --
// the copy would still look live after the original was consumed and would spend
// a DIFFERENT reservation's bytes. Keeping the state in the controller means
// every copy names the same one-shot entry.
type Reservation struct {
	owner *Controller
	token uint64
	// epoch invalidates handles across restoration: a reservation made before a
	// restart describes bytes the reconstructed state does not contain.
	epoch uint64
}

// Bytes reports how many bytes this reservation holds, or 0 once it is consumed,
// stale, or foreign.
func (r *Reservation) Bytes() uint64 {
	if r == nil || r.owner == nil {
		return 0
	}

	r.owner.mu.Lock()
	defer r.owner.mu.Unlock()

	p, err := r.owner.lookupLocked(r)
	if err != nil {
		return 0
	}

	return p.bytes
}

// pending is controller-held reservation state, keyed by token.
type pending struct {
	class Class
	bytes uint64
}

// spoolCharges is one generation's independent accounting.
type spoolCharges struct {
	// slots maps a sequence to its byte charge.
	slots map[uint64]uint64
	// reclaimedThrough is the last authorized watermark. Per generation, never
	// global -- a global watermark would let one lane release another lane's bytes.
	reclaimedThrough uint64
	// serial is the last applied authorization serial, which makes replay a no-op.
	serial uint64
}

// SpoolSnapshot is one generation's accounting as read back at startup.
type SpoolSnapshot struct {
	// ReclaimedThrough and AuthorizationSerial are the last authorization this
	// generation applied. Both must be carried across restart: without the serial,
	// a replayed authorization would be indistinguishable from a new one.
	ReclaimedThrough    uint64
	AuthorizationSerial uint64
	// Slots maps a sequence to its byte charge. Nothing about delivery state
	// appears here: a snapshot that recorded remote resolution would be duplicate
	// lifecycle state with no reader, and gwprefix already owns it (task 2.16).
	Slots map[uint64]uint64
}

// Snapshot is the reconstructed byte accounting for every live generation.
type Snapshot struct {
	Spools map[SpoolID]SpoolSnapshot
}

// Controller tracks reserved and charged unreclaimed bytes and makes class-aware
// admission decisions. Safe for concurrent use.
type Controller struct {
	mu  sync.Mutex
	lim Limits

	// ready is false until a snapshot is installed. A fresh controller must not
	// admit: it would be admitting against bytes the spool is still holding.
	ready bool

	// epoch increments on restoration, invalidating outstanding handles.
	epoch uint64
	// nextToken is monotonic and is NEVER reset or wrapped, so a token can never
	// alias a live handle.
	nextToken uint64
	pending   map[uint64]*pending

	spools map[SpoolID]*spoolCharges

	// reserved is admitted bytes not yet bound to a slot identity.
	reserved uint64
	// charged is the sum of every live slot charge.
	charged uint64

	bulkPaused bool
}

// New validates the limits and returns a controller that is CLOSED to admission
// until Restore installs a snapshot.
//
// Starting open is the fail-open shape this exists to prevent: a fresh process
// would report zero held bytes and admit a full capacity of new work on top of
// whatever the spool still holds. A deployment with genuinely no durable state
// calls Restore with an empty snapshot, which is a verified claim rather than an
// assumption.
func New(lim Limits) (*Controller, error) {
	if err := validateLimits(lim); err != nil {
		return nil, err
	}

	return &Controller{
		lim:     lim,
		pending: make(map[uint64]*pending),
		spools:  make(map[SpoolID]*spoolCharges),
	}, nil
}

// NewRestored builds a controller and installs a snapshot in one step, so a
// caller that already holds the reconstructed state never handles an unready
// controller. This is the natural restart object: Restore is startup-only.
func NewRestored(lim Limits, snap Snapshot) (*Controller, error) {
	c, err := New(lim)
	if err != nil {
		return nil, err
	}

	if err := c.Restore(snap); err != nil {
		return nil, err
	}

	return c, nil
}

func validateLimits(lim Limits) error {
	if lim.Capacity == 0 || lim.HighWater > lim.Capacity || lim.LowWater >= lim.HighWater {
		return ErrInvalidLimits
	}

	// Checked addition: InteractiveReserve+RecoveryReserve can WRAP, which made
	// (MaxUint64, 1) look like a tiny sum and pass a capacity check it exceeds by
	// astronomical margin.
	floors, carry := bits.Add64(lim.InteractiveReserve, lim.RecoveryReserve, 0)
	if carry != 0 || floors > lim.Capacity {
		return ErrInvalidLimits
	}

	return nil
}

// addChecked returns a+b, or false if the sum would wrap.
func addChecked(a, b uint64) (uint64, bool) {
	sum, carry := bits.Add64(a, b, 0)

	return sum, carry == 0
}

func addOrOverflow(a, b uint64) (uint64, error) {
	sum, ok := addChecked(a, b)
	if !ok {
		return 0, ErrOverflow
	}

	return sum, nil
}

// heldLocked is reserved + charged: every byte the controller is holding.
// Returns false if the total would wrap, which callers must treat as "no room"
// rather than as a small number.
func (c *Controller) heldLocked() (uint64, bool) {
	return addChecked(c.reserved, c.charged)
}

// lookupLocked resolves a handle to its controller-held state.
func (c *Controller) lookupLocked(r *Reservation) (*pending, error) {
	if r == nil {
		return nil, ErrReservationConsumed
	}

	if r.owner != c {
		return nil, ErrForeignReservation
	}

	if r.epoch != c.epoch {
		return nil, fmt.Errorf("%w: handle epoch %d, controller epoch %d", ErrStaleReservation, r.epoch, c.epoch)
	}

	p, ok := c.pending[r.token]
	if !ok {
		return nil, ErrReservationConsumed
	}

	return p, nil
}

// Reserve requests bytes for a class. On Admit it returns a Reservation holding
// exactly those bytes against the budget; the caller must later Commit (once the
// record is durably spooled at a slot identity) or Release (if the window is
// abandoned) that handle. On Defer or Reject it returns a nil Reservation.
//
// An unrestored controller Defers: the request is not impossible, it is merely
// unanswerable until the durable state is known.
func (c *Controller) Reserve(class Class, bytes uint64) (*Reservation, Decision) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.ready {
		return nil, Defer
	}

	if bytes == 0 {
		return nil, Reject
	}

	if c.nextToken == math.MaxUint64 {
		// Fail closed rather than wrap: a wrapped token would overwrite a live
		// entry, handing an old handle the new reservation's bytes.
		return nil, Reject
	}

	c.updateHysteresisLocked()

	total, ok := c.heldLocked()
	if !ok {
		return nil, Defer
	}

	// Budgets are computed by SUBTRACTION and admission by `bytes > budget-total`,
	// never `total+bytes > budget`. The additive form wraps: with a huge capacity,
	// reserved+bytes could overflow to a small number and admit unboundedly,
	// silently defeating the hard cap the controller exists to enforce.
	budget := c.lim.Capacity

	switch class {
	case ClassRecovery:
		// Recovery may draw on the whole capacity, including other reserves.
	case ClassInteractive:
		// Interactive may use everything except the recovery floor.
		budget = c.lim.Capacity - c.lim.RecoveryReserve
	case ClassBulk:
		// Bulk may use only what is left after both floors, and is paused by
		// hysteresis until pressure relaxes.
		budget = c.lim.Capacity - c.lim.RecoveryReserve - c.lim.InteractiveReserve
	default:
		return nil, Reject
	}

	if bytes > budget {
		return nil, Reject
	}

	if class == ClassBulk && c.bulkPaused {
		return nil, Defer
	}

	if total > budget || bytes > budget-total {
		return nil, Defer
	}

	reserved, ok := addChecked(c.reserved, bytes)
	if !ok {
		return nil, Defer
	}

	c.nextToken++

	if _, alias := c.pending[c.nextToken]; alias {
		return nil, Reject
	}

	c.pending[c.nextToken] = &pending{class: class, bytes: bytes}
	c.reserved = reserved
	c.updateHysteresisLocked()

	return &Reservation{owner: c, token: c.nextToken, epoch: c.epoch}, Admit
}

// Commit binds a reservation's bytes to a slot identity as an immutable charge.
//
// actualBytes may not exceed the reserved amount; the surplus returns to the
// budget. The charge is then released only by a reclaim authorization.
func (c *Controller) Commit(r *Reservation, key SlotKey, actualBytes uint64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.ready {
		return ErrNotRestored
	}

	p, err := c.lookupLocked(r)
	if err != nil {
		return err
	}

	if key.Spool == "" {
		return ErrEmptySpool
	}

	if actualBytes == 0 {
		return fmt.Errorf("%w: %s", ErrEmptySlot, key)
	}

	if actualBytes > p.bytes {
		return fmt.Errorf("%w: charged %d > reserved %d", ErrOverCommit, actualBytes, p.bytes)
	}

	sp, ok := c.spools[key.Spool]
	if !ok {
		sp = &spoolCharges{slots: make(map[uint64]uint64)}
	}

	if key.Seq <= sp.reclaimedThrough {
		return fmt.Errorf("%w: %s at or below %d", ErrReclaimedSlot, key, sp.reclaimedThrough)
	}

	if _, dup := sp.slots[key.Seq]; dup {
		return fmt.Errorf("%w: %s", ErrDuplicateSlot, key)
	}

	charged, err := addOrOverflow(c.charged, actualBytes)
	if err != nil {
		return err
	}

	if p.bytes > c.reserved {
		// Exact invariant rather than saturating subtraction: a reservation whose
		// bytes exceed what this controller has reserved means the accounting is
		// already wrong, and silently clamping to zero would hide it.
		return fmt.Errorf("%w: reservation %d > reserved %d", ErrOverflow, p.bytes, c.reserved)
	}

	c.spools[key.Spool] = sp
	sp.slots[key.Seq] = actualBytes

	delete(c.pending, r.token)
	c.reserved -= p.bytes
	c.charged = charged
	c.updateHysteresisLocked()

	return nil
}

// Release returns an uncharged reservation's bytes to the budget.
func (c *Controller) Release(r *Reservation) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.ready {
		return ErrNotRestored
	}

	p, err := c.lookupLocked(r)
	if err != nil {
		return err
	}

	if p.bytes > c.reserved {
		return fmt.Errorf("%w: reservation %d > reserved %d", ErrOverflow, p.bytes, c.reserved)
	}

	delete(c.pending, r.token)
	c.reserved -= p.bytes
	c.updateHysteresisLocked()

	return nil
}

// ApplyReclaim releases every charge in one generation at or below an authorized
// watermark, and returns the bytes freed.
//
// This is the ONLY path that returns charged bytes to the budget. The
// authorization comes from the durable journal/coverage owner; admission does not
// and cannot verify it, so what it enforces instead is exactness and
// monotonicity: the serial must advance, the watermark may not retreat, replay is
// a no-op, and the arithmetic is checked.
//
// Producing the authorization, and proving it holds across a crash, is task 2.28.
func (c *Controller) ApplyReclaim(auth ReclaimAuthorization) (uint64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.ready {
		return 0, ErrNotRestored
	}

	if !auth.valid() {
		return 0, ErrUnauthorized
	}

	spool, through, serial := auth.spool, auth.through, auth.serial

	sp, ok := c.spools[spool]
	if !ok {
		return 0, fmt.Errorf("%w: %s", ErrUnknownSpool, spool)
	}

	if serial == sp.serial {
		// A serial names exactly ONE authorization. Replaying it is a no-op, but the
		// same serial carrying a DIFFERENT watermark is a contradiction -- two
		// authorizations issued under one identity -- and applying it would release
		// bytes under a serial that has already been consumed.
		if through != sp.reclaimedThrough {
			return 0, fmt.Errorf("%w: %s serial %d already applied through %d, now claims %d",
				ErrAuthorizationRegression, spool, serial, sp.reclaimedThrough, through)
		}

		return 0, nil
	}

	// The serial is checked INDEPENDENTLY of the watermark. A stale authorization
	// can still carry a larger watermark -- a rolled-back or superseded owner
	// reissuing -- and the watermark check alone would accept it.
	if serial < sp.serial {
		return 0, fmt.Errorf("%w: %s serial %d < %d", ErrAuthorizationRegression, spool, serial, sp.serial)
	}

	if through < sp.reclaimedThrough {
		return 0, fmt.Errorf("%w: %s through %d < %d",
			ErrAuthorizationRegression, spool, through, sp.reclaimedThrough)
	}

	var (
		freed   uint64
		release = make([]uint64, 0, len(sp.slots))
	)

	for seq, bytes := range sp.slots {
		if seq > through {
			continue
		}

		sum, err := addOrOverflow(freed, bytes)
		if err != nil {
			return 0, err
		}

		freed = sum

		release = append(release, seq)
	}

	if freed > c.charged {
		return 0, fmt.Errorf("%w: freeing %d > charged %d", ErrOverflow, freed, c.charged)
	}

	for _, seq := range release {
		delete(sp.slots, seq)
	}

	c.charged -= freed
	sp.reclaimedThrough = through
	sp.serial = serial
	c.updateHysteresisLocked()

	return freed, nil
}

// Restore installs reconstructed accounting and opens the controller to
// admission. It is STARTUP-ONLY.
//
// Restoring a live controller is refused. Validating outside the lock and then
// swapping is not merely a race: any window at all lets work admitted in the
// meantime be silently erased, and a stale snapshot would overwrite accounting
// that is more current than it is. A restart wants a NEW controller, which is
// what NewRestored builds.
//
// Validation happens entirely under the lock, into fresh state that is installed
// only on success, so a rejected snapshot leaves a fresh controller closed rather
// than open and empty.
func (c *Controller) Restore(snap Snapshot) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.ready {
		return ErrAlreadyRestored
	}

	spools := make(map[SpoolID]*spoolCharges, len(snap.Spools))

	var charged uint64

	for id, s := range snap.Spools {
		if id == "" {
			return fmt.Errorf("%w: %w", ErrInvalidSnapshot, ErrEmptySpool)
		}

		sp := &spoolCharges{
			slots:            make(map[uint64]uint64, len(s.Slots)),
			reclaimedThrough: s.ReclaimedThrough,
			serial:           s.AuthorizationSerial,
		}

		for seq, bytes := range s.Slots {
			if seq <= s.ReclaimedThrough {
				return fmt.Errorf("%w: %s/%d is at or below the restored watermark %d",
					ErrInvalidSnapshot, id, seq, s.ReclaimedThrough)
			}

			if bytes == 0 {
				return fmt.Errorf("%w: %s/%d has zero bytes", ErrInvalidSnapshot, id, seq)
			}

			sp.slots[seq] = bytes

			sum, err := addOrOverflow(charged, bytes)
			if err != nil {
				return err
			}

			charged = sum
		}

		spools[id] = sp
	}

	if charged > c.lim.Capacity {
		return fmt.Errorf("%w: restored %d bytes exceeds capacity %d", ErrInvalidSnapshot, charged, c.lim.Capacity)
	}

	c.epoch++
	c.pending = make(map[uint64]*pending)
	c.spools = spools
	c.reserved = 0
	c.charged = charged
	c.ready = true
	c.restoreHysteresisLocked()

	return nil
}

// restoreHysteresisLocked sets the initial bulk-pause state after a restart.
//
// It cannot be derived by the normal rule, which only pauses at or above the high
// water: a controller restored BETWEEN the marks was paused before the crash and
// has not seen the relief that clears it. Starting unpaused turns a restart into a
// resume signal, letting bulk admit against pressure that never relaxed --
// exactly what the hysteresis exists to prevent.
//
// So restart assumes the pessimistic side: paused unless the restored usage is at
// or below the low water, which is the only unambiguous evidence of real relief.
// The state is DERIVED rather than carried in the snapshot on purpose -- a
// persisted `paused` flag is a second source of truth that can disagree with the
// byte totals it is supposed to summarise.
func (c *Controller) restoreHysteresisLocked() {
	total, ok := c.heldLocked()
	if !ok {
		total = c.lim.Capacity
	}

	c.bulkPaused = total > c.lim.LowWater
}

// Ready reports whether a snapshot has been installed. An unready controller
// admits nothing.
func (c *Controller) Ready() bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.ready
}

// BulkPaused reports whether bulk admission is currently paused by hysteresis.
func (c *Controller) BulkPaused() bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.bulkPaused
}

// Pressure returns the fraction of capacity currently held.
func (c *Controller) Pressure() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()

	held, ok := c.heldLocked()
	if !ok {
		return 1
	}

	return float64(held) / float64(c.lim.Capacity)
}

// InUse returns bytes reserved but not yet bound to a slot identity, and bytes
// charged to slots awaiting a reclaim authorization.
//
// Both are reported because both are real held state: an accessor that hid the
// charged bucket read zero while the controller was completely full,
// under-reporting the exact condition this accounting exists to make visible.
func (c *Controller) InUse() (reserved, charged uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.reserved, c.charged
}

// TotalHeld returns every byte the controller is holding. This is the number
// admission and hysteresis act on.
func (c *Controller) TotalHeld() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()

	held, ok := c.heldLocked()
	if !ok {
		return c.lim.Capacity
	}

	return held
}

// ReclaimedThrough returns one generation's last authorized watermark.
func (c *Controller) ReclaimedThrough(spool SpoolID) uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()

	sp, ok := c.spools[spool]
	if !ok {
		return 0
	}

	return sp.reclaimedThrough
}

func (c *Controller) updateHysteresisLocked() {
	// Charged bytes are still HELD: they apply back-pressure until a reclaim
	// authorization releases them, or the controller would admit new work against
	// capacity the spool has not actually released.
	total, ok := c.heldLocked()
	if !ok {
		total = c.lim.Capacity
	}

	if !c.bulkPaused && total >= c.lim.HighWater {
		c.bulkPaused = true
	} else if c.bulkPaused && total <= c.lim.LowWater {
		c.bulkPaused = false
	}
}
