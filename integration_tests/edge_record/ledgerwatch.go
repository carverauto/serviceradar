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
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ledgerwatch.go observes the gateway's :bulk lane accountant for Groups E
// and F, through ServiceRadar.Edge.PublisherPool.ledger/1 over the gateway
// release's `rpc`.
//
// WHY ONE LONG rpc AND NOT ONE rpc PER READ. Every `bin/<release> rpc` boots
// a hidden BEAM node, which costs a second or more. The requests these groups
// observe are in flight for five seconds (JetStreamPublisher's receive
// timeout), so a handful of per-read rpc calls can straddle the whole window
// and observe nothing. The watcher is instead ONE rpc that stays inside the
// gateway node, samples the ledger every few milliseconds, and records every
// CHANGE as a trace it prints as JSON when told to stop.
//
// The test and the watcher coordinate through files in a directory both can
// see (the gateway release is a local subprocess):
//
//   - the watcher writes a marker file when it sees a condition the test must
//     wait for (ledgerMarkerActive, ledgerMarkerOwnerExited, ...);
//   - the test writes "event-<name>" when it has finished an action, and the
//     watcher records it in the trace BEFORE the next sample, and always
//     records that next sample even when nothing changed. The first sample
//     after an event therefore reflects the ledger after that action, with no
//     clock shared between the processes;
//   - "stop" ends the watch.
//
// The analyzers at the bottom of this file are pure functions over the parsed
// trace, so ledgerwatch_selfcheck_test.go can prove each check fails on the
// trace it exists to reject.

// Marker names the watcher writes. Per-spool markers are suffixed with the
// spool id in lower-case hex.
const (
	ledgerMarkerReady               = "ready"
	ledgerMarkerKilled              = "killed"
	ledgerMarkerReplacementAccepted = "replacement-accepting"
	ledgerMarkerConnectionReplaced  = "connection-replaced"
	ledgerMarkerActive              = "active-"
	ledgerMarkerReactivated         = "reactivated-"
	ledgerMarkerIdle                = "idle-"
	ledgerMarkerReleased            = "released-"
	ledgerMarkerOwnerExited         = "owner-exited-"
	// ledgerMarkerRecorded is written once an "event-<name>" file has been
	// recorded in the trace, so the test can wait for its event to be
	// ordered before it changes the ledger again.
	ledgerMarkerRecorded = "recorded-"

	ledgerEventPrefix = "event-"
	ledgerStopFile    = "stop"

	ledgerKindSample = "sample"
	ledgerKindEvent  = "event"

	// ledgerEventKilled is recorded by the watcher itself, immediately after
	// the sample it acted on.
	ledgerEventKilled = "killed"
)

var (
	errLedgerWatchNoJSON  = errors.New("verticalslice: ledger watcher printed no JSON trace")
	errLedgerWatchTimeout = errors.New("verticalslice: ledger watcher hit its own deadline before being stopped")
	errLedgerWatchExited  = errors.New("verticalslice: ledger watcher exited without writing marker")
	errLedgerMarkerWait   = errors.New("verticalslice: ledger watcher marker not written in time")
)

// ledgerKillDwell is how long every kill-set attempt must have been active
// before the watcher kills the lane's transport. An attempt turns :active when
// the pool handles the :confirm_admission that PublisherPool.admit/4 casts,
// which is BEFORE JetStreamPublisher.publish_record issues request/5 on its
// captured connection pid. A kill inside that gap fails the request at once
// instead of leaving it in flight, so its owner exits within milliseconds and
// races the replacement generation. 250ms is well inside the 5s receive
// timeout that keeps a request that did reach the connection in flight.
const ledgerKillDwell = 250 * time.Millisecond

// ledgerWatchExprTemplate is the Elixir the watcher runs inside the gateway
// node. Parameters, in order: base64 of the marker directory, comma-separated
// hex spool ids to watch, comma-separated hex spool ids whose attempts must
// ALL have been active for the kill dwell before the watcher kills the lane's
// transport (empty: never kill), that dwell in milliseconds, and the
// watcher's own deadline in milliseconds. None of them is ever spliced into
// source unencoded.
const ledgerWatchExprTemplate = `
alias ServiceRadar.Edge.{LaneTransportRuntime, PublisherLane, PublisherPool}
pool = PublisherPool.via(:bulk)
dir = Base.decode64!("%s")
watched = String.split("%s", ",", trim: true)
kill_set = String.split("%s", ",", trim: true)
kill_dwell = %d
started = System.monotonic_time(:millisecond)
deadline = started + %d
hex = fn b -> Base.encode16(b, case: :lower) end
mark = fn st, name ->
  if MapSet.member?(st.marks, name) do
    st
  else
    File.write!(Path.join(dir, name), "")
    %%{st | marks: MapSet.put(st.marks, name)}
  end
end
append = fn st, entry ->
  %%{st | trace: [Map.put(entry, :at_ms, System.monotonic_time(:millisecond) - started) | st.trace]}
end
conn_pid = fn -> Process.whereis(PublisherLane.connection_name(:bulk)) end
File.write!(Path.join(dir, "ready"), "")
loop = fn loop, st ->
  events =
    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "event-"))
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(st.events, &1))
  st =
    Enum.reduce(events, st, fn name, st ->
      st
      |> append.(%%{kind: "event", event: String.replace_prefix(name, "event-", "")})
      |> Map.update!(:events, &MapSet.put(&1, name))
      |> Map.put(:last, nil)
      |> mark.("recorded-" <> String.replace_prefix(name, "event-", ""))
    end)
  stopping = File.exists?(Path.join(dir, "stop"))
  l = PublisherPool.ledger(pool)
  now = System.monotonic_time(:millisecond)
  mine =
    for %%{key: {{_scope, _agent, spool, seq}, _fp}} = r <- l.reservations, hex.(spool) in watched, into: %%{} do
      {hex.(spool), Map.put(r, :sequence, seq)}
    end
  active = for {s, %%{attempt: %%{phase: :active} = a}} <- mine, into: %%{}, do: {s, a}
  st = %%{st | owners: Map.merge(Map.new(active, fn {s, a} -> {s, a.owner} end), st.owners),
               first_tokens: Map.merge(Map.new(active, fn {s, a} -> {s, a.token} end), st.first_tokens),
               first_active: Map.merge(Map.new(active, fn {s, _a} -> {s, now} end), st.first_active)}
  reservations =
    for {s, r} <- Enum.sort(mine) do
      %%{spool: s, sequence: r.sequence, bytes: r.bytes,
        phase: r.attempt && r.attempt.phase,
        token: r.attempt && r.attempt.token,
        owner: r.attempt && inspect(r.attempt.owner),
        on_accepting: r.attempt != nil and r.attempt.generation === l.accepting}
    end
  first_owners =
    for {s, p} <- Enum.sort(st.owners) do
      %%{spool: s, owner: inspect(p), alive: Process.alive?(p)}
    end
  sample = %%{
    kind: "sample",
    pool: inspect(Process.whereis(pool)),
    accepting: l.accepting && inspect(l.accepting),
    frame_credits: l.frame_credits,
    byte_credits: l.byte_credits,
    outstanding_frames: l.outstanding_frames,
    outstanding_bytes: l.outstanding_bytes,
    available_frames: l.available_frames,
    available_bytes: l.available_bytes,
    reservations: reservations,
    first_owners: first_owners
  }
  st = if sample == st.last, do: st, else: %%{append.(st, sample) | last: sample}
  st =
    Enum.reduce(watched, st, fn s, st ->
      r = Map.get(mine, s)
      seen = Map.has_key?(st.first_tokens, s)
      owner = Map.get(st.owners, s)
      st
      |> then(fn st -> if match?(%%{attempt: %%{phase: :active}}, r), do: mark.(st, "active-" <> s), else: st end)
      |> then(fn st -> if match?(%%{attempt: %%{phase: :active}}, r) and r.attempt.token != st.first_tokens[s], do: mark.(st, "reactivated-" <> s), else: st end)
      |> then(fn st -> if seen and match?(%%{attempt: nil}, r), do: mark.(st, "idle-" <> s), else: st end)
      |> then(fn st -> if seen and r == nil, do: mark.(st, "released-" <> s), else: st end)
      |> then(fn st -> if owner != nil and not Process.alive?(owner), do: mark.(st, "owner-exited-" <> s), else: st end)
    end)
  st =
    case st.killed do
      nil -> st
      k ->
        st
        |> then(fn st -> if l.accepting != nil and l.accepting !== k.accepting, do: mark.(st, "replacement-accepting"), else: st end)
        |> then(fn st ->
          c = conn_pid.()
          if is_pid(c) and c !== k.conn and Process.alive?(c), do: mark.(st, "connection-replaced"), else: st
        end)
    end
  st =
    if st.killed == nil and kill_set != [] and
         Enum.all?(kill_set, &(Map.has_key?(active, &1) and now - st.first_active[&1] >= kill_dwell)) do
      transport = Process.whereis(LaneTransportRuntime.via(:bulk)) || raise "no :bulk lane transport registered"
      killed = %%{accepting: l.accepting, conn: conn_pid.(), transport: transport}
      Process.exit(transport, :kill)
      %%{append.(st, %%{kind: "event", event: "killed"}) | killed: killed, last: nil} |> mark.("killed")
    else
      st
    end
  cond do
    stopping -> {false, st}
    System.monotonic_time(:millisecond) > deadline -> {true, st}
    true ->
      Process.sleep(5)
      loop.(loop, st)
  end
end
{timed_out, st} =
  loop.(loop, %%{trace: [], last: nil, marks: MapSet.new(), events: MapSet.new(), owners: %%{}, first_tokens: %%{}, first_active: %%{}, killed: nil})
IO.puts(JSON.encode!(%%{timed_out: timed_out, trace: Enum.reverse(st.trace)}))
`

// buildLedgerWatchExpr renders the watcher for markerDir, watching the given
// spool ids and, when killWhenActive is non-empty, killing the :bulk lane's
// transport generation the first time every one of those spools has held an
// active attempt for ledgerKillDwell.
func buildLedgerWatchExpr(markerDir string, watched, killWhenActive [][]byte, deadlineMS int64) string {
	return fmt.Sprintf(ledgerWatchExprTemplate,
		base64.StdEncoding.EncodeToString([]byte(markerDir)),
		joinHex(watched), joinHex(killWhenActive), ledgerKillDwell.Milliseconds(), deadlineMS)
}

func joinHex(ids [][]byte) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = hex.EncodeToString(id)
	}
	return strings.Join(parts, ",")
}

// ledgerTrace is the watcher's output: every distinct ledger state it saw for
// the watched spools, interleaved with the events it recorded.
type ledgerTrace struct {
	TimedOut bool               `json:"timed_out"`
	Entries  []ledgerTraceEntry `json:"trace"`
}

type ledgerTraceEntry struct {
	Kind  string `json:"kind"` // "sample" or "event"
	Event string `json:"event,omitempty"`

	// Pool is the accountant's pid. A change means the accountant was
	// restarted, and a restarted accountant starts from an empty ledger.
	Pool string `json:"pool,omitempty"`
	// Accepting is the transport generation admissions are issued against,
	// or nil while no transport is registered.
	Accepting *string `json:"accepting,omitempty"`

	FrameCredits     int64 `json:"frame_credits"`
	ByteCredits      int64 `json:"byte_credits"`
	OutstandingBytes int64 `json:"outstanding_bytes"`

	Reservations []ledgerReservation `json:"reservations"`
	// FirstOwners is the first process seen owning an active attempt for
	// each watched spool, and whether it is still alive. It outlives the
	// attempt in the ledger, which is what shows a request still running
	// after its attempt was fenced.
	FirstOwners []ledgerOwner `json:"first_owners"`
}

type ledgerReservation struct {
	Spool       string  `json:"spool"`
	Bytes       int64   `json:"bytes"`
	Phase       *string `json:"phase"`
	Token       *int64  `json:"token"`
	Owner       *string `json:"owner"`
	OnAccepting bool    `json:"on_accepting"`
}

type ledgerOwner struct {
	Spool string `json:"spool"`
	Owner string `json:"owner"`
	Alive bool   `json:"alive"`
}

func (e *ledgerTraceEntry) reservation(spool string) (ledgerReservation, bool) {
	for _, r := range e.Reservations {
		if r.Spool == spool {
			return r, true
		}
	}
	return ledgerReservation{}, false
}

// ownerAlive reports whether spool's first owner is alive, and whether the
// watcher had seen one at all.
func (e *ledgerTraceEntry) ownerAlive(spool string) (alive, known bool) {
	for _, o := range e.FirstOwners {
		if o.Spool == spool {
			return o.Alive, true
		}
	}
	return false, false
}

func (r ledgerReservation) active() bool { return r.Phase != nil && *r.Phase == "active" }

func (r ledgerReservation) idle() bool { return r.Phase == nil }

func (r ledgerReservation) token() int64 {
	if r.Token == nil {
		return 0
	}
	return *r.Token
}

func (r ledgerReservation) owner() string {
	if r.Owner == nil {
		return ""
	}
	return *r.Owner
}

func strPtrValue(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

// parseLedgerTrace extracts the watcher's JSON line from rpc output.
func parseLedgerTrace(out string) (*ledgerTrace, error) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var tr ledgerTrace
		if err := json.Unmarshal([]byte(line), &tr); err != nil {
			return nil, fmt.Errorf("verticalslice: decode ledger trace: %w", err)
		}
		if tr.TimedOut {
			return &tr, errLedgerWatchTimeout
		}
		return &tr, nil
	}
	return nil, errLedgerWatchNoJSON
}

func (tr *ledgerTrace) eventIndex(name string, from int) int {
	for i := from; i < len(tr.Entries); i++ {
		if tr.Entries[i].Kind == ledgerKindEvent && tr.Entries[i].Event == name {
			return i
		}
	}
	return -1
}

// sampleIndex returns the first sample at or after from satisfying pred, or
// -1.
func (tr *ledgerTrace) sampleIndex(from int, pred func(*ledgerTraceEntry) bool) int {
	for i := from; i < len(tr.Entries); i++ {
		if tr.Entries[i].Kind == ledgerKindSample && pred(&tr.Entries[i]) {
			return i
		}
	}
	return -1
}

// lastSampleBefore returns the last sample strictly before idx, or -1.
func (tr *ledgerTrace) lastSampleBefore(idx int) int {
	for i := idx - 1; i >= 0; i-- {
		if tr.Entries[i].Kind == ledgerKindSample {
			return i
		}
	}
	return -1
}

func (tr *ledgerTrace) lastSample() int { return tr.lastSampleBefore(len(tr.Entries)) }

// restartOverlapPlan names the spools Group E drives.
type restartOverlapPlan struct {
	// InFlight are the publications held in flight when the transport is
	// killed.
	InFlight []string
	// Readmitted is the in-flight publication retried after termination, on
	// the replacement transport.
	Readmitted string
	// NewWork is a fresh publication admitted beside it.
	NewWork string
	// ReadmittedEvent is recorded by the test once both are observed active.
	ReadmittedEvent string
}

// analyzeRestartOverlap checks Group E's claim against a watcher trace:
//
//  1. every in-flight publication holds an active attempt on the accepting
//     generation, and then the watcher kills that generation's transport;
//  2. once a REPLACEMENT generation is accepting -- while every in-flight
//     request's owner is still alive -- the SAME accountant still charges
//     every in-flight reservation, so the replacement cannot have reopened
//     that capacity, and none of those attempts is on the replacement;
//  3. after every owner has exited (termination observed) the charges are
//     still held, with no attempt;
//  4. the replacement then admits work within the original grant: the
//     terminated publication is re-admitted as a new attempt on the SAME
//     reservation (never released in between, so no second credit), next to
//     new work, with the in-flight charges still counted and the grant
//     unchanged;
//  5. everything settles.
//
// It returns every violation found; an empty result means the claim held.
func analyzeRestartOverlap(tr *ledgerTrace, plan restartOverlapPlan) []string {
	c := &restartOverlapCheck{tr: tr, plan: plan, firstTokens: map[string]int64{}}
	if tr.TimedOut {
		c.failf("ledger watcher hit its deadline before the test stopped it")
	}
	kill, ok := c.beforeKill()
	if !ok {
		return c.v
	}
	repIdx, ok := c.replacement(kill)
	if !ok {
		return c.v
	}
	termIdx, ok := c.termination(kill, repIdx)
	if !ok {
		return c.v
	}
	if c.readmission(termIdx) {
		c.settled()
	}
	return c.v
}

// restartOverlapCheck carries Group E's analysis from one phase to the next.
type restartOverlapCheck struct {
	tr   *ledgerTrace
	plan restartOverlapPlan
	v    []string

	// pre is the last sample before the kill, and killedGen its accepting
	// generation.
	pre          *ledgerTraceEntry
	killedGen    string
	firstTokens  map[string]int64
	chargedBytes int64
}

func (c *restartOverlapCheck) failf(format string, args ...any) {
	c.v = append(c.v, fmt.Sprintf(format, args...))
}

// beforeKill checks claim 1 and returns the kill event's index.
func (c *restartOverlapCheck) beforeKill() (int, bool) {
	kill := c.tr.eventIndex(ledgerEventKilled, 0)
	if kill < 0 {
		c.failf("the watcher never killed the lane transport: the in-flight requests were never all observed active at once")
		return 0, false
	}
	preIdx := c.tr.lastSampleBefore(kill)
	if preIdx < 0 {
		c.failf("no ledger sample precedes the transport kill")
		return 0, false
	}
	c.pre = &c.tr.Entries[preIdx]
	if c.pre.Accepting == nil {
		c.failf("before the kill: no transport generation was accepting")
		return 0, false
	}
	c.killedGen = *c.pre.Accepting

	found := len(c.v)
	for _, s := range c.plan.InFlight {
		r, ok := c.pre.reservation(s)
		switch {
		case !ok:
			c.failf("before the kill: in-flight publication %s holds no reservation", s)
		case !r.active() || !r.OnAccepting:
			c.failf("before the kill: %s is not an active attempt on the accepting generation (phase=%s on_accepting=%t)", s, strPtrValue(r.Phase), r.OnAccepting)
		default:
			c.firstTokens[s] = r.token()
			c.chargedBytes += r.Bytes
		}
		if alive, _ := c.pre.ownerAlive(s); !alive {
			c.failf("before the kill: %s's request owner is not alive", s)
		}
	}
	return kill, len(c.v) == found
}

// replacement checks claim 2 at the first sample with a replacement
// generation accepting, and returns its index.
func (c *restartOverlapCheck) replacement(kill int) (int, bool) {
	repIdx := c.tr.sampleIndex(kill, func(e *ledgerTraceEntry) bool {
		return e.Accepting != nil && *e.Accepting != c.killedGen
	})
	if repIdx < 0 {
		c.failf("no replacement transport generation ever became accepting after the kill")
		return 0, false
	}
	rep := &c.tr.Entries[repIdx]
	c.v = append(c.v, sameAccountant("replacement accepting", c.pre, rep)...)
	for _, s := range c.plan.InFlight {
		if alive, _ := rep.ownerAlive(s); !alive {
			c.failf("replacement accepting: %s's request had already terminated, so the replacement was never observed beside an in-flight request", s)
		}
	}
	if rep.OutstandingBytes < c.chargedBytes {
		c.failf("replacement accepting: outstanding_bytes=%d, below the %d bytes the in-flight requests hold -- capacity was reopened", rep.OutstandingBytes, c.chargedBytes)
	}
	return repIdx, true
}

// termination checks claim 3 -- and that every charge was held from the kill
// until then -- and returns the index of the first sample with every owner
// gone.
func (c *restartOverlapCheck) termination(kill, repIdx int) (int, bool) {
	termIdx := c.tr.sampleIndex(repIdx, func(e *ledgerTraceEntry) bool {
		for _, s := range c.plan.InFlight {
			if alive, known := e.ownerAlive(s); !known || alive {
				return false
			}
		}
		return true
	})
	if termIdx < 0 {
		c.failf("the in-flight requests' termination was never observed (their owners never exited)")
		return 0, false
	}
	for i := kill; i <= termIdx; i++ {
		c.heldThroughTermination(i)
	}
	term := &c.tr.Entries[termIdx]
	for _, s := range c.plan.InFlight {
		if r, ok := term.reservation(s); ok && !r.idle() {
			c.failf("termination observed: %s still holds an attempt (phase=%s), want its charge kept with no attempt", s, strPtrValue(r.Phase))
		}
	}
	return termIdx, true
}

// heldThroughTermination checks one sample between the kill and termination:
// every in-flight charge is held, and none of those attempts is on the
// replacement.
func (c *restartOverlapCheck) heldThroughTermination(i int) {
	e := &c.tr.Entries[i]
	if e.Kind != ledgerKindSample {
		return
	}
	label := fmt.Sprintf("sample %d (kill..termination)", i)
	c.v = append(c.v, sameAccountant(label, c.pre, e)...)
	onReplacement := e.Accepting != nil && *e.Accepting != c.killedGen
	for _, s := range c.plan.InFlight {
		r, ok := e.reservation(s)
		switch {
		case !ok:
			c.failf("%s: %s's charge was released while its request was outstanding", label, s)
		case onReplacement && r.OnAccepting:
			c.failf("%s: %s has an attempt on the replacement generation before its request terminated", label, s)
		}
	}
}

// readmission checks claim 4 at the last sample before the re-admission
// event.
func (c *restartOverlapCheck) readmission(termIdx int) bool {
	readmitEvent := c.tr.eventIndex(c.plan.ReadmittedEvent, termIdx)
	if readmitEvent < 0 {
		c.failf("event %q never recorded after termination", c.plan.ReadmittedEvent)
		return false
	}
	rdIdx := c.tr.lastSampleBefore(readmitEvent)
	if rdIdx < termIdx {
		c.failf("no ledger sample between termination and re-admission")
		return false
	}
	rd := &c.tr.Entries[rdIdx]
	c.v = append(c.v, sameAccountant("re-admission", c.pre, rd)...)
	if r, ok := rd.reservation(c.plan.Readmitted); !ok || !r.active() || !r.OnAccepting {
		c.failf("re-admission: %s is not an active attempt on the replacement generation", c.plan.Readmitted)
	} else if r.token() == c.firstTokens[c.plan.Readmitted] {
		c.failf("re-admission: %s still carries its pre-kill attempt token %d, want a new attempt", c.plan.Readmitted, r.token())
	}
	if r, ok := rd.reservation(c.plan.NewWork); !ok || !r.active() || !r.OnAccepting {
		c.failf("re-admission: new work %s is not an active attempt on the replacement generation", c.plan.NewWork)
	}
	for _, s := range c.plan.InFlight {
		if _, ok := rd.reservation(s); !ok {
			c.failf("re-admission: %s's charge is no longer counted", s)
		}
	}
	// The re-admitted publication reused its original charge: its
	// reservation was never released between termination and re-admission.
	for i := termIdx; i <= rdIdx; i++ {
		e := &c.tr.Entries[i]
		if e.Kind != ledgerKindSample {
			continue
		}
		if _, ok := e.reservation(c.plan.Readmitted); !ok {
			c.failf("sample %d: %s was released before re-admission, so its retry took a fresh credit instead of its original charge", i, c.plan.Readmitted)
		}
	}
	return true
}

// settled checks claim 5 on the final sample.
func (c *restartOverlapCheck) settled() {
	final := &c.tr.Entries[c.tr.lastSample()]
	c.v = append(c.v, sameAccountant("final", c.pre, final)...)
	for _, s := range append(append([]string{}, c.plan.InFlight...), c.plan.NewWork) {
		if _, ok := final.reservation(s); ok {
			c.failf("final: %s still holds a reservation, want every publication settled", s)
		}
	}
}

// sameAccountant reports a sample whose accountant or grant differs from the
// reference: either would mean a restart handed out a fresh window.
func sameAccountant(label string, ref, e *ledgerTraceEntry) []string {
	var v []string
	if e.Pool != ref.Pool {
		v = append(v, fmt.Sprintf("%s: the accountant was replaced (pool %s -> %s), and a fresh accountant's empty ledger is the reopened capacity", label, ref.Pool, e.Pool))
	}
	if e.FrameCredits != ref.FrameCredits || e.ByteCredits != ref.ByteCredits {
		v = append(v, fmt.Sprintf("%s: the grant changed (%d frames/%d bytes -> %d/%d)", label, ref.FrameCredits, ref.ByteCredits, e.FrameCredits, e.ByteCredits))
	}
	return v
}

// analyzePostHandoffFencing checks Group F's claim against a watcher trace:
//
//  1. the publication is handed to its request owner: an active attempt with
//     token T1 and owner O1;
//  2. a retry of that publication is answered (retryEvent) while T1 is still
//     the active attempt, O1 still alive and a transport accepting -- so the
//     retry was refused because the attempt is in flight, not for want of
//     transport or credit -- and it never displaced T1;
//  3. the prior request is then fenced: the reservation is still charged with
//     no attempt, and O1 exits;
//  4. after the fence the publication is admitted at most once more (one new
//     token) and settles.
func analyzePostHandoffFencing(tr *ledgerTrace, spool, retryEvent string) []string {
	var v []string
	if tr.TimedOut {
		v = append(v, "ledger watcher hit its deadline before the test stopped it")
	}

	startIdx := tr.sampleIndex(0, func(e *ledgerTraceEntry) bool {
		r, ok := e.reservation(spool)
		return ok && r.active()
	})
	if startIdx < 0 {
		return append(v, "the publication was never observed handed to a request owner (no active attempt)")
	}
	start := &tr.Entries[startIdx]
	first, _ := start.reservation(spool)
	t1, o1 := first.token(), first.owner()

	retryIdx := tr.eventIndex(retryEvent, startIdx)
	if retryIdx < 0 {
		return append(v, fmt.Sprintf("event %q was never recorded after the attempt started", retryEvent))
	}
	afterIdx := tr.sampleIndex(retryIdx, func(*ledgerTraceEntry) bool { return true })
	if afterIdx < 0 {
		return append(v, "no ledger sample follows the refused retry")
	}
	after := &tr.Entries[afterIdx]
	if r, ok := after.reservation(spool); !ok || !r.active() || r.token() != t1 || r.owner() != o1 {
		v = append(v, fmt.Sprintf("after the retry was answered: the prior attempt (token %d, owner %s) is no longer the active attempt, so the retry was not observed refused while it was un-fenced", t1, o1))
	}
	if alive, _ := after.ownerAlive(spool); !alive {
		v = append(v, "after the retry was answered: the prior request's owner had already exited, so the retry was not observed against an un-fenced request")
	}
	if after.Accepting == nil {
		v = append(v, "after the retry was answered: no transport was accepting, so the refusal may have been :no_transport rather than the in-flight attempt")
	}

	fenceIdx := tr.sampleIndex(afterIdx, func(e *ledgerTraceEntry) bool {
		r, ok := e.reservation(spool)
		return ok && r.idle()
	})
	if fenceIdx < 0 {
		return append(v, "the prior request was never observed fenced (its reservation charged with no attempt)")
	}
	// Up to the fence, T1 is the only attempt: nothing displaced it and its
	// charge was never released.
	for i := startIdx; i < fenceIdx; i++ {
		e := &tr.Entries[i]
		if e.Kind != ledgerKindSample {
			continue
		}
		if r, ok := e.reservation(spool); !ok || !r.active() || r.token() != t1 {
			v = append(v, fmt.Sprintf("sample %d: before the fence the publication's attempt is not T1=%d (a retry was admitted beside, or instead of, the un-fenced request)", i, t1))
		}
	}
	ownerExit := tr.sampleIndex(fenceIdx, func(e *ledgerTraceEntry) bool {
		alive, known := e.ownerAlive(spool)
		return known && !alive
	})
	if ownerExit < 0 {
		v = append(v, "the prior request's owner was never observed to exit after the fence")
	}

	newTokens := map[int64]bool{}
	for i := fenceIdx; i < len(tr.Entries); i++ {
		e := &tr.Entries[i]
		if e.Kind != ledgerKindSample {
			continue
		}
		if r, ok := e.reservation(spool); ok && r.active() {
			if r.token() == t1 {
				v = append(v, fmt.Sprintf("sample %d: the fenced attempt T1=%d is active again", i, t1))
			} else {
				newTokens[r.token()] = true
			}
		}
	}
	if len(newTokens) > 1 {
		v = append(v, fmt.Sprintf("after the fence the publication was admitted %d times, want once", len(newTokens)))
	}
	final := &tr.Entries[tr.lastSample()]
	if _, ok := final.reservation(spool); ok {
		v = append(v, "final: the publication still holds a reservation, want the post-fence admission settled")
	}
	return v
}
