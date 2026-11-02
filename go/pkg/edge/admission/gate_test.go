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

func TestNewGateRejectsBadWatermarks(t *testing.T) {
	held := func() uint64 { return 0 }
	for name, build := range map[string]func() (*Gate, error){
		"low equals high": func() (*Gate, error) { return NewGate(100, 100, held) },
		"low above high":  func() (*Gate, error) { return NewGate(100, 200, held) },
		"no byte reading": func() (*Gate, error) { return NewGate(100, 50, nil) },
	} {
		if _, err := build(); !errors.Is(err, ErrInvalidGate) {
			t.Errorf("%s: err=%v, want ErrInvalidGate", name, err)
		}
	}
}

// The gate follows the bytes its owner reports: bulk pauses at the high water,
// stays paused while the bytes sit between the marks, resumes at the low water,
// and stays open between the marks until the high water is reached again.
func TestGateBulkHysteresisFollowsTheOwnersBytes(t *testing.T) {
	var held uint64
	g, err := NewGate(800, 400, func() uint64 { return held })
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range []struct {
		held uint64
		want Decision
	}{
		{0, Admit},
		{799, Admit},
		{800, Defer},
		{401, Defer},
		{799, Defer},
		{400, Admit},
		{799, Admit},
		{900, Defer},
	} {
		held = step.held
		if got := g.Admit(ClassBulk); got != step.want {
			t.Fatalf("bulk at %d held = %v, want %v", step.held, got, step.want)
		}
		if g.BulkPaused() != (step.want == Defer) {
			t.Fatalf("BulkPaused at %d held disagrees with Admit", step.held)
		}
	}
}

// A gate first read between the marks starts paused: those bytes may belong to
// a pause the process never saw relieved. At or below the low water it starts
// open.
func TestGateStartsPausedAboveTheLowWater(t *testing.T) {
	for _, tc := range []struct {
		held uint64
		want Decision
	}{
		{400, Admit},
		{401, Defer},
		{799, Defer},
	} {
		g, err := NewGate(800, 400, func() uint64 { return tc.held })
		if err != nil {
			t.Fatal(err)
		}
		if got := g.Admit(ClassBulk); got != tc.want {
			t.Errorf("first read at %d held = %v, want %v", tc.held, got, tc.want)
		}
	}
}

// Only bulk pauses; the byte owner enforces the hard ceiling for every class.
func TestGatePausesOnlyBulk(t *testing.T) {
	g, err := NewGate(800, 400, func() uint64 { return 1000 })
	if err != nil {
		t.Fatal(err)
	}
	for class, want := range map[Class]Decision{
		ClassBulk: Defer, ClassInteractive: Admit, ClassRecovery: Admit, Class(99): Reject,
	} {
		if got := g.Admit(class); got != want {
			t.Errorf("class %d while paused = %v, want %v", class, got, want)
		}
	}
}
