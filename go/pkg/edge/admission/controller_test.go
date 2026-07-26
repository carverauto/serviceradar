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
	"testing"
)

func newCtl(t *testing.T) *Controller {
	t.Helper()
	c, err := New(Limits{
		Capacity:           1000,
		HighWater:          800,
		LowWater:           400,
		InteractiveReserve: 200,
		RecoveryReserve:    100,
	})
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	return c
}

// reserveCommit reserves bytes for a class, asserts Admit, and commits the full
// amount. It returns nothing; test failures are fatal.
func reserveCommit(t *testing.T, c *Controller, class Class, bytes uint64) {
	t.Helper()
	r, d := c.Reserve(class, bytes)
	if d != Admit {
		t.Fatalf("reserve %d = %v, want Admit", bytes, d)
	}
	if err := c.Commit(r, bytes); err != nil {
		t.Fatalf("commit %d: %v", bytes, err)
	}
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
	reserveCommit(t, c, ClassBulk, 700) // total 700 < HighWater(800)
	if c.BulkPaused() {
		t.Fatal("should not be paused below high-water")
	}
	reserveCommit(t, c, ClassInteractive, 150) // total 850 >= 800
	if !c.BulkPaused() {
		t.Fatal("should be paused at/above high-water")
	}
	if _, d := c.Reserve(ClassBulk, 1); d != Defer {
		t.Fatalf("bulk while paused = %v, want Defer", d)
	}
	c.Resolve(400) // total 450 > LowWater(400): still paused
	if !c.BulkPaused() {
		t.Fatal("hysteresis: still paused between low- and high-water")
	}
	c.Resolve(60) // total 390 <= 400: resumes
	if c.BulkPaused() {
		t.Fatal("should resume at/below low-water")
	}
	if _, d := c.Reserve(ClassBulk, 1); d != Admit {
		t.Fatalf("bulk after resume = %v, want Admit", d)
	}
}

func TestInteractiveReserveIsUnborrowableByBulk(t *testing.T) {
	c := newCtl(t)
	reserveCommit(t, c, ClassBulk, 700)
	if _, d := c.Reserve(ClassBulk, 1); d != Defer {
		t.Fatalf("bulk into interactive/recovery reserve = %v, want Defer", d)
	}
	if _, d := c.Reserve(ClassInteractive, 200); d != Admit {
		t.Fatalf("interactive into its reserve = %v, want Admit", d)
	}
}

func TestRecoveryFloorProtectedFromInteractive(t *testing.T) {
	c := newCtl(t)
	reserveCommit(t, c, ClassInteractive, 900)
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

func TestReleaseFreesReservationWithoutCommitting(t *testing.T) {
	c := newCtl(t)
	r, d := c.Reserve(ClassBulk, 500)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}
	res, used := c.InUse()
	if res != 500 || used != 0 {
		t.Fatalf("after reserve res=%d used=%d, want 500/0", res, used)
	}
	if err := c.Release(r); err != nil {
		t.Fatalf("release: %v", err)
	}
	res, used = c.InUse()
	if res != 0 || used != 0 {
		t.Fatalf("after release res=%d used=%d, want 0/0", res, used)
	}
}

// Finding usp-11/P1: a commit reporting more bytes than were reserved must be
// rejected, or committed bytes could exceed the promised capacity.
func TestCommitRejectsOverReservation(t *testing.T) {
	c := newCtl(t)
	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}
	if err := c.Commit(r, 200); !errors.Is(err, ErrOverCommit) {
		t.Fatalf("over-commit = %v, want ErrOverCommit", err)
	}
	// The reservation was not consumed by the failed commit; a correct commit
	// still works and leaves used within the reservation.
	if err := c.Commit(r, 100); err != nil {
		t.Fatalf("commit 100: %v", err)
	}
	_, used := c.InUse()
	if used != 100 {
		t.Fatalf("used = %d, want 100", used)
	}
}

// Finding usp-11/P1: a reservation may be committed or released only once, so a
// double-commit cannot inflate used bytes past capacity.
func TestReservationConsumedOnce(t *testing.T) {
	c := newCtl(t)
	r, _ := c.Reserve(ClassBulk, 100)
	if err := c.Commit(r, 100); err != nil {
		t.Fatalf("commit: %v", err)
	}
	if err := c.Commit(r, 100); !errors.Is(err, ErrReservationConsumed) {
		t.Fatalf("second commit = %v, want ErrReservationConsumed", err)
	}
	if err := c.Release(r); !errors.Is(err, ErrReservationConsumed) {
		t.Fatalf("release after commit = %v, want ErrReservationConsumed", err)
	}
	_, used := c.InUse()
	if used != 100 {
		t.Fatalf("used = %d after double-commit attempt, want 100", used)
	}
}

// The hard-cap invariant holds across a churn of reserve/commit/resolve: total
// held never exceeds capacity.
func TestCapacityInvariantHolds(t *testing.T) {
	c := newCtl(t)
	// Commit up to the bulk budget, then partial-commit a reservation.
	reserveCommit(t, c, ClassBulk, 600)
	r, d := c.Reserve(ClassBulk, 100)
	if d != Admit {
		t.Fatalf("reserve = %v", d)
	}
	// Commit less than reserved; the surplus is released, not left dangling.
	if err := c.Commit(r, 40); err != nil {
		t.Fatalf("commit 40: %v", err)
	}
	res, used := c.InUse()
	if res != 0 {
		t.Fatalf("reserved surplus not released: res=%d", res)
	}
	if used != 640 {
		t.Fatalf("used = %d, want 640", used)
	}
	if res+used > 1000 {
		t.Fatalf("capacity invariant broken: %d > 1000", res+used)
	}
}
