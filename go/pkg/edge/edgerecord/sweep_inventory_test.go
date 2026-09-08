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
	"sort"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// THE FROZEN MATRIX, WRITTEN OUT AS LITERALS.
//
// This inventory exists because VECTORS SAMPLE. Only an exhaustive listing shows
// the mapping is TOTAL over the declared sources, INJECTIVE into kinds, and that
// the two unreachable kinds are absent from its range -- a vector set cannot
// establish absence.
//
// The inventory has TWO parts and only ONE is descriptor-derived:
//
//   - SOURCE and KIND are enum domains, so they are checked against the GENERATED
//     DESCRIPTORS below and a renumbering or a new member fails.
//   - OPERAND and DISPOSITION are NOT enum domains and no descriptor knows them.
//     They are literal table entries, exactly like the frozen field inventories
//     elsewhere in this change. A descriptor check over the operand column would
//     assert nothing.
//
// These literals are deliberately NOT derived from sweepSourceMatrix: a test that
// reads the table it is checking passes for any table.
//
//nolint:gochecknoglobals // immutable frozen inventory
var frozenSweepMatrix = []struct {
	source      string
	sourceNum   int32
	kind        string
	kindNum     int32
	operand     sweepContextOperand
	sourceRunID sourceRunIDDisposition
}{
	{"SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP", 1, "EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP", 1, operandExecutionID, sourceRunIDForbidden},
	{"SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE", 2, "EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE", 2, operandExecutionID, sourceRunIDForbidden},
	{"SWEEP_EXECUTION_SOURCE_AD_HOC", 3, "EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC", 4, operandSourceRunID, sourceRunIDRequired},
	{"SWEEP_EXECUTION_SOURCE_ON_DEMAND", 4, "EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND", 5, operandSourceRunID, sourceRunIDRequired},
	{"SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK", 5, "EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK", 3, operandSourceRunID, sourceRunIDRequired},
}

// The two kinds that exist on the wire but are OUTSIDE this mapping's range.
//
//nolint:gochecknoglobals // immutable frozen inventory
var unreachableKinds = []string{
	"EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN",
	"EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL",
}

func sourceEnum() protoreflect.EnumDescriptor {
	return edgev1.SweepExecutionSource(0).Descriptor()
}

func kindEnum() protoreflect.EnumDescriptor {
	return edgev1.EdgeSourceAuthorizationKind(0).Descriptor()
}

// The SOURCE and KIND columns are checked against the generated descriptors, so a
// renumbering or a rename fails here rather than silently changing the contract.
func TestFrozenMatrixNamesAndNumbersMatchDescriptors(t *testing.T) {
	src, kind := sourceEnum(), kindEnum()
	for _, row := range frozenSweepMatrix {
		sv := src.Values().ByName(protoreflect.Name(row.source))
		if sv == nil {
			t.Fatalf("source %s is not a generated member", row.source)
		}
		if int32(sv.Number()) != row.sourceNum {
			t.Fatalf("source %s: descriptor number %d, frozen %d", row.source, sv.Number(), row.sourceNum)
		}
		kv := kind.Values().ByName(protoreflect.Name(row.kind))
		if kv == nil {
			t.Fatalf("kind %s is not a generated member", row.kind)
		}
		if int32(kv.Number()) != row.kindNum {
			t.Fatalf("kind %s: descriptor number %d, frozen %d", row.kind, kv.Number(), row.kindNum)
		}
	}
	for _, name := range unreachableKinds {
		if kindEnum().Values().ByName(protoreflect.Name(name)) == nil {
			t.Fatalf("unreachable kind %s is not a generated member; the exclusion below would be vacuous", name)
		}
	}
}

// enumMembers lists every generated member name of an enum.
func enumMembers(d protoreflect.EnumDescriptor) []string {
	vals := d.Values()
	out := make([]string, 0, vals.Len())
	for i := 0; i < vals.Len(); i++ {
		out = append(out, string(vals.Get(i).Name()))
	}
	sort.Strings(out)
	return out
}

// BOTH GENERATED ENUM DOMAINS ARE PARTITIONED EXHAUSTIVELY against literals.
//
// Checking only that the five expected rows exist is not a totality proof: a NEW
// generated source or kind passes it untouched. Worse, an inventory that walks
// only its own expectation lists is vacuous if one of those lists shrinks --
// deleting an entry from the unreachable set silently removed its check, which is
// what this partition closes.
//
// So every member of each enum must appear in EXACTLY ONE literal bucket, and the
// buckets must together equal the generated domain. A new member fails until it is
// classified deliberately.
func TestGeneratedEnumDomainsArePartitionedExhaustively(t *testing.T) {
	t.Run("sources", func(t *testing.T) {
		mapped := make([]string, 0, len(frozenSweepMatrix))
		for _, r := range frozenSweepMatrix {
			mapped = append(mapped, r.source)
		}
		// UNSPECIFIED is deliberately UNMAPPED: it is the proto default, so an unset
		// field must not select a mapping.
		want := append([]string{"SWEEP_EXECUTION_SOURCE_UNSPECIFIED"}, mapped...)
		sort.Strings(want)
		assertPartition(t, "SweepExecutionSource", enumMembers(sourceEnum()), want)
	})

	t.Run("kinds", func(t *testing.T) {
		mapped := make([]string, 0, len(frozenSweepMatrix))
		for _, r := range frozenSweepMatrix {
			mapped = append(mapped, r.kind)
		}
		want := append([]string{"EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED"}, mapped...)
		want = append(want, unreachableKinds...)
		sort.Strings(want)
		assertPartition(t, "EdgeSourceAuthorizationKind", enumMembers(kindEnum()), want)
	})
}

// assertPartition fails if the generated domain and the literal partition differ
// in EITHER direction: a new generated member is unclassified, and a literal that
// names no generated member would make its own checks vacuous.
func assertPartition(t *testing.T, name string, generated, want []string) {
	t.Helper()
	inWant := map[string]bool{}
	for _, w := range want {
		inWant[w] = true
	}
	inGen := map[string]bool{}
	for _, g := range generated {
		inGen[g] = true
	}
	for _, g := range generated {
		if !inWant[g] {
			t.Fatalf("%s: generated member %s is in no literal bucket; classify it as mapped, unreachable, or unspecified", name, g)
		}
	}
	for _, w := range want {
		if !inGen[w] {
			t.Fatalf("%s: literal %s names no generated member, so every check over it is vacuous", name, w)
		}
	}
	if len(want) != len(inWant) {
		t.Fatalf("%s: the literal partition lists a member twice", name)
	}
}

// INJECTIVE: no two sources map to the same kind. A collapsed pair would let one
// source's authority authorize another's body.
func TestFrozenMatrixIsInjective(t *testing.T) {
	seen := map[string]string{}
	for _, r := range frozenSweepMatrix {
		if prev, dup := seen[r.kind]; dup {
			t.Fatalf("kind %s is mapped from both %s and %s", r.kind, prev, r.source)
		}
		seen[r.kind] = r.source
	}
}

// ABSENT FROM THE RANGE: the two unreachable kinds are mapped from no source.
// This is the property a vector set cannot establish, which is why the inventory
// exists.
func TestUnreachableKindsAreOutsideTheRange(t *testing.T) {
	for _, name := range unreachableKinds {
		for _, r := range frozenSweepMatrix {
			if r.kind == name {
				t.Fatalf("%s is reachable from source %s, but is declared unreachable", name, r.source)
			}
		}
	}
}

// THE IMPLEMENTATION AGREES WITH THE FROZEN LITERALS, in all four columns. This
// is what connects the inventory above to the behaviour: sweepSourceMatrix is the
// SOLE kind lookup in the correlation, so the inventory's coverage is the
// behaviour's coverage.
func TestImplementationMatchesFrozenMatrix(t *testing.T) {
	if len(sweepSourceMatrix) != len(frozenSweepMatrix) {
		t.Fatalf("implementation has %d rows, frozen inventory has %d", len(sweepSourceMatrix), len(frozenSweepMatrix))
	}
	for _, row := range frozenSweepMatrix {
		src := edgev1.SweepExecutionSource(row.sourceNum)
		got, ok := sweepRuleFor(src)
		if !ok {
			t.Fatalf("%s: implementation has no row", row.source)
		}
		if int32(got.kind) != row.kindNum {
			t.Fatalf("%s: implementation kind %d, frozen %d", row.source, got.kind, row.kindNum)
		}
		if got.operand != row.operand {
			t.Fatalf("%s: implementation operand %d, frozen %d", row.source, got.operand, row.operand)
		}
		if got.sourceRunID != row.sourceRunID {
			t.Fatalf("%s: implementation disposition %d, frozen %d", row.source, got.sourceRunID, row.sourceRunID)
		}
	}
}

// UNSPECIFIED selects no row. It is the proto default, so accepting it would let
// an unset field choose a mapping.
func TestUnspecifiedSourceHasNoRow(t *testing.T) {
	if _, ok := sweepRuleFor(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_UNSPECIFIED); ok {
		t.Fatal("UNSPECIFIED must not select a matrix row")
	}
}

// THE FIFTEEN LABEL NAMES ARE FROZEN AS AN EXACT SET.
//
// A SET, not a sequence: the shared vector manifest that would give an ORDER its
// authority does not exist yet, and the spec's prose enumerates them in a
// different sequence from this file. Asserting an order none of those three agree
// on would pin an accident. When the manifest lands and freezes an order, this
// becomes an ordered comparison.
//
// The literal is written out rather than derived from the constants it checks: a
// test that reads its own subject passes for any subject.
func TestFrozenLabelSet(t *testing.T) {
	want := []string{
		"assignment_epoch", "batch_time_window", "context_id", "execution_shard",
		"host_time_overflow", "host_time_window", "plan_digest", "range_id",
		"scope_digest", "source_authority_absent", "source_kind",
		"source_run_id_disposition", "target_range_digest", "trace_time_overflow",
		"trace_time_window",
	}
	if len(want) != 15 {
		t.Fatalf("the frozen set is FIFTEEN labels; this list has %d", len(want))
	}

	// `got` comes from the PRODUCTION registry, not a second hand-built list. An
	// earlier version constructed both sides here, so a sixteenth constant added to
	// the implementation left this green.
	got := map[string]bool{}
	for _, l := range SweepLabels() {
		if got[string(l)] {
			t.Fatalf("the registry lists %q twice", l)
		}
		got[string(l)] = true
	}
	wantSet := map[string]bool{}
	for _, w := range want {
		if wantSet[w] {
			t.Fatalf("the frozen literal lists %q twice", w)
		}
		wantSet[w] = true
	}
	for w := range wantSet {
		if !got[w] {
			t.Fatalf("frozen label %q is not in the registry", w)
		}
	}
	for g := range got {
		if !wantSet[g] {
			t.Fatalf("the registry carries %q, which is not a frozen label", g)
		}
	}
}

// A label outside the registry cannot be emitted. This is what makes a stray
// constant INERT rather than silently live: the inventory above compares the
// registry, so an unregistered constant is invisible to it, and this guard is why
// that is safe.
func TestUnregisteredLabelCannotBeEmitted(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("emitting an unregistered label must panic")
		}
	}()
	_ = sweepJoinErr(SweepJoinLabel("not_a_registered_label"))
}

// EACH GUARD IS PROVEN INDEPENDENTLY. All three are in-package because each needs
// an unexported type or helper -- the typed-nil and registry cases construct
// *sweepJoinError directly, and the nil-gate case calls sweepBodyErr. The external
// test cannot reach any of them, which is why it makes no claim about them.

// A TYPED NIL satisfies errors.As and sets the target to nil, so SweepLabelOf must
// check for it before reading the label. Without the check this panics.
func TestSweepLabelOfHandlesTypedNil(t *testing.T) {
	var e *sweepJoinError
	l, ok := SweepLabelOf(e)
	if ok || l != "" {
		t.Fatalf("typed nil reported %q, %v; want \"\", false", l, ok)
	}
}

// The REGISTRY RE-CHECK inside SweepLabelOf, proven on its own. Constructed here
// directly, bypassing the constructor, which is the only way to reach a label the
// registry does not carry -- so this is the one path that exercises that branch.
func TestSweepLabelOfRejectsAnUnregisteredLabel(t *testing.T) {
	e := &sweepJoinError{label: SweepJoinLabel("not_registered"), gate: ErrSweepJoin}
	if l, ok := SweepLabelOf(e); ok {
		t.Fatalf("an unregistered label was reported as frozen: %q", l)
	}
	// A registered label on the same shape IS reported, so the test above is not
	// passing because SweepLabelOf refuses everything.
	e2 := &sweepJoinError{label: SweepLabelContextID, gate: ErrSweepJoin}
	if l, ok := SweepLabelOf(e2); !ok || l != SweepLabelContextID {
		t.Fatalf("a registered label was not reported: %q, %v", l, ok)
	}
}

// The NIL-GATE constructor check, proven on its own. A labelled rejection with no
// gate would panic later in Error(), far from the site that built it.
func TestLabelledErrorRequiresAGate(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("building a labelled rejection with a nil gate must panic")
		}
	}()
	_ = sweepBodyErr(SweepLabelSourceRunIDDisposition, nil)
}
