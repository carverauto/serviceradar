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

package admission

import (
	"errors"
	"math"
	"testing"
)

// spoolA and spoolB are two independent generations, as two live lanes have.
const (
	spoolA SpoolID = "gen-a"
	spoolB SpoolID = "gen-b"
)

// authorizationFor mints a reclaim authorization. It can exist only inside this
// package: the carrier's fields are unexported, so no external package can build
// a populated one. Task 2.28 supplies the real producer.
func authorizationFor(spool SpoolID, through, serial uint64) ReclaimAuthorization {
	return ReclaimAuthorization{spool: spool, through: through, serial: serial}
}

func testLimits() Limits {
	return Limits{
		Capacity:           1000,
		HighWater:          800,
		LowWater:           400,
		InteractiveReserve: 200,
		RecoveryReserve:    100,
	}
}

// newCtl returns a controller restored from a verified-empty snapshot: the
// deliberate "nothing durable" start.
func newCtl(t *testing.T) *Controller {
	t.Helper()

	c, err := NewRestored(testLimits(), Snapshot{})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	return c
}

func slotAt(seq uint64) SlotKey { return SlotKey{Spool: spoolA, Seq: seq} }

// reserveCommit reserves bytes for a class, asserts Admit, and charges them to a
// slot identity.
func reserveCommit(t *testing.T, c *Controller, class Class, key SlotKey, bytes uint64) {
	t.Helper()

	r, d := c.Reserve(class, bytes)
	if d != Admit {
		t.Fatalf("reserve %d = %v, want Admit", bytes, d)
	}

	if err := c.Commit(r, key, bytes); err != nil {
		t.Fatalf("commit %s (%d bytes): %v", key, bytes, err)
	}
}

// authorize applies an authorization and returns the bytes freed.
func authorize(t *testing.T, c *Controller, spool SpoolID, through, serial uint64) uint64 {
	t.Helper()

	freed, err := c.ApplyReclaim(authorizationFor(spool, through, serial))
	if err != nil {
		t.Fatalf("ApplyReclaim(%s, %d, %d): %v", spool, through, serial, err)
	}

	return freed
}

func TestNewRejectsBadLimits(t *testing.T) {
	cases := []Limits{
		{Capacity: 0},
		{Capacity: 100, HighWater: 200, LowWater: 50},
		{Capacity: 100, HighWater: 80, LowWater: 80},
		{Capacity: 100, HighWater: 80, LowWater: 40, InteractiveReserve: 80, RecoveryReserve: 40},
	}
	for i, lim := range cases {
		if _, err := New(lim); err == nil {
			t.Fatalf("case %d: expected ErrInvalidLimits", i)
		}
	}
}

func TestBulkHysteresisPausesAtHighWaterResumesAtLowWater(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 400)
	reserveCommit(t, c, ClassBulk, slotAt(2), 300) // total 700 < HighWater(800)

	if c.BulkPaused() {
		t.Fatal("should not be paused below high-water")
	}

	reserveCommit(t, c, ClassInteractive, SlotKey{spoolB, 1}, 150) // total 850 >= 800

	if !c.BulkPaused() {
		t.Fatal("should be paused at/above high-water")
	}

	if _, d := c.Reserve(ClassBulk, 1); d != Defer {
		t.Fatalf("bulk while paused = %v, want Defer", d)
	}

	if got := authorize(t, c, spoolA, 1, 1); got != 400 {
		t.Fatalf("freed %d, want 400", got) // total 450 > LowWater(400): still paused
	}

	if !c.BulkPaused() {
		t.Fatal("hysteresis: still paused between low- and high-water")
	}

	if got := authorize(t, c, spoolA, 2, 2); got != 300 {
		t.Fatalf("freed %d, want 300", got) // total 150 <= 400: resumes
	}

	if c.BulkPaused() {
		t.Fatal("should resume at/below low-water")
	}

	if _, d := c.Reserve(ClassBulk, 1); d != Admit {
		t.Fatalf("bulk after resume = %v, want Admit", d)
	}
}

func TestInteractiveReserveIsUnborrowableByBulk(t *testing.T) {
	c := newCtl(t)
	reserveCommit(t, c, ClassBulk, slotAt(1), 700)

	if _, d := c.Reserve(ClassBulk, 1); d != Defer {
		t.Fatalf("bulk into interactive/recovery reserve = %v, want Defer", d)
	}

	if _, d := c.Reserve(ClassInteractive, 200); d != Admit {
		t.Fatalf("interactive into its reserve = %v, want Admit", d)
	}
}

func TestRecoveryFloorProtectedFromInteractive(t *testing.T) {
	c := newCtl(t)
	reserveCommit(t, c, ClassInteractive, slotAt(1), 900)

	if _, d := c.Reserve(ClassInteractive, 1); d != Defer {
		t.Fatalf("interactive into recovery floor = %v, want Defer", d)
	}

	if _, d := c.Reserve(ClassRecovery, 100); d != Admit {
		t.Fatalf("recovery into its floor = %v, want Admit", d)
	}
}

func TestRejectVsDefer(t *testing.T) {
	c := newCtl(t)

	if _, d := c.Reserve(ClassBulk, 701); d != Reject {
		t.Fatalf("oversized bulk = %v, want Reject", d)
	}

	if _, d := c.Reserve(ClassRecovery, 1001); d != Reject {
		t.Fatalf("oversized recovery = %v, want Reject", d)
	}
}

func TestReleaseFreesUnchargedReservation(t *testing.T) {
	c := newCtl(t)

	r, d := c.Reserve(ClassBulk, 500)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	reserved, charged := c.InUse()
	if reserved != 500 || charged != 0 {
		t.Fatalf("after reserve reserved=%d charged=%d, want 500/0", reserved, charged)
	}

	if err := c.Release(r); err != nil {
		t.Fatalf("release: %v", err)
	}

	if got := c.TotalHeld(); got != 0 {
		t.Fatalf("TotalHeld=%d after releasing an uncharged reservation, want 0", got)
	}
}

// Finding usp-11/P1: a charge reporting more bytes than were reserved must be
// rejected, or charged bytes could exceed the promised capacity.
func TestCommitRejectsOverReservation(t *testing.T) {
	c := newCtl(t)

	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	if err := c.Commit(r, slotAt(1), 200); !errors.Is(err, ErrOverCommit) {
		t.Fatalf("over-commit = %v, want ErrOverCommit", err)
	}

	if err := c.Commit(r, slotAt(1), 100); err != nil {
		t.Fatalf("commit 100: %v", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld = %d, want 100", got)
	}
}

// Finding usp-11/P1: a reservation may be committed or released only once.
func TestReservationConsumedOnce(t *testing.T) {
	c := newCtl(t)

	r, _ := c.Reserve(ClassBulk, 100)
	if err := c.Commit(r, slotAt(1), 100); err != nil {
		t.Fatalf("commit: %v", err)
	}

	if err := c.Commit(r, slotAt(2), 100); !errors.Is(err, ErrReservationConsumed) {
		t.Fatalf("second commit = %v, want ErrReservationConsumed", err)
	}

	if err := c.Release(r); !errors.Is(err, ErrReservationConsumed) {
		t.Fatalf("release after commit = %v, want ErrReservationConsumed", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld = %d after a double-commit attempt, want 100", got)
	}
}

// Committing less than reserved returns the surplus.
func TestSurplusReservationIsReturned(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 600)

	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	if err := c.Commit(r, slotAt(2), 40); err != nil {
		t.Fatalf("commit 40: %v", err)
	}

	reserved, charged := c.InUse()
	if reserved != 0 {
		t.Fatalf("reserved surplus not released: reserved=%d", reserved)
	}

	if charged != 640 {
		t.Fatalf("charged = %d, want 640", charged)
	}
}

// --- 2.17: only a durable authorization releases ---------------------------

// The normative 2.17 regression, at this package's boundary: a crash before a
// durable local authorization leaves the bytes present.
//
// The gateway may have PubAcked every one of these slots -- admission has no way
// to know or care, because it holds no remote-resolution state at all. Nothing
// short of an authorization from the durable owner frees a byte.
func TestRestartWithoutAuthorizationReleasesNothing(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 400)
	reserveCommit(t, c, ClassBulk, slotAt(2), 300)

	if got := c.TotalHeld(); got != 700 {
		t.Fatalf("TotalHeld=%d, want 700", got)
	}

	// CRASH, then restart from the durable accounting. No reclaim was authorized.
	restarted, err := NewRestored(testLimits(), Snapshot{Spools: map[SpoolID]SpoolSnapshot{
		spoolA: {Slots: map[uint64]uint64{1: 400, 2: 300}},
	}})
	if err != nil {
		t.Fatalf("restore: %v", err)
	}

	if got := restarted.TotalHeld(); got != 700 {
		t.Fatalf("TotalHeld=%d after restart, want 700 retained", got)
	}

	if got := restarted.ReclaimedThrough(spoolA); got != 0 {
		t.Fatalf("restored watermark = %d, want 0: nothing was ever authorized", got)
	}

	// The restarted controller enforces the same pressure the crashed one did.
	if _, d := restarted.Reserve(ClassBulk, 400); d == Admit {
		t.Fatal("restarted controller admitted against bytes the spool still holds")
	}

	// Only the durable owner's authorization releases them.
	if got := authorize(t, restarted, spoolA, 2, 1); got != 700 {
		t.Fatalf("freed %d under authorization, want 700", got)
	}

	if got := restarted.TotalHeld(); got != 0 {
		t.Fatalf("TotalHeld=%d after authorization, want 0", got)
	}
}

// A replayed authorization is a no-op, so no replay can release bytes twice.
func TestReclaimAuthorizationIsIdempotent(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 100)
	reserveCommit(t, c, ClassBulk, slotAt(2), 100)

	if got := authorize(t, c, spoolA, 1, 7); got != 100 {
		t.Fatalf("first application freed %d, want 100", got)
	}

	for range 3 {
		if got := authorize(t, c, spoolA, 1, 7); got != 0 {
			t.Fatalf("replay freed %d, want 0", got)
		}
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d after replays, want 100 (slot 2 still charged)", got)
	}

	// A later serial that repeats the same watermark is also a no-op in bytes.
	if got := authorize(t, c, spoolA, 1, 8); got != 0 {
		t.Fatalf("re-authorizing the same watermark freed %d, want 0", got)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d, want 100", got)
	}

	// One serial names one authorization: reusing it with a different watermark is
	// a contradiction, not a replay, and must not release slot 2.
	_, err := c.ApplyReclaim(authorizationFor(spoolA, 2, 8))
	if !errors.Is(err, ErrAuthorizationRegression) {
		t.Fatalf("serial reused with a new watermark = %v, want ErrAuthorizationRegression", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d after a contradictory serial, want 100", got)
	}
}

// An authorization may not move a generation backwards.
func TestReclaimAuthorizationIsMonotonic(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 100)
	reserveCommit(t, c, ClassBulk, slotAt(2), 100)

	if got := authorize(t, c, spoolA, 2, 5); got != 200 {
		t.Fatalf("freed %d, want 200", got)
	}

	// A retreating watermark under a newer serial.
	_, err := c.ApplyReclaim(authorizationFor(spoolA, 1, 6))
	if !errors.Is(err, ErrAuthorizationRegression) {
		t.Fatalf("retreating watermark = %v, want ErrAuthorizationRegression", err)
	}

	// A STALE serial carrying a LARGER watermark: a superseded or rolled-back
	// owner reissuing. The watermark alone looks like progress, so only the serial
	// catches it -- and slot 3's bytes must stay held.
	reserveCommit(t, c, ClassBulk, slotAt(3), 100)

	_, err = c.ApplyReclaim(authorizationFor(spoolA, 3, 4))
	if !errors.Is(err, ErrAuthorizationRegression) {
		t.Fatalf("stale serial with a larger watermark = %v, want ErrAuthorizationRegression", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d after a stale authorization, want 100", got)
	}

	if got := c.ReclaimedThrough(spoolA); got != 2 {
		t.Fatalf("watermark = %d after a stale authorization, want 2", got)
	}

	// A slot at or below the watermark cannot be charged again.
	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	if err := c.Commit(r, slotAt(2), 100); !errors.Is(err, ErrReclaimedSlot) {
		t.Fatalf("charging a reclaimed slot = %v, want ErrReclaimedSlot", err)
	}
}

// Authorizations that arrive OUT OF ORDER are refused, not applied late.
//
// The owner issues 5, then 7; 6 is delayed in flight and lands afterwards. Its
// watermark is behind 7's and its serial is behind the applied one, so the bytes
// it names are already accounted for -- applying it would release slots 3 and 4 a
// second time.
func TestOutOfOrderAuthorizationsAreRefused(t *testing.T) {
	c := newCtl(t)

	for seq := uint64(1); seq <= 5; seq++ {
		reserveCommit(t, c, ClassBulk, slotAt(seq), 100)
	}

	if got := authorize(t, c, spoolA, 2, 5); got != 200 {
		t.Fatalf("serial 5 freed %d, want 200", got)
	}

	if got := authorize(t, c, spoolA, 4, 7); got != 200 {
		t.Fatalf("serial 7 freed %d, want 200", got)
	}

	// Serial 6 arrives late, naming a watermark between the two.
	_, err := c.ApplyReclaim(authorizationFor(spoolA, 3, 6))
	if !errors.Is(err, ErrAuthorizationRegression) {
		t.Fatalf("late serial 6 = %v, want ErrAuthorizationRegression", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d, want 100: only slot 5 remains", got)
	}

	if got := c.ReclaimedThrough(spoolA); got != 4 {
		t.Fatalf("watermark = %d after a late authorization, want 4", got)
	}
}

// The zero carrier holds no claim. It is the only value an external package can
// produce, so this is what an attempted forgery gets.
func TestZeroAuthorizationIsRejected(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 100)

	if _, err := c.ApplyReclaim(ReclaimAuthorization{}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("zero authorization = %v, want ErrUnauthorized", err)
	}

	// A carrier naming a generation but no serial is equally empty.
	if _, err := c.ApplyReclaim(ReclaimAuthorization{spool: spoolA, through: 1}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("serial-less authorization = %v, want ErrUnauthorized", err)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d, want 100", got)
	}
}

// Charges are bound to an immutable slot identity: one identity, one charge.
func TestChargesAreBoundToAnImmutableSlotIdentity(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 100)

	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	if err := c.Commit(r, slotAt(1), 100); !errors.Is(err, ErrDuplicateSlot) {
		t.Fatalf("second charge for one identity = %v, want ErrDuplicateSlot", err)
	}

	if err := c.Commit(r, SlotKey{Spool: "", Seq: 1}, 100); !errors.Is(err, ErrEmptySpool) {
		t.Fatalf("charge with no generation = %v, want ErrEmptySpool", err)
	}

	if err := c.Commit(r, slotAt(2), 0); !errors.Is(err, ErrEmptySlot) {
		t.Fatalf("zero-byte charge = %v, want ErrEmptySlot", err)
	}

	if _, d := c.Reserve(ClassBulk, 0); d != Reject {
		t.Fatalf("zero-byte reserve = %v, want Reject", d)
	}
}

// Generations are isolated: one authorization never touches another's charges.
func TestGenerationsAreIsolated(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, SlotKey{spoolA, 1}, 100)
	reserveCommit(t, c, ClassInteractive, SlotKey{spoolB, 1}, 100)

	if got := c.TotalHeld(); got != 200 {
		t.Fatalf("TotalHeld=%d, want 200: sequence 1 in two generations is two slots", got)
	}

	if got := authorize(t, c, spoolA, 1, 1); got != 100 {
		t.Fatalf("freed %d, want 100", got)
	}

	if got := c.TotalHeld(); got != 100 {
		t.Fatalf("TotalHeld=%d, want 100: generation B's slot 1 must survive", got)
	}

	if got := c.ReclaimedThrough(spoolB); got != 0 {
		t.Fatalf("generation B watermark = %d, want 0: one lane must not advance another", got)
	}

	// An authorization for an unknown generation touches nothing.
	_, err := c.ApplyReclaim(authorizationFor("gen-never-seen", 99, 1))
	if !errors.Is(err, ErrUnknownSpool) {
		t.Fatalf("unknown generation = %v, want ErrUnknownSpool", err)
	}

	if got := authorize(t, c, spoolB, 1, 1); got != 100 {
		t.Fatalf("freed %d, want 100", got)
	}

	if got := c.TotalHeld(); got != 0 {
		t.Fatalf("TotalHeld=%d after both generations, want 0", got)
	}
}

// --- restart ---------------------------------------------------------------

// A fresh controller must not admit before its durable accounting is known.
func TestRestartMustRestoreBeforeAdmitting(t *testing.T) {
	fresh, err := New(testLimits())
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	if fresh.Ready() {
		t.Fatal("a fresh controller reports ready before any snapshot was installed")
	}

	if _, d := fresh.Reserve(ClassBulk, 400); d != Defer {
		t.Fatalf("unrestored reserve = %v, want Defer", d)
	}

	if _, err := fresh.ApplyReclaim(authorizationFor(spoolA, 1, 1)); !errors.Is(err, ErrNotRestored) {
		t.Fatalf("unrestored ApplyReclaim = %v, want ErrNotRestored", err)
	}

	err = fresh.Restore(Snapshot{Spools: map[SpoolID]SpoolSnapshot{
		spoolA: {ReclaimedThrough: 4, AuthorizationSerial: 9, Slots: map[uint64]uint64{5: 400, 6: 300}},
	}})
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}

	if got := fresh.TotalHeld(); got != 700 {
		t.Fatalf("TotalHeld=%d after restore, want 700", got)
	}

	if got := fresh.ReclaimedThrough(spoolA); got != 4 {
		t.Fatalf("restored watermark = %d, want 4", got)
	}

	// The restored serial makes a replayed authorization a no-op rather than a
	// second release.
	if got := authorize(t, fresh, spoolA, 4, 9); got != 0 {
		t.Fatalf("replayed pre-restart authorization freed %d, want 0", got)
	}

	if _, d := fresh.Reserve(ClassBulk, 400); d == Admit {
		t.Fatal("restored controller admitted against bytes the spool still holds")
	}
}

// Restart must not act as a resume signal for bulk admission.
//
// A controller restored BETWEEN the marks was paused before the crash and has not
// seen the relief that clears it, so it starts paused. Deriving the flag from the
// normal rule -- which only pauses at or above the high water -- would let bulk
// admit against pressure that never relaxed.
func TestRestartDoesNotResumeBulkWithoutRelief(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 300)
	reserveCommit(t, c, ClassInteractive, slotAt(2), 500) // 800 >= HighWater

	if !c.BulkPaused() {
		t.Fatal("should be paused at the high water")
	}

	// Reclaiming the leading slot leaves 500: below the high water, above the low.
	if got := authorize(t, c, spoolA, 1, 1); got != 300 {
		t.Fatalf("freed %d, want 300", got)
	}

	if !c.BulkPaused() {
		t.Fatal("live controller must stay paused at 500 until the low water")
	}

	// Restart holding the same remaining charge, between the two marks.
	restarted, err := NewRestored(testLimits(), Snapshot{Spools: map[SpoolID]SpoolSnapshot{
		spoolA: {ReclaimedThrough: 1, AuthorizationSerial: 1, Slots: map[uint64]uint64{2: 500}},
	}})
	if err != nil {
		t.Fatalf("restore: %v", err)
	}

	if !restarted.BulkPaused() {
		t.Fatal("restart resumed bulk without relief: restored usage is above the low water")
	}

	if _, d := restarted.Reserve(ClassBulk, 1); d != Defer {
		t.Fatalf("bulk after restart = %v, want Defer", d)
	}

	// Real relief still clears it.
	if got := authorize(t, restarted, spoolA, 2, 2); got != 500 {
		t.Fatalf("freed %d, want 500", got)
	}

	if restarted.BulkPaused() {
		t.Fatal("bulk must resume once the low water is reached")
	}
}

// A restart at or below the low water starts unpaused: that is unambiguous
// relief, so the conservative default must not wedge bulk admission forever.
func TestRestartBelowLowWaterStartsUnpaused(t *testing.T) {
	c, err := NewRestored(testLimits(), Snapshot{Spools: map[SpoolID]SpoolSnapshot{
		spoolA: {Slots: map[uint64]uint64{1: 400}},
	}})
	if err != nil {
		t.Fatalf("restore: %v", err)
	}

	if c.BulkPaused() {
		t.Fatal("restart at the low water must not pause bulk")
	}

	if _, d := c.Reserve(ClassBulk, 1); d != Admit {
		t.Fatalf("bulk after restart at the low water = %v, want Admit", d)
	}
}

// Restoration is startup-only: swapping state under a running controller erases
// whatever it accepted in the meantime.
func TestRestoreIsStartupOnly(t *testing.T) {
	c := newCtl(t)

	reserveCommit(t, c, ClassBulk, slotAt(1), 700)

	if err := c.Restore(Snapshot{}); !errors.Is(err, ErrAlreadyRestored) {
		t.Fatalf("restoring a live controller = %v, want ErrAlreadyRestored", err)
	}

	if got := c.TotalHeld(); got != 700 {
		t.Fatalf("TotalHeld=%d after a refused restore, want 700 preserved", got)
	}

	if _, d := c.Reserve(ClassBulk, 700); d == Admit {
		t.Fatal("a refused restore erased live state and admitted against it")
	}
}

// A rejected snapshot must never leave a fresh controller open and empty.
func TestFailedRestoreDoesNotOpenAdmission(t *testing.T) {
	cases := map[string]Snapshot{
		"slot below the restored watermark": {Spools: map[SpoolID]SpoolSnapshot{
			spoolA: {ReclaimedThrough: 5, Slots: map[uint64]uint64{5: 700}},
		}},
		"zero-byte charge": {Spools: map[SpoolID]SpoolSnapshot{
			spoolA: {Slots: map[uint64]uint64{1: 0}},
		}},
		"empty generation id": {Spools: map[SpoolID]SpoolSnapshot{
			"": {Slots: map[uint64]uint64{1: 10}},
		}},
		"exceeds capacity": {Spools: map[SpoolID]SpoolSnapshot{
			spoolA: {Slots: map[uint64]uint64{1: 1001}},
		}},
	}

	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			fresh, err := New(testLimits())
			if err != nil {
				t.Fatalf("new: %v", err)
			}

			if err := fresh.Restore(bad); !errors.Is(err, ErrInvalidSnapshot) {
				t.Fatalf("bad snapshot = %v, want ErrInvalidSnapshot", err)
			}

			if fresh.Ready() {
				t.Fatal("a failed restore opened the controller")
			}

			if _, d := fresh.Reserve(ClassBulk, 400); d == Admit {
				t.Fatal("admitted after a failed restore")
			}
		})
	}
}

// --- arithmetic and handles -------------------------------------------------

// Unchecked uint64 arithmetic must not wrap the hard cap to zero.
func TestHardCapSurvivesOverflowingInputs(t *testing.T) {
	c, err := NewRestored(Limits{
		Capacity:  math.MaxUint64,
		HighWater: math.MaxUint64,
		LowWater:  math.MaxUint64 - 1,
	}, Snapshot{})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	if _, d := c.Reserve(ClassRecovery, math.MaxUint64); d != Admit {
		t.Fatalf("first max reserve = %v, want Admit", d)
	}

	if _, d := c.Reserve(ClassRecovery, 1); d == Admit {
		t.Fatal("admitted past a full capacity: the total wrapped to zero")
	}

	if got := c.Pressure(); got < 1 {
		t.Fatalf("Pressure=%v at capacity, want >= 1", got)
	}
}

// A snapshot whose charges sum past uint64 is refused rather than wrapped into a
// small, admitting total.
//
// This is the reachable overflow: live charges cannot wrap, because reserve +
// charged is bounded by capacity on the way in. A snapshot arrives from outside
// that invariant.
func TestRestoreRefusesWrappingCharges(t *testing.T) {
	fresh, err := New(Limits{
		Capacity:  math.MaxUint64,
		HighWater: math.MaxUint64,
		LowWater:  math.MaxUint64 - 1,
	})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	err = fresh.Restore(Snapshot{Spools: map[SpoolID]SpoolSnapshot{
		spoolA: {Slots: map[uint64]uint64{
			1: math.MaxUint64 - 1,
			2: math.MaxUint64 - 1,
		}},
	}})
	if !errors.Is(err, ErrOverflow) {
		t.Fatalf("wrapping snapshot = %v, want ErrOverflow", err)
	}

	if fresh.Ready() {
		t.Fatal("a wrapping snapshot opened the controller")
	}

	if _, d := fresh.Reserve(ClassRecovery, math.MaxUint64); d == Admit {
		t.Fatal("admitted a full capacity after a wrapping snapshot")
	}
}

// Reserve floors whose SUM wraps must be rejected.
func TestLimitsRejectWrappingFloors(t *testing.T) {
	_, err := New(Limits{
		Capacity:           1000,
		HighWater:          800,
		LowWater:           400,
		InteractiveReserve: math.MaxUint64,
		RecoveryReserve:    1,
	})
	if !errors.Is(err, ErrInvalidLimits) {
		t.Fatalf("wrapping floors: err = %v, want ErrInvalidLimits", err)
	}
}

// A reservation is bound to the controller that issued it.
func TestForeignReservationsAreRejected(t *testing.T) {
	a := newCtl(t)

	b, err := NewRestored(Limits{Capacity: 50, HighWater: 50, LowWater: 25}, Snapshot{})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	r, d := a.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v, want Admit", d)
	}

	if err := b.Commit(r, slotAt(1), 100); !errors.Is(err, ErrForeignReservation) {
		t.Fatalf("foreign commit: err = %v, want ErrForeignReservation", err)
	}

	if err := b.Release(r); !errors.Is(err, ErrForeignReservation) {
		t.Fatalf("foreign release: err = %v, want ErrForeignReservation", err)
	}

	if got := b.TotalHeld(); got != 0 {
		t.Fatalf("foreign controller holds %d, want 0", got)
	}

	if err := a.Commit(r, slotAt(1), 100); err != nil {
		t.Fatalf("owner commit after foreign attempts: %v", err)
	}
}

// A COPY of a handle names the same one-shot reservation.
func TestCopiedReservationCannotConsumeAnother(t *testing.T) {
	c := newCtl(t)

	first, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve first = %v", d)
	}

	second, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve second = %v", d)
	}

	clone := *first

	if err := c.Commit(first, slotAt(1), 100); err != nil {
		t.Fatalf("commit first: %v", err)
	}

	if err := c.Commit(&clone, slotAt(2), 100); !errors.Is(err, ErrReservationConsumed) {
		t.Fatalf("copied handle commit = %v, want ErrReservationConsumed", err)
	}

	if got := clone.Bytes(); got != 0 {
		t.Fatalf("consumed copy reports %d bytes, want 0", got)
	}

	if got := second.Bytes(); got != 100 {
		t.Fatalf("second reservation reports %d bytes, want 100", got)
	}

	if err := c.Commit(second, slotAt(2), 100); err != nil {
		t.Fatalf("second handle was consumed by the copy: %v", err)
	}

	if got := c.TotalHeld(); got != 200 {
		t.Fatalf("TotalHeld=%d, want 200", got)
	}
}

// The token space must fail closed rather than wrap onto a live handle.
func TestTokenExhaustionFailsClosed(t *testing.T) {
	c := newCtl(t)

	c.mu.Lock()
	c.nextToken = math.MaxUint64
	c.mu.Unlock()

	if _, d := c.Reserve(ClassBulk, 100); d != Reject {
		t.Fatalf("reserve at token exhaustion = %v, want Reject", d)
	}

	if got := c.TotalHeld(); got != 0 {
		t.Fatalf("TotalHeld=%d after a rejected reserve, want 0", got)
	}
}

// A handle from before a restoration describes bytes the reconstructed state does
// not contain.
func TestReservationsAreInvalidatedByRestore(t *testing.T) {
	c, err := New(testLimits())
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	if err := c.Restore(Snapshot{}); err != nil {
		t.Fatalf("Restore: %v", err)
	}

	stale, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}

	c.mu.Lock()
	c.epoch++
	c.mu.Unlock()

	if err := c.Commit(stale, slotAt(1), 100); !errors.Is(err, ErrStaleReservation) {
		t.Fatalf("stale-epoch handle = %v, want ErrStaleReservation", err)
	}

	if err := c.Release(stale); !errors.Is(err, ErrStaleReservation) {
		t.Fatalf("stale-epoch release = %v, want ErrStaleReservation", err)
	}
}
