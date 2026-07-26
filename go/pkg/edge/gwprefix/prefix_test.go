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

package gwprefix

import (
	"errors"
	"testing"
)

func TestFreshTrackerResolvesNothing(t *testing.T) {
	tr := New(1)
	if tr.ResolvedThrough() != 0 {
		t.Fatalf("fresh resolved = %d, want 0", tr.ResolvedThrough())
	}
}

func TestContiguousInOrderAdvances(t *testing.T) {
	tr := New(1)
	for seq := uint64(1); seq <= 5; seq++ {
		if err := tr.Record(seq, StatusAccepted); err != nil {
			t.Fatalf("record %d: %v", seq, err)
		}
	}
	if tr.ResolvedThrough() != 5 {
		t.Fatalf("resolved = %d, want 5", tr.ResolvedThrough())
	}
}

// Out-of-order durable outcomes must NOT advance the prefix past a gap; the
// prefix jumps only when the gap fills.
func TestOutOfOrderHoldsAtGap(t *testing.T) {
	tr := New(1)
	_ = tr.Record(1, StatusAccepted)
	_ = tr.Record(3, StatusAccepted) // 2 is still missing
	_ = tr.Record(4, StatusRejected) // durable via DLQ, but behind the gap
	if tr.ResolvedThrough() != 1 {
		t.Fatalf("resolved = %d, want 1 (held at missing seq 2)", tr.ResolvedThrough())
	}
	if tr.PendingOutOfOrder() != 2 {
		t.Fatalf("pending = %d, want 2", tr.PendingOutOfOrder())
	}
	// Fill the gap: prefix jumps across 2,3,4.
	if err := tr.Record(2, StatusAccepted); err != nil {
		t.Fatalf("record 2: %v", err)
	}
	if tr.ResolvedThrough() != 4 {
		t.Fatalf("resolved after gap fill = %d, want 4", tr.ResolvedThrough())
	}
	if tr.PendingOutOfOrder() != 0 {
		t.Fatalf("pending = %d, want 0", tr.PendingOutOfOrder())
	}
}

// A rejected (DLQ'd) frame is resolved and advances the prefix just like an
// accepted one.
func TestRejectedResolvesPrefix(t *testing.T) {
	tr := New(1)
	_ = tr.Record(1, StatusAccepted)
	_ = tr.Record(2, StatusRejected)
	_ = tr.Record(3, StatusAccepted)
	if tr.ResolvedThrough() != 3 {
		t.Fatalf("resolved = %d, want 3", tr.ResolvedThrough())
	}
}

// A non-durable outcome (NATS unavailable / saturation) is never recorded, so
// the prefix withholds at that sequence even though later frames are durable.
func TestWithheldSequenceHoldsPrefix(t *testing.T) {
	tr := New(1)
	_ = tr.Record(1, StatusAccepted)
	// seq 2 is withheld (publisher saturated) -> not recorded.
	_ = tr.Record(3, StatusAccepted)
	_ = tr.Record(4, StatusAccepted)
	if tr.ResolvedThrough() != 1 {
		t.Fatalf("resolved = %d, want 1 (seq 2 withheld)", tr.ResolvedThrough())
	}
	// Recording pending must be rejected outright.
	if err := tr.Record(2, StatusPending); !errors.Is(err, ErrNotDurable) {
		t.Fatalf("record pending = %v, want ErrNotDurable", err)
	}
}

func TestRecordValidatesRange(t *testing.T) {
	tr := New(10)
	if err := tr.Record(9, StatusAccepted); !errors.Is(err, ErrBelowBase) {
		t.Fatalf("below base = %v, want ErrBelowBase", err)
	}
	if err := tr.Record(10, StatusAccepted); err != nil {
		t.Fatalf("record base: %v", err)
	}
	// Re-record already-resolved is an idempotent no-op.
	if err := tr.Record(10, StatusAccepted); err != nil {
		t.Fatalf("idempotent re-record: %v", err)
	}
}

func TestConflictingStatusRejected(t *testing.T) {
	tr := New(1)
	_ = tr.Record(2, StatusAccepted) // out of order, held
	if err := tr.Record(2, StatusRejected); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflicting status = %v, want ErrConflict", err)
	}
}
