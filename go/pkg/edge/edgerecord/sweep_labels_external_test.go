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

// Package edgerecord_test is an EXTERNAL test package on purpose. The in-package
// tests can reach unexported identifiers, so they cannot show what an outside
// caller is able to do -- and the registry bypass this file guards was only
// reachable from outside.
package edgerecord_test

import (
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// THE LABEL REGISTRY MUST NOT BE BYPASSABLE FROM OUTSIDE THE PACKAGE.
//
// While the error type was exported with an exported Label field, external code
// could build one directly:
//
//	&edgerecord.SweepJoinError{Label: "future"}
//
// SweepLabelOf then reported "future" as a frozen label, and Error() panicked
// dereferencing the nil gate. The registry and its constructor guard were both
// live, and both were simply routed around.
//
// WHAT THIS FILE DOES AND DOES NOT PROVE, stated plainly so it is not read as
// stronger than it is.
//
// It does NOT detect a future change that re-exports a constructible error type.
// The old expression cannot compile any more, and a test cannot assert that
// something fails to compile; a compile-fail check would need a separate build
// harness this package does not have. If someone re-exports the type, this file
// keeps passing.
//
// What it DOES pin is narrower than that, and only what the assertions below
// actually exercise: SweepLabelOf answers an UNRELATED error and a NIL error
// without panicking and without inventing a label, and SweepLabels() exposes the
// canonical set to an outside caller. That is two inputs, not "hostile input" in
// general.
//
// The GUARDS -- the typed-nil check, the registry re-check, and the constructor's
// nil-gate refusal -- are proven by TestSweepLabelOfHandlesTypedNil,
// TestSweepLabelOfRejectsAnUnregisteredLabel and TestLabelledErrorRequiresAGate in
// sweep_inventory_test.go. All three live in-package because each needs an
// unexported type or helper that this package cannot construct.
func TestLabelsAreOnlyObservableThroughTheAccessor(t *testing.T) {
	// An unrelated error carries no label, and asking does not panic.
	//nolint:err113 // a test INPUT, not an error this code returns
	if l, ok := edgerecord.SweepLabelOf(errors.New("unrelated")); ok {
		t.Fatalf("an unrelated error reported label %q", l)
	}
	// nil is answerable too: callers pass whatever a validator returned.
	if _, ok := edgerecord.SweepLabelOf(nil); ok {
		t.Fatal("nil reported a label")
	}
}

// The canonical set is asserted from OUT HERE as well as in-package, because an
// outside caller sees it through SweepLabels() and that is the surface a consumer
// actually builds against.
func TestCanonicalLabelSetIsVisibleExternally(t *testing.T) {
	labels := edgerecord.SweepLabels()
	if len(labels) != 15 {
		t.Fatalf("SweepLabels() returned %d labels, want the frozen 15", len(labels))
	}
	seen := map[edgerecord.SweepJoinLabel]bool{}
	for _, l := range labels {
		if seen[l] {
			t.Fatalf("SweepLabels() repeats %q", l)
		}
		if l == "" {
			t.Fatal("SweepLabels() contains an empty label")
		}
		seen[l] = true
	}
}
