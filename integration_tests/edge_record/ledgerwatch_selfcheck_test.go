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

package verticalslice

import (
	"errors"
	"strings"
	"testing"
)

// The analyzers decide Groups E and F on a live run, so each must be shown to
// FAIL on the trace it exists to reject. Every trace here is hand-built: a
// passing shape, then one mutation per claim.

const (
	selfcheckPool = "#PID<0.100.0>"
	selfcheckGen1 = "#Reference<0.1.1.1>"
	selfcheckGen2 = "#Reference<0.2.2.2>"
)

func selfcheckStr(s string) *string { return &s }

func selfcheckInt(n int64) *int64 { return &n }

// selfcheckActive is an active attempt on the sample's accepting generation.
func selfcheckActive(spool string, token int64, owner string) ledgerReservation {
	return ledgerReservation{
		Spool: spool, Sequence: 1, Bytes: 100,
		Phase: selfcheckStr("active"), Token: selfcheckInt(token), Owner: selfcheckStr(owner),
		OnAccepting: true,
	}
}

func selfcheckIdle(spool string) ledgerReservation {
	return ledgerReservation{Spool: spool, Sequence: 1, Bytes: 100}
}

// selfcheckSample builds a sample whose grant is 64 frames and 64 MiB, and
// in which only the listed reservations are outstanding.
func selfcheckSample(accepting string, alive map[string]bool, rs ...ledgerReservation) ledgerTraceEntry {
	e := ledgerTraceEntry{
		Kind: ledgerKindSample, Pool: selfcheckPool,
		FrameCredits: 64, ByteCredits: 64 << 20,
		Reservations: rs,
	}
	if accepting != "" {
		e.Accepting = selfcheckStr(accepting)
	}
	for _, r := range rs {
		e.OutstandingFrames++
		e.OutstandingBytes += r.Bytes
	}
	e.AvailableFrames = e.FrameCredits - e.OutstandingFrames
	e.AvailableBytes = e.ByteCredits - e.OutstandingBytes
	for _, spool := range []string{"a", "b", "c", "d", "e"} {
		if a, ok := alive[spool]; ok {
			e.FirstOwners = append(e.FirstOwners, ledgerOwner{Spool: spool, Owner: "owner-" + spool, Alive: a})
		}
	}
	return e
}

func selfcheckEvent(name string) ledgerTraceEntry {
	return ledgerTraceEntry{Kind: ledgerKindEvent, Event: name}
}

func expectNoViolations(t *testing.T, v []string) {
	t.Helper()
	for _, msg := range v {
		t.Errorf("unexpected violation: %s", msg)
	}
}

func expectViolation(t *testing.T, v []string, want string) {
	t.Helper()
	for _, msg := range v {
		if strings.Contains(msg, want) {
			return
		}
	}
	t.Errorf("no violation mentions %q; got %q", want, v)
}

func selfcheckRestartPlan() restartOverlapPlan {
	return restartOverlapPlan{
		InFlight: []string{"a", "b", "c"}, Readmitted: "a", NewWork: "d", ReadmittedEvent: "readmitted",
	}
}

// restartOverlapTrace is the passing Group E shape; index comments name the
// entries the mutations below edit.
func restartOverlapTrace() *ledgerTrace {
	allAlive := map[string]bool{"a": true, "b": true, "c": true}
	allDead := map[string]bool{"a": false, "b": false, "c": false}
	withNew := map[string]bool{"a": false, "b": false, "c": false, "d": true}
	return &ledgerTrace{Entries: []ledgerTraceEntry{
		/* 0 */ selfcheckSample(selfcheckGen1, allAlive,
			selfcheckActive("a", 1, "owner-a"), selfcheckActive("b", 2, "owner-b"), selfcheckActive("c", 3, "owner-c")),
		/* 1 */ selfcheckEvent(ledgerEventKilled),
		/* 2 */ selfcheckSample("", allAlive, selfcheckIdle("a"), selfcheckIdle("b"), selfcheckIdle("c")),
		/* 3 */ selfcheckSample(selfcheckGen2, allAlive, selfcheckIdle("a"), selfcheckIdle("b"), selfcheckIdle("c")),
		/* 4 */ selfcheckSample(selfcheckGen2, allDead, selfcheckIdle("a"), selfcheckIdle("b"), selfcheckIdle("c")),
		/* 5 */ selfcheckSample(selfcheckGen2, withNew,
			selfcheckActive("a", 4, "owner-a2"), selfcheckIdle("b"), selfcheckIdle("c"), selfcheckActive("d", 5, "owner-d")),
		/* 6 */ selfcheckEvent("readmitted"),
		/* 7 */ selfcheckSample(selfcheckGen2, withNew,
			selfcheckActive("a", 4, "owner-a2"), selfcheckIdle("b"), selfcheckIdle("c"), selfcheckActive("d", 5, "owner-d")),
		/* 8 */ selfcheckSample(selfcheckGen2, map[string]bool{"a": false, "b": false, "c": false, "d": false}),
	}}
}

func TestAnalyzeRestartOverlapAcceptsTheClaim(t *testing.T) {
	expectNoViolations(t, analyzeRestartOverlap(restartOverlapTrace(), selfcheckRestartPlan()))
}

func TestAnalyzeRestartOverlapRejects(t *testing.T) {
	allAlive := map[string]bool{"a": true, "b": true, "c": true}

	cases := []struct {
		name   string
		mutate func(tr *ledgerTrace)
		want   string
	}{
		{
			name: "a replacement that reopens the in-flight capacity",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[3] = selfcheckSample(selfcheckGen2, allAlive, selfcheckIdle("a"))
			},
			want: "released while its request was outstanding",
		},
		{
			name: "a replacement whose byte total hands the charges back",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[3].OutstandingBytes, tr.Entries[3].AvailableBytes = 0, 64<<20
			},
			want: "capacity was reopened",
		},
		{
			name:   "a restarted accountant",
			mutate: func(tr *ledgerTrace) { tr.Entries[3].Pool = "#PID<0.999.0>" },
			want:   "the accountant was replaced",
		},
		{
			name: "a replacement observed only after the requests terminated",
			mutate: func(tr *ledgerTrace) {
				for _, i := range []int{2, 3} {
					for j := range tr.Entries[i].FirstOwners {
						tr.Entries[i].FirstOwners[j].Alive = false
					}
				}
			},
			want: "had already terminated",
		},
		{
			name: "an in-flight attempt moved onto the replacement before termination",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[3].Reservations[0] = selfcheckActive("a", 9, "owner-x")
			},
			want: "attempt on the replacement generation before its request terminated",
		},
		{
			name:   "no kill",
			mutate: func(tr *ledgerTrace) { tr.Entries = append(tr.Entries[:1], tr.Entries[2:]...) },
			want:   "never killed the lane transport",
		},
		{
			name: "a re-admission that took a fresh credit",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[4] = selfcheckSample(selfcheckGen2, map[string]bool{"a": false, "b": false, "c": false},
					selfcheckIdle("b"), selfcheckIdle("c"))
			},
			want: "released before re-admission",
		},
		{
			name: "a re-admission that is still the pre-kill attempt",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[5].Reservations[0] = selfcheckActive("a", 1, "owner-a")
			},
			want: "still carries its pre-kill attempt token",
		},
		{
			name: "work never settled",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[8] = selfcheckSample(selfcheckGen2, nil, selfcheckIdle("b"))
			},
			want: "still holds a reservation",
		},
		{
			name:   "a watcher that timed out",
			mutate: func(tr *ledgerTrace) { tr.TimedOut = true },
			want:   "hit its deadline",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tr := restartOverlapTrace()
			tc.mutate(tr)
			expectViolation(t, analyzeRestartOverlap(tr, selfcheckRestartPlan()), tc.want)
		})
	}
}

// postHandoffFencingTrace is the passing Group F shape.
func postHandoffFencingTrace() *ledgerTrace {
	return &ledgerTrace{Entries: []ledgerTraceEntry{
		/* 0 */ selfcheckSample(selfcheckGen1, nil),
		/* 1 */ selfcheckSample(selfcheckGen1, map[string]bool{"e": true}, selfcheckActive("e", 7, "owner-e")),
		/* 2 */ selfcheckEvent("retry-refused"),
		/* 3 */ selfcheckSample(selfcheckGen1, map[string]bool{"e": true}, selfcheckActive("e", 7, "owner-e")),
		/* 4 */ selfcheckSample(selfcheckGen1, map[string]bool{"e": false}, selfcheckIdle("e")),
		/* 5 */ selfcheckSample(selfcheckGen1, map[string]bool{"e": false}, selfcheckActive("e", 8, "owner-e2")),
		/* 6 */ selfcheckSample(selfcheckGen1, map[string]bool{"e": false}),
	}}
}

func TestAnalyzePostHandoffFencingAcceptsTheClaim(t *testing.T) {
	expectNoViolations(t, analyzePostHandoffFencing(postHandoffFencingTrace(), "e", "retry-refused"))
}

func TestAnalyzePostHandoffFencingRejects(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(tr *ledgerTrace)
		want   string
	}{
		{
			name: "a retry admitted over the un-fenced attempt",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[3] = selfcheckSample(selfcheckGen1, map[string]bool{"e": true}, selfcheckActive("e", 9, "owner-retry"))
			},
			want: "no longer the active attempt",
		},
		{
			name: "a retry answered only after the fence",
			mutate: func(tr *ledgerTrace) {
				e := tr.Entries
				tr.Entries = []ledgerTraceEntry{e[0], e[1], e[4], e[2], e[4], e[5], e[6]}
			},
			want: "owner had already exited",
		},
		{
			name: "a refusal while no transport was accepting",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[3].Accepting = nil
			},
			want: ":no_transport",
		},
		{
			name: "no fence before the next admission",
			mutate: func(tr *ledgerTrace) {
				tr.Entries = append(tr.Entries[:4], tr.Entries[5:]...)
			},
			want: "never observed fenced",
		},
		{
			name: "admitted twice after the fence",
			mutate: func(tr *ledgerTrace) {
				twice := selfcheckSample(selfcheckGen1, map[string]bool{"e": false}, selfcheckActive("e", 10, "owner-e3"))
				tr.Entries = append(tr.Entries[:6], twice, tr.Entries[6])
			},
			want: "admitted 2 times",
		},
		{
			name: "the fenced attempt coming back",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[5].Reservations[0] = selfcheckActive("e", 7, "owner-e")
			},
			want: "is active again",
		},
		{
			name: "never settled",
			mutate: func(tr *ledgerTrace) {
				tr.Entries[6] = selfcheckSample(selfcheckGen1, map[string]bool{"e": false}, selfcheckIdle("e"))
			},
			want: "still holds a reservation",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tr := postHandoffFencingTrace()
			tc.mutate(tr)
			expectViolation(t, analyzePostHandoffFencing(tr, "e", "retry-refused"), tc.want)
		})
	}
}

// TestParseLedgerTrace pins the JSON the Elixir watcher prints -- a hand-built
// line in its exact shape -- and the two ways a watch can come back unusable.
func TestParseLedgerTrace(t *testing.T) {
	out := strings.Join([]string{
		"some unrelated release output",
		`{"timed_out":false,"trace":[` +
			`{"kind":"sample","at_ms":4,"pool":"#PID<0.1.0>","accepting":"#Reference<0.1.2.3>","frame_credits":64,"byte_credits":67108864,` +
			`"outstanding_frames":1,"outstanding_bytes":100,"available_frames":63,"available_bytes":67108764,` +
			`"reservations":[{"spool":"e5","sequence":1,"bytes":100,"phase":"active","token":2,"owner":"#PID<0.2.0>","on_accepting":true}],` +
			`"first_owners":[{"spool":"e5","owner":"#PID<0.2.0>","alive":true}]},` +
			`{"kind":"sample","at_ms":9,"pool":"#PID<0.1.0>","accepting":null,"frame_credits":64,"byte_credits":67108864,` +
			`"outstanding_frames":1,"outstanding_bytes":100,"available_frames":63,"available_bytes":67108764,` +
			`"reservations":[{"spool":"e5","sequence":1,"bytes":100,"phase":null,"token":null,"owner":null,"on_accepting":false}],"first_owners":[]},` +
			`{"kind":"event","event":"retry-refused","at_ms":12}]}`,
	}, "\n")

	tr, err := parseLedgerTrace(out)
	if err != nil {
		t.Fatalf("parseLedgerTrace: %v", err)
	}
	if len(tr.Entries) != 3 {
		t.Fatalf("parsed %d entries, want 3", len(tr.Entries))
	}
	first, ok := tr.Entries[0].reservation("e5")
	if !ok || !first.active() || first.token() != 2 || first.owner() != "#PID<0.2.0>" || !first.OnAccepting {
		t.Errorf("first reservation decoded as %+v", first)
	}
	if alive, known := tr.Entries[0].ownerAlive("e5"); !alive || !known {
		t.Errorf("first owner alive=%t known=%t, want both true", alive, known)
	}
	second, ok := tr.Entries[1].reservation("e5")
	if tr.Entries[1].Accepting != nil || !ok || !second.idle() {
		t.Errorf("second sample decoded as accepting=%v reservation=%+v, want no generation and an idle reservation", tr.Entries[1].Accepting, second)
	}
	if tr.Entries[2].Kind != ledgerKindEvent || tr.Entries[2].Event != "retry-refused" {
		t.Errorf("third entry decoded as %+v", tr.Entries[2])
	}

	if _, err := parseLedgerTrace(`{"timed_out":true,"trace":[]}`); !errors.Is(err, errLedgerWatchTimeout) {
		t.Errorf("timed-out watch returned %v, want errLedgerWatchTimeout", err)
	}
	if _, err := parseLedgerTrace("** (CompileError) nofile:1"); !errors.Is(err, errLedgerWatchNoJSON) {
		t.Errorf("output without a trace returned %v, want errLedgerWatchNoJSON", err)
	}
}
