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

package edgerecord

import (
	"errors"
	"fmt"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The two rows whose signed context names the EXECUTION, so source_run_id is
// FORBIDDEN, and the three whose context names a source-side run, so it is
// REQUIRED. Kept as literals rather than derived from sweepSourceMatrix: a test
// that reads the table it is checking would pass for any table.
var (
	//nolint:gochecknoglobals // immutable frozen inventory
	forbiddenRows = []edgev1.SweepExecutionSource{
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE,
	}
	//nolint:gochecknoglobals // immutable frozen inventory
	requiredRows = []edgev1.SweepExecutionSource{
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC,
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND,
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
	}
)

// sweepBatchFor returns a batch that is VALID for the given row -- the fixture
// defaults to SCHEDULED_CHECK, so both the source and the disposition must be
// re-set for any other row.
func sweepBatchFor(t *testing.T, src edgev1.SweepExecutionSource) *edgev1.SweepObservationBatchV1 {
	t.Helper()
	b := validSweepBatch(t)
	b.Source = src
	rule, ok := sweepRuleFor(src)
	if !ok {
		t.Fatalf("no frozen row for %v", src)
	}
	if rule.sourceRunID == sourceRunIDRequired {
		b.SourceRunId = mustUUID(t)
	} else {
		b.SourceRunId = nil
	}
	return b
}

// A valid batch on EVERY row is the control the negatives below are measured
// against. Without it a validator that rejected everything would pass them all.
func TestSweepDispositionPositivePerRow(t *testing.T) {
	for _, src := range append(append([]edgev1.SweepExecutionSource{}, forbiddenRows...), requiredRows...) {
		if err := ValidateSweepObservationBatch(sweepBatchFor(t, src)); err != nil {
			t.Fatalf("%v: valid batch rejected: %v", src, err)
		}
	}
}

// FORBIDDEN-PRESENCE, on BOTH forbidden rows. Sampling one row would leave the
// other's disposition unenforced -- the per-row gap the matrix exists to close.
func TestSweepSourceRunIDForbiddenPresence(t *testing.T) {
	for _, src := range forbiddenRows {
		b := sweepBatchFor(t, src)
		b.SourceRunId = mustUUID(t) // canonical, so only the DISPOSITION can reject it
		assertDispositionRejection(t, ValidateSweepObservationBatch(b), fmt.Sprintf("%v present-when-forbidden", src))
	}
}

// REQUIRED-ABSENCE, on ALL THREE required rows.
func TestSweepSourceRunIDRequiredAbsence(t *testing.T) {
	for _, src := range requiredRows {
		b := sweepBatchFor(t, src)
		b.SourceRunId = nil
		assertDispositionRejection(t, ValidateSweepObservationBatch(b), fmt.Sprintf("%v absent-when-required", src))
	}
}

// MALFORMED, one per required row. The canonical-UUID predicate is frozen as
// source-INDEPENDENT, which says the three rows SHARE a check -- it does not
// show all three INVOKE it, and one sampled row is satisfied by an
// implementation that checks canonical form on one source and skips the others.
// The three shapes below are the three INDEPENDENT predicates of "canonical UUID";
// they are not a catalogue of malformations, which does belong to the shared UUID
// predicate's own suite.
func TestSweepSourceRunIDMalformedPerRequiredRow(t *testing.T) {
	// Three shapes, because "canonical UUID" is three independent predicates and
	// LENGTH alone proves only one. With a wrong-length vector as the sole
	// malformed case, deleting BOTH the version and variant checks from
	// ValidateCanonicalUUID leaves the whole suite green -- verified by mutation.
	shapes := []struct {
		name string
		id   func(*testing.T) []byte
	}{
		{"wrong-length", func(*testing.T) []byte { return []byte{0x01, 0x02, 0x03} }},
		{"bad-version", func(t *testing.T) []byte {
			t.Helper()
			id := mustUUID(t)
			id[6] &= 0x0F // version nibble 0: outside the defined 1-8
			return id
		}},
		{"bad-variant", func(t *testing.T) []byte {
			t.Helper()
			id := mustUUID(t)
			id[8] = (id[8] & 0x3F) | 0xC0 // variant 110, not the RFC 10
			return id
		}},
	}
	for _, src := range requiredRows {
		for _, sh := range shapes {
			b := sweepBatchFor(t, src)
			b.SourceRunId = sh.id(t)
			assertDispositionRejection(t, ValidateSweepObservationBatch(b), fmt.Sprintf("%v/%s", src, sh.name))
		}
	}
}

// The disposition is decidable from the batch ALONE and MUST be refused by the
// BODY validator, not deferred to correlation. If it were deferred, a malformed
// batch would reach authority comparison and the reported reason would depend on
// which mismatch was noticed first.
func TestSweepDispositionIsBodyOwned(t *testing.T) {
	b := sweepBatchFor(t, edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC)
	b.SourceRunId = nil
	assertDispositionRejection(t, ValidateSweepObservationBatch(b), "body-owned disposition")
}

// UUIDv7Nanos is the ONE checked conversion. A 48-bit timestamp can encode
// ~281474976710655 ms; int64 nanos top out near 9223372036854 ms, so most of
// the encodable range overflows. An unchecked `ms * 1e6` WRAPS -- and the vector
// below is built so the wrapped value is small and positive, i.e. lands INSIDE a
// window it should have been refused by. An overflow that wrapped to something
// out of range would be refused either way and prove nothing.
func TestUUIDv7NanosRejectsOverflow(t *testing.T) {
	// 18446744073710 ms is past the checked bound, is encodable in 48 bits, and
	// its unchecked product wraps to a SMALL POSITIVE nanosecond value near the
	// epoch -- i.e. one a collection window can plausibly contain.
	// A VARIABLE, not a const: Go evaluates constant arithmetic in arbitrary
	// precision and rejects the overflow at compile time, which would hide the
	// very wrap this vector exists to model.
	ms := int64(18446744073710)

	if ms <= maxUUIDv7Millis {
		t.Fatalf("test setup: %d is not past the checked bound %d", ms, maxUUIDv7Millis)
	}
	if ms > 1<<48-1 {
		t.Fatalf("test setup: %d is not encodable in 48 bits, so no real UUIDv7 reaches it", ms)
	}
	// The wrap must be POSITIVE and SMALL. A negative or huge wrapped value would
	// be refused by a window check anyway, so it could not distinguish a checked
	// conversion from an unchecked one.
	wrapped := ms * 1_000_000 //nolint:gosec // deliberate: this models the UNCHECKED conversion
	if wrapped <= 0 || wrapped > int64(time.Second) {
		t.Fatalf("test setup: unchecked multiply yields %d, which no window would accept anyway", wrapped)
	}

	id := uuidV7WithMillis(t, ms)
	if _, err := UUIDv7Nanos(id); !errors.Is(err, ErrUUIDv7TimeRange) {
		t.Fatalf("want ErrUUIDv7TimeRange for an overflowing timestamp, got %v", err)
	}

	// The same id must still decode as MILLISECONDS -- the value is a valid
	// UUIDv7, so this is a conversion-range failure, not a structural one.
	if _, err := UUIDv7Millis(id); err != nil {
		t.Fatalf("overflowing id must still be structurally valid: %v", err)
	}
}

// The largest convertible timestamp is ACCEPTED. Without this a guard that
// rejected everything would pass the overflow test above.
func TestUUIDv7NanosAcceptsMaximum(t *testing.T) {
	id := uuidV7WithMillis(t, maxUUIDv7Millis)
	ns, err := UUIDv7Nanos(id)
	if err != nil {
		t.Fatalf("maximum convertible timestamp must be accepted: %v", err)
	}
	if ns != maxUUIDv7Millis*1_000_000 {
		t.Fatalf("ns = %d, want %d", ns, maxUUIDv7Millis*1_000_000)
	}
}

// uuidV7WithMillis builds a structurally valid UUIDv7 carrying an exact
// millisecond timestamp.
func uuidV7WithMillis(t *testing.T, ms int64) []byte {
	t.Helper()
	if ms < 0 || ms > 1<<48-1 {
		t.Fatalf("ms %d is not encodable in 48 bits", ms)
	}
	out := make([]byte, 16)
	for i := 0; i < 6; i++ {
		out[i] = byte(ms >> (40 - 8*i))
	}
	for i := 6; i < 16; i++ {
		out[i] = byte(i)
	}
	out[6] = (out[6] & 0x0F) | 0x70
	out[8] = (out[8] & 0x3F) | 0x80
	if err := ValidateUUIDv7(out); err != nil {
		t.Fatalf("constructed id is not a valid UUIDv7: %v", err)
	}
	got, err := UUIDv7Millis(out)
	if err != nil || got != ms {
		t.Fatalf("constructed id decodes to %d (err %v), want %d", got, err, ms)
	}
	return out
}

// assertDispositionRejection pins the LABEL and the OWNING GATE together. Asserting
// only the gate leaves the pair unpinned: the body validator could emit any label
// with the right sentinel and stay green.
func assertDispositionRejection(t *testing.T, err error, ctx string) {
	t.Helper()
	if !errors.Is(err, ErrSweepSourceRunID) {
		t.Fatalf("%s: want ErrSweepSourceRunID, got %v", ctx, err)
	}
	if errors.Is(err, ErrSweepJoin) {
		t.Fatalf("%s: a BODY rejection must not also be a correlation one: %v", ctx, err)
	}
	got, ok := SweepLabelOf(err)
	if !ok {
		t.Fatalf("%s: rejection carries no portable label: %v", ctx, err)
	}
	if got != SweepLabelSourceRunIDDisposition {
		t.Fatalf("%s: label = %q, want %q", ctx, got, SweepLabelSourceRunIDDisposition)
	}
}
