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

// Package admission_test is an EXTERNAL test package: it sees only what any
// other package sees. It exists to check the one property an internal test
// cannot -- that release authority is unreachable from outside.
package admission_test

import (
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/admission"
)

// forgedAuthorization is the embedding attack that defeated the previous seal,
// carried forward as a live regression.
//
// When ReclaimAuthorization was an INTERFACE sealed by an unexported method,
// embedding it -- a nil value was enough -- promoted that method, and overriding
// the three exported accessors produced a fully accepted authorization. It
// released every charged byte while every seal test passed.
//
// Against the opaque carrier the same attack yields nothing: embedding a struct
// promotes its fields for reading, but an external package cannot SET unexported
// fields, cannot write a composite literal for them, and cannot convert a
// same-shaped struct (non-exported field names in different packages are never
// identical). All this type can hand over is the zero carrier.
type forgedAuthorization struct {
	admission.ReclaimAuthorization
	spool           admission.SpoolID
	through, serial uint64
}

// TestExternalForgeryCannotRelease is the reproduction of the P0 that blocked
// this PR, now asserting the opposite outcome.
func TestExternalForgeryCannotRelease(t *testing.T) {
	c, err := admission.NewRestored(admission.Limits{
		Capacity:  1000,
		HighWater: 800,
		LowWater:  400,
	}, admission.Snapshot{})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	key := admission.SlotKey{Spool: "external", Seq: 1}

	r, d := c.Reserve(admission.ClassBulk, 50)
	if d != admission.Admit {
		t.Fatalf("reserve = %v, want Admit", d)
	}

	if err := c.Commit(r, key, 50); err != nil {
		t.Fatalf("commit: %v", err)
	}

	forged := forgedAuthorization{spool: "external", through: 1, serial: 1}

	// The best an external package can present is the embedded ZERO carrier: the
	// fields above are its own, and nothing can copy them into the real one.
	freed, err := c.ApplyReclaim(forged.ReclaimAuthorization)
	if err == nil {
		t.Fatalf("a forged authorization was accepted and freed %d bytes", freed)
	}

	if freed != 0 {
		t.Fatalf("a rejected authorization freed %d bytes, want 0", freed)
	}

	if got := c.TotalHeld(); got != 50 {
		t.Fatalf("TotalHeld=%d after a forgery attempt, want 50 still held", got)
	}
}

// The carrier must expose no settable field, which is what makes it opaque.
//
// Adding one exported field would let any package build a populated
// authorization by composite literal, silently restoring the forgery this PR was
// blocked on -- with no other test noticing.
func TestReclaimAuthorizationHasNoExportedFields(t *testing.T) {
	carrier := reflect.TypeOf(admission.ReclaimAuthorization{})

	if carrier.Kind() != reflect.Struct {
		t.Fatalf("ReclaimAuthorization is a %v; an interface can be satisfied by embedding and is not opaque",
			carrier.Kind())
	}

	for i := range carrier.NumField() {
		if f := carrier.Field(i); f.IsExported() {
			t.Fatalf("ReclaimAuthorization.%s is exported: an external package can now mint its own release "+
				"authority by composite literal", f.Name)
		}
	}
}

// Admission must expose no remote-resolution input at all.
//
// Gateway resolution belongs to gwprefix (task 2.16). A "note it but never read
// it" accessor here was duplicate lifecycle state that contradicted the task
// boundary, and its absence is the proof that no remote signal can reach the
// release path.
func TestNoRemoteResolutionSurface(t *testing.T) {
	ctl := reflect.TypeOf(&admission.Controller{})

	for i := range ctl.NumMethod() {
		name := ctl.Method(i).Name

		for _, banned := range []string{"gateway", "puback", "resolved", "remote"} {
			if strings.Contains(strings.ToLower(name), banned) {
				t.Fatalf("Controller.%s reintroduces remote-resolution surface; that lifecycle belongs to "+
					"gwprefix (2.16), not to byte accounting", name)
			}
		}
	}
}

// An outside caller can drive the whole admission lifecycle EXCEPT release.
//
// This is the shape a production caller has today: it can reserve and charge, and
// it has no reachable way to give the bytes back. That is intentional until task
// 2.28 supplies the authorization producer.
func TestOutsideCallerCanChargeButNotRelease(t *testing.T) {
	c, err := admission.NewRestored(admission.Limits{
		Capacity:  1000,
		HighWater: 800,
		LowWater:  400,
	}, admission.Snapshot{})
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	key := admission.SlotKey{Spool: "gen-external", Seq: 1}

	r, d := c.Reserve(admission.ClassBulk, 500)
	if d != admission.Admit {
		t.Fatalf("reserve = %v, want Admit", d)
	}

	if err := c.Commit(r, key, 500); err != nil {
		t.Fatalf("commit: %v", err)
	}

	if got := c.TotalHeld(); got != 500 {
		t.Fatalf("TotalHeld=%d after an external caller did everything it can, want 500 still held", got)
	}
}
