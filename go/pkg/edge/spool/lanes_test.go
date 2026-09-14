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

package spool

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Synthetic identities: invented UUIDs with valid version/variant bits and an
// invented component id.
func testScope(b byte) []byte {
	id := bytes.Repeat([]byte{b}, 16)
	id[6] = 0x40 | (b & 0x0F)
	id[8] = 0x80 | (b & 0x3F)
	return id
}

func testIdentity(scope byte, agent string) Identity {
	return Identity{NetworkScopeID: testScope(scope), AgentID: []byte(agent)}
}

//nolint:gochecknoglobals // immutable test fixtures
var (
	sessionA = testIdentity(0x11, "agent-test-01")
	sessionB = testIdentity(0x11, "agent-test-02")

	bulkLane = LaneKey{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
	}
	interactiveLane = LaneKey{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE,
	}
	recoveryLane = LaneKey{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE,
	}
	// inactiveLane is well formed but absent from the deployment taxonomy.
	inactiveLane = LaneKey{
		RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1,
		TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
	}
)

func taxonomyOf(t *testing.T, lanes ...LaneKey) *fairsched.LaneTaxonomy {
	t.Helper()
	policies := make([]fairsched.LanePolicy, 0, len(lanes))
	for _, k := range lanes {
		policies = append(policies, fairsched.LanePolicy{Key: k, WeightBytes: 1})
	}
	tax, err := fairsched.NewLaneTaxonomy(policies, recoveryLane)
	if err != nil {
		t.Fatalf("NewLaneTaxonomy: %v", err)
	}
	return tax
}

func deploymentTaxonomy(t *testing.T) *fairsched.LaneTaxonomy {
	t.Helper()
	return taxonomyOf(t, bulkLane, interactiveLane, recoveryLane)
}

func openLanesWith(t *testing.T, root string, session Identity, tax *fairsched.LaneTaxonomy) *LaneSet {
	t.Helper()
	ls, err := OpenLanes(root, session, tax)
	if err != nil {
		t.Fatalf("OpenLanes: %v", err)
	}
	t.Cleanup(func() { _ = ls.Close() })
	return ls
}

func openLanes(t *testing.T, root string, session Identity) *LaneSet {
	t.Helper()
	return openLanesWith(t, root, session, deploymentTaxonomy(t))
}

// openFDs counts the process's open file descriptors.
func openFDs(t *testing.T) int {
	t.Helper()
	d, err := os.Open("/dev/fd")
	if err != nil {
		t.Skipf("cannot count open descriptors: %v", err)
	}
	defer func() { _ = d.Close() }()
	names, err := d.Readdirnames(-1)
	if err != nil {
		t.Skipf("cannot count open descriptors: %v", err)
	}
	return len(names)
}

func mustLaneAppend(t *testing.T, ls *LaneSet, key LaneKey, id Identity, ev byte, body string) Receipt {
	t.Helper()
	r, err := ls.Append(key, id, evid(ev), []byte(body))
	if err != nil {
		t.Fatalf("Append(%s): %v", key, err)
	}
	return r
}

func bodies(t *testing.T, g *Generation) []string {
	t.Helper()
	recs, err := g.Unresolved()
	if err != nil {
		t.Fatalf("unresolved: %v", err)
	}
	out := make([]string, 0, len(recs))
	for _, r := range recs {
		out = append(out, string(r.Body))
	}
	return out
}

func requireRetryable(t *testing.T, err, specific error) {
	t.Helper()
	if !errors.Is(err, specific) || !errors.Is(err, ErrRetryable) || errors.Is(err, ErrPermanent) {
		t.Fatalf("err = %v; want %v classified RETRYABLE only", err, specific)
	}
}

func requirePermanent(t *testing.T, err, specific error) {
	t.Helper()
	if !errors.Is(err, specific) || !errors.Is(err, ErrPermanent) || errors.Is(err, ErrRetryable) {
		t.Fatalf("err = %v; want %v classified PERMANENT only", err, specific)
	}
}

func TestLanesHaveIndependentOpenGenerations(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)

	bulk := mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	inter := mustLaneAppend(t, ls, interactiveLane, sessionA, 2, "interactive-1")
	recov := mustLaneAppend(t, ls, recoveryLane, sessionA, 3, "recovery-1")
	bulk2 := mustLaneAppend(t, ls, bulkLane, sessionA, 4, "bulk-2")

	// Each lane opened its own generation with its own sequence space.
	for _, r := range []Receipt{bulk, inter, recov} {
		if r.Sequence != 1 || r.Generation.Ordinal != 1 {
			t.Fatalf("first append on %s = seq %d ordinal %d, want 1/1",
				r.Generation.Lane, r.Sequence, r.Generation.Ordinal)
		}
		if !r.Generation.Identity.equal(sessionA) {
			t.Fatalf("generation on %s froze %+v, want the session identity", r.Generation.Lane, r.Generation.Identity)
		}
	}
	if bulk2.Sequence != 2 || !bytes.Equal(bulk2.Generation.SpoolID, bulk.Generation.SpoolID) {
		t.Fatalf("second bulk append = seq %d in %x, want seq 2 in %x",
			bulk2.Sequence, bulk2.Generation.SpoolID, bulk.Generation.SpoolID)
	}
	ids := map[string]LaneKey{}
	for _, r := range []Receipt{bulk, inter, recov} {
		if prev, dup := ids[string(r.Generation.SpoolID)]; dup {
			t.Fatalf("%s and %s share spool id %x", prev, r.Generation.Lane, r.Generation.SpoolID)
		}
		ids[string(r.Generation.SpoolID)] = r.Generation.Lane
	}

	// Reclamation state is per lane.
	bulkGen, _ := ls.OpenGeneration(bulkLane)
	interGen, _ := ls.OpenGeneration(interactiveLane)
	if err := bulkGen.Resolve(2); err != nil {
		t.Fatalf("resolve bulk: %v", err)
	}
	if interGen.Resolved() != 0 {
		t.Fatalf("resolving bulk moved interactive's watermark to %d", interGen.Resolved())
	}
	if got := bodies(t, interGen); len(got) != 1 || got[0] != "interactive-1" {
		t.Fatalf("interactive records = %v", got)
	}

	if got := ls.Lanes(); len(got) != 3 {
		t.Fatalf("Lanes() = %v, want 3 lanes", got)
	}
}

// A lane appending (and fsyncing) must not hold any lock another lane needs.
func TestLaneAppendDoesNotWaitOnAnotherLane(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")

	// Park the bulk lane mid-append by holding its lock.
	bulk := ls.existingLane(bulkLane)
	bulk.mu.Lock()
	defer bulk.mu.Unlock()

	done := make(chan error, 1)
	go func() {
		_, err := ls.Append(interactiveLane, sessionA, evid(2), []byte("interactive-1"))
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("interactive append: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("interactive append blocked behind the bulk lane")
	}
}

func TestConcurrentLanesKeepContiguousSequences(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	const perLane = 40
	lanes := []LaneKey{bulkLane, interactiveLane, recoveryLane}

	var wg sync.WaitGroup
	errs := make(chan error, len(lanes)*perLane)
	for i, key := range lanes {
		wg.Add(1)
		go func(i int, key LaneKey) {
			defer wg.Done()
			for n := 0; n < perLane; n++ {
				if _, err := ls.Append(key, sessionA, evid(byte(i)), []byte(fmt.Sprintf("%s-%d", key, n))); err != nil {
					errs <- err
					return
				}
			}
		}(i, key)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent append: %v", err)
	}

	for _, key := range lanes {
		gens := ls.Generations(key)
		if len(gens) != 1 {
			t.Fatalf("%s has %d generations, want 1", key, len(gens))
		}
		recs, err := gens[0].Unresolved()
		if err != nil {
			t.Fatalf("unresolved: %v", err)
		}
		if len(recs) != perLane {
			t.Fatalf("%s holds %d records, want %d", key, len(recs), perLane)
		}
		for n, r := range recs {
			if r.Sequence != uint64(n+1) || string(r.Body) != fmt.Sprintf("%s-%d", key, n) {
				t.Fatalf("%s record %d = seq %d body %q", key, n, r.Sequence, r.Body)
			}
		}
	}
}

func TestRotationRequiredIsRetryableAndIsolatedPerLane(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	first := mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	inter := mustLaneAppend(t, ls, interactiveLane, sessionA, 2, "interactive-1")

	if err := ls.RequireRotation(bulkLane); err != nil {
		t.Fatalf("RequireRotation: %v", err)
	}

	// The valid append is refused as RETRYABLE and writes nothing.
	_, err := ls.Append(bulkLane, sessionA, evid(3), []byte("bulk-2"))
	requireRetryable(t, err, ErrRotationRequired)
	oldBulk, _ := ls.OpenGeneration(bulkLane)
	if oldBulk.NextSequence() != 2 {
		t.Fatalf("refused append consumed a sequence: next = %d", oldBulk.NextSequence())
	}

	// The other lane is untouched by the pending rotation.
	inter2 := mustLaneAppend(t, ls, interactiveLane, sessionA, 4, "interactive-2")
	if inter2.Sequence != 2 || !bytes.Equal(inter2.Generation.SpoolID, inter.Generation.SpoolID) {
		t.Fatalf("interactive append during bulk rotation = seq %d in %x", inter2.Sequence, inter2.Generation.SpoolID)
	}

	next, err := ls.Rotate(bulkLane)
	if err != nil {
		t.Fatalf("Rotate: %v", err)
	}
	if next.Ordinal != 2 || bytes.Equal(next.SpoolID, first.Generation.SpoolID) {
		t.Fatalf("successor = ordinal %d spool %x, want ordinal 2 with a fresh spool id", next.Ordinal, next.SpoolID)
	}

	// The producer retries the SAME append and it lands in the successor.
	retry, err := ls.Append(bulkLane, sessionA, evid(3), []byte("bulk-2"))
	if err != nil {
		t.Fatalf("retried append: %v", err)
	}
	if retry.Sequence != 1 || !bytes.Equal(retry.Generation.SpoolID, next.SpoolID) {
		t.Fatalf("retried append = seq %d in %x, want seq 1 in %x", retry.Sequence, retry.Generation.SpoolID, next.SpoolID)
	}

	// The closed generation keeps its record, identity, and reclamation state.
	gens := ls.Generations(bulkLane)
	if len(gens) != 2 || !gens[0].Closed() || gens[1].Closed() {
		t.Fatalf("bulk generations after rotation = %d, closed %v/%v", len(gens), gens[0].Closed(), gens[1].Closed())
	}
	if got := bodies(t, gens[0]); len(got) != 1 || got[0] != "bulk-1" {
		t.Fatalf("closed generation records = %v", got)
	}
	if err := gens[0].Resolve(1); err != nil {
		t.Fatalf("resolve closed generation: %v", err)
	}
	if gens[1].Resolved() != 0 {
		t.Fatal("resolving the closed generation moved the successor's watermark")
	}

	// Rotation of bulk did not rotate interactive.
	if gens := ls.Generations(interactiveLane); len(gens) != 1 || gens[0].Closed() {
		t.Fatalf("interactive lane rotated alongside bulk: %d generations", len(gens))
	}
}

func TestUnauthorizedOrMalformedAppendIsPermanent(t *testing.T) {
	cases := []struct {
		name     string
		lane     LaneKey
		identity Identity
		eventID  []byte
		want     error
	}{
		{"unspecified lane", LaneKey{}, sessionA, evid(1), ErrLaneInvalid},
		{"undeclared route profile", LaneKey{RouteProfile: 99, TrafficClass: bulkLane.TrafficClass}, sessionA, evid(1), ErrLaneInvalid},
		{"undeclared traffic class", LaneKey{RouteProfile: bulkLane.RouteProfile, TrafficClass: -1}, sessionA, evid(1), ErrLaneInvalid},
		{"other network scope", bulkLane, testIdentity(0x22, "agent-test-01"), evid(1), ErrScopeUnauthorized},
		{"malformed network scope", bulkLane, Identity{NetworkScopeID: []byte{1, 2}, AgentID: sessionA.AgentID}, evid(1), ErrScopeUnauthorized},
		{"other agent", bulkLane, sessionB, evid(1), ErrAgentUnauthorized},
		{"malformed agent", bulkLane, Identity{NetworkScopeID: sessionA.NetworkScopeID, AgentID: []byte("agent test")}, evid(1), ErrAgentUnauthorized},
		{"short event id", bulkLane, sessionA, []byte{1}, ErrEventIDLength},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ls := openLanes(t, t.TempDir(), sessionA)
			_, err := ls.Append(tc.lane, tc.identity, tc.eventID, []byte("x"))
			requirePermanent(t, err, tc.want)
			if len(ls.Lanes()) != 0 {
				t.Fatalf("refused append opened a generation: %v", ls.Lanes())
			}
		})
	}
}

// Unauthorized identity stays PERMANENT even on a lane whose rotation is pending:
// the retryable answer must never mask an authorization failure.
func TestUnauthorizedIdentityIsPermanentWhileRotationPending(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	if err := ls.RequireRotation(bulkLane); err != nil {
		t.Fatalf("RequireRotation: %v", err)
	}
	_, err := ls.Append(bulkLane, sessionB, evid(2), []byte("x"))
	requirePermanent(t, err, ErrAgentUnauthorized)
}

func TestRotationAndMalformedLaneControlCalls(t *testing.T) {
	ls := openLanes(t, t.TempDir(), sessionA)
	if err := ls.RequireRotation(LaneKey{}); !errors.Is(err, ErrLaneInvalid) {
		t.Fatalf("RequireRotation(malformed) = %v", err)
	}
	if _, err := ls.Rotate(LaneKey{}); !errors.Is(err, ErrLaneInvalid) {
		t.Fatalf("Rotate(malformed) = %v", err)
	}
	// A lane with no generation needs no rotation.
	if err := ls.RequireRotation(bulkLane); err != nil {
		t.Fatalf("RequireRotation(empty lane): %v", err)
	}
	if r := mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1"); r.Sequence != 1 {
		t.Fatalf("append on never-opened lane = seq %d", r.Sequence)
	}
}

func TestGenerationsRecoverUnderTheirFrozenIdentity(t *testing.T) {
	root := t.TempDir()

	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	first := mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	if _, err := ls.Rotate(bulkLane); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	second := mustLaneAppend(t, ls, bulkLane, sessionA, 2, "bulk-2")
	mustLaneAppend(t, ls, interactiveLane, sessionA, 3, "interactive-1")
	if err := ls.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Same session: both generations recover, the open one keeps appending.
	ls = openLanes(t, root, sessionA)
	gens := ls.Generations(bulkLane)
	if len(gens) != 2 || !gens[0].Closed() || gens[1].Closed() {
		t.Fatalf("recovered bulk generations = %d", len(gens))
	}
	if id := gens[0].Identity(); !bytes.Equal(id.SpoolID, first.Generation.SpoolID) || id.Ordinal != 1 ||
		!id.Identity.equal(sessionA) || id.Lane != bulkLane {
		t.Fatalf("closed generation recovered as %+v", id)
	}
	r := mustLaneAppend(t, ls, bulkLane, sessionA, 4, "bulk-3")
	if r.Sequence != 2 || !bytes.Equal(r.Generation.SpoolID, second.Generation.SpoolID) {
		t.Fatalf("append after recovery = seq %d in %x", r.Sequence, r.Generation.SpoolID)
	}
	if err := ls.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Re-enrolled under another agent identity: old generations keep identity A,
	// the recovered open one must rotate, and the successor freezes identity B.
	ls = openLanes(t, root, sessionB)
	_, err = ls.Append(bulkLane, sessionB, evid(5), []byte("bulk-b-1"))
	requireRetryable(t, err, ErrRotationRequired)
	if _, err := ls.Append(interactiveLane, sessionB, evid(6), []byte("x")); !errors.Is(err, ErrRotationRequired) {
		t.Fatalf("interactive append under new identity = %v, want ROTATION_REQUIRED", err)
	}

	next, err := ls.Rotate(bulkLane)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if next.Ordinal != 3 || !next.Identity.equal(sessionB) {
		t.Fatalf("successor = %+v, want ordinal 3 frozen under session B", next)
	}
	if r := mustLaneAppend(t, ls, bulkLane, sessionB, 5, "bulk-b-1"); r.Sequence != 1 {
		t.Fatalf("retried append = seq %d", r.Sequence)
	}

	gens = ls.Generations(bulkLane)
	if len(gens) != 3 {
		t.Fatalf("bulk generations = %d, want 3", len(gens))
	}
	for i, want := range [][]string{{"bulk-1"}, {"bulk-2", "bulk-3"}} {
		if !gens[i].Closed() || !gens[i].Identity().Identity.equal(sessionA) {
			t.Fatalf("generation %d lost its frozen identity or closed state", i+1)
		}
		if got := bodies(t, gens[i]); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("generation %d records = %v, want %v", i+1, got, want)
		}
	}
}

func TestRecoveryDiscardsUnpublishedGenerationPreparation(t *testing.T) {
	root := t.TempDir()
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	_ = ls.Close()

	laneDir := filepath.Join(root, laneDirName(bulkLane))
	stale := filepath.Join(laneDir, tmpPrefix+generationDirName(2, testScope(0x33)))
	if err := os.Mkdir(stale, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	ls = openLanes(t, root, sessionA)
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unpublished preparation survived recovery: %v", err)
	}
	if gens := ls.Generations(bulkLane); len(gens) != 1 {
		t.Fatalf("generations = %d, want 1", len(gens))
	}
}

// A crash after the close marker but before the successor exists leaves the lane
// with no open generation; the next append opens one with the next ordinal.
func TestRecoveryAfterCloseBeforeSuccessor(t *testing.T) {
	root := t.TempDir()
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	g, _ := ls.OpenGeneration(bulkLane)
	if err := writeClosedMarker(g.dir); err != nil {
		t.Fatalf("marker: %v", err)
	}
	_ = ls.Close()

	ls = openLanes(t, root, sessionA)
	if _, ok := ls.OpenGeneration(bulkLane); ok {
		t.Fatal("closed generation recovered as open")
	}
	r := mustLaneAppend(t, ls, bulkLane, sessionA, 2, "bulk-2")
	if r.Generation.Ordinal != 2 || r.Sequence != 1 {
		t.Fatalf("append = ordinal %d seq %d, want 2/1", r.Generation.Ordinal, r.Sequence)
	}
}

func TestRecoveryFailsStopOnUntrustworthyGenerationState(t *testing.T) {
	setup := func(t *testing.T) (string, *Generation, *Generation) {
		t.Helper()
		root := t.TempDir()
		ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
		if _, err := ls.Rotate(bulkLane); err != nil {
			t.Fatalf("rotate: %v", err)
		}
		gens := ls.Generations(bulkLane)
		_ = ls.Close()
		return root, gens[0], gens[1]
	}

	t.Run("corrupt identity", func(t *testing.T) {
		root, closed, _ := setup(t)
		path := filepath.Join(closed.dir, identityFile)
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		raw[40] ^= 0xFF // inside the frozen network_scope_id
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}
		if _, err := OpenLanes(root, sessionA, deploymentTaxonomy(t)); !errors.Is(err, ErrCorruptGeneration) {
			t.Fatalf("OpenLanes = %v, want ErrCorruptGeneration", err)
		}
	})

	t.Run("identity moved to another generation", func(t *testing.T) {
		root, closed, open := setup(t)
		raw, err := os.ReadFile(filepath.Join(open.dir, identityFile))
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if err := os.WriteFile(filepath.Join(closed.dir, identityFile), raw, 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}
		if _, err := OpenLanes(root, sessionA, deploymentTaxonomy(t)); !errors.Is(err, ErrCorruptGeneration) {
			t.Fatalf("OpenLanes = %v, want ErrCorruptGeneration", err)
		}
	})

	t.Run("two open generations", func(t *testing.T) {
		root, closed, _ := setup(t)
		if err := os.Remove(filepath.Join(closed.dir, closedFile)); err != nil {
			t.Fatalf("remove marker: %v", err)
		}
		if _, err := OpenLanes(root, sessionA, deploymentTaxonomy(t)); !errors.Is(err, ErrCorruptGeneration) {
			t.Fatalf("OpenLanes = %v, want ErrCorruptGeneration", err)
		}
	})

	t.Run("unrecognized lane entry", func(t *testing.T) {
		root, _, _ := setup(t)
		if err := os.Mkdir(filepath.Join(root, "0-1"), 0o700); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if _, err := OpenLanes(root, sessionA, deploymentTaxonomy(t)); !errors.Is(err, ErrCorruptGeneration) {
			t.Fatalf("OpenLanes = %v, want ErrCorruptGeneration", err)
		}
	})
}

func TestOpenLanesRejectsMalformedSessionIdentity(t *testing.T) {
	for _, id := range []Identity{
		{NetworkScopeID: make([]byte, 16), AgentID: sessionA.AgentID},
		{NetworkScopeID: sessionA.NetworkScopeID, AgentID: nil},
	} {
		if _, err := OpenLanes(t.TempDir(), id, deploymentTaxonomy(t)); !errors.Is(err, ErrSessionIdentity) {
			t.Fatalf("OpenLanes(%+v) = %v, want ErrSessionIdentity", id, err)
		}
	}
}

func TestOpenLanesRequiresTaxonomy(t *testing.T) {
	root := filepath.Join(t.TempDir(), "lanes")
	if _, err := OpenLanes(root, sessionA, nil); !errors.Is(err, fairsched.ErrTaxonomyInvalid) {
		t.Fatalf("OpenLanes(nil taxonomy) = %v, want ErrTaxonomyInvalid", err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused OpenLanes created its root: %v", err)
	}
}

func TestLaneOutsideTaxonomyIsNotReady(t *testing.T) {
	root := t.TempDir()
	ls := openLanes(t, root, sessionA)

	_, err := ls.Append(inactiveLane, sessionA, evid(1), []byte("x"))
	requireRetryable(t, err, ErrLaneNotReady)
	requireRetryable(t, ls.RequireRotation(inactiveLane), ErrLaneNotReady)
	_, err = ls.Rotate(inactiveLane)
	requireRetryable(t, err, ErrLaneNotReady)

	// A permanent refusal is not masked by the lane being not ready.
	_, err = ls.Append(inactiveLane, sessionB, evid(1), []byte("x"))
	requirePermanent(t, err, ErrAgentUnauthorized)

	if got := ls.Lanes(); len(got) != 0 {
		t.Fatalf("refused lane has bookkeeping: %v", got)
	}
	if _, ok := ls.OpenGeneration(inactiveLane); ok {
		t.Fatal("refused lane opened a generation")
	}
	if _, err := os.Stat(filepath.Join(root, laneDirName(inactiveLane))); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("refused lane created a directory: %v", err)
	}
}

// A lane the new taxonomy dropped keeps every generation it spooled readable and
// resolvable under its frozen identity; only new appends and rotations wait.
func TestRecoveredLaneOutsideTaxonomyStaysReadable(t *testing.T) {
	root := t.TempDir()
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	first := mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")
	if _, err := ls.Rotate(bulkLane); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	second := mustLaneAppend(t, ls, bulkLane, sessionA, 2, "bulk-2")
	if err := ls.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	ls = openLanesWith(t, root, sessionA, taxonomyOf(t, interactiveLane, recoveryLane))

	_, err = ls.Append(bulkLane, sessionA, evid(3), []byte("bulk-3"))
	requireRetryable(t, err, ErrLaneNotReady)
	requireRetryable(t, ls.RequireRotation(bulkLane), ErrLaneNotReady)
	_, err = ls.Rotate(bulkLane)
	requireRetryable(t, err, ErrLaneNotReady)

	gens := ls.Generations(bulkLane)
	if len(gens) != 2 || !gens[0].Closed() || gens[1].Closed() {
		t.Fatalf("recovered bulk generations = %d", len(gens))
	}
	for i, want := range []Receipt{first, second} {
		id := gens[i].Identity()
		if !bytes.Equal(id.SpoolID, want.Generation.SpoolID) || !id.Identity.equal(sessionA) || id.Lane != bulkLane {
			t.Fatalf("generation %d recovered as %+v", i+1, id)
		}
		if got := bodies(t, gens[i]); len(got) != 1 || got[0] != fmt.Sprintf("bulk-%d", i+1) {
			t.Fatalf("generation %d records = %v", i+1, got)
		}
		if err := gens[i].Resolve(want.Sequence); err != nil {
			t.Fatalf("resolve generation %d: %v", i+1, err)
		}
		if gens[i].Resolved() != want.Sequence || gens[i].NextSequence() != want.Sequence+1 {
			t.Fatalf("generation %d = resolved %d next %d", i+1, gens[i].Resolved(), gens[i].NextSequence())
		}
	}

	if r := mustLaneAppend(t, ls, interactiveLane, sessionA, 4, "interactive-1"); r.Sequence != 1 {
		t.Fatalf("active lane append = seq %d", r.Sequence)
	}
}

// Closed generations never append again, so they must not pin a segment
// descriptor for the life of the lane set, at run time or after recovery.
func TestClosedGenerationsHoldNoSegmentDescriptor(t *testing.T) {
	const rotations = 16
	root := t.TempDir()
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")

	before := openFDs(t)
	for range rotations {
		if _, err := ls.Rotate(bulkLane); err != nil {
			t.Fatalf("rotate: %v", err)
		}
	}
	if grown := openFDs(t) - before; grown > 2 {
		t.Fatalf("%d rotations left %d more descriptors open", rotations, grown)
	}
	gens := ls.Generations(bulkLane)
	if len(gens) != rotations+1 {
		t.Fatalf("bulk generations = %d, want %d", len(gens), rotations+1)
	}
	if got := bodies(t, gens[0]); len(got) != 1 || got[0] != "bulk-1" {
		t.Fatalf("closed generation records = %v", got)
	}
	if err := gens[0].Resolve(1); err != nil {
		t.Fatalf("resolve closed generation: %v", err)
	}
	if err := ls.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	before = openFDs(t)
	ls = openLanes(t, root, sessionA)
	if grown := openFDs(t) - before; grown > 2 {
		t.Fatalf("recovering %d closed generations left %d descriptors open", rotations, grown)
	}
	gens = ls.Generations(bulkLane)
	if len(gens) != rotations+1 || gens[0].Resolved() != 1 || gens[0].NextSequence() != 2 {
		t.Fatalf("recovered %d generations; first resolved %d next %d",
			len(gens), gens[0].Resolved(), gens[0].NextSequence())
	}
	if r := mustLaneAppend(t, ls, bulkLane, sessionA, 2, "bulk-2"); r.Generation.Ordinal != rotations+1 || r.Sequence != 1 {
		t.Fatalf("append after recovery = ordinal %d seq %d", r.Generation.Ordinal, r.Sequence)
	}
}

// A failure after a generation is published must leave it closed, so the retry's
// successor is the lane's only open generation and recovery still succeeds.
func TestFailureAfterPublishingGenerationClosesIt(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("directory permissions do not constrain root")
	}
	root := t.TempDir()
	ls, err := OpenLanes(root, sessionA, deploymentTaxonomy(t))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustLaneAppend(t, ls, bulkLane, sessionA, 1, "bulk-1")

	// Write and search without read: a generation can still be published into the
	// lane directory, but the directory cannot be opened to fsync the publish.
	laneDir := filepath.Join(root, laneDirName(bulkLane))
	if err := os.Chmod(laneDir, 0o300); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(laneDir, 0o700) })
	if _, err := ls.Rotate(bulkLane); err == nil {
		t.Fatal("Rotate succeeded although the lane directory could not be fsynced")
	}
	if err := os.Chmod(laneDir, 0o700); err != nil {
		t.Fatalf("chmod: %v", err)
	}

	if r := mustLaneAppend(t, ls, bulkLane, sessionA, 2, "bulk-2"); r.Generation.Ordinal != 3 || r.Sequence != 1 {
		t.Fatalf("retried append = ordinal %d seq %d, want 3/1", r.Generation.Ordinal, r.Sequence)
	}
	if err := ls.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	ls = openLanes(t, root, sessionA)
	gens := ls.Generations(bulkLane)
	if len(gens) != 3 || !gens[0].Closed() || !gens[1].Closed() || gens[2].Closed() {
		t.Fatalf("recovered bulk generations = %d", len(gens))
	}
	if r := mustLaneAppend(t, ls, bulkLane, sessionA, 3, "bulk-3"); r.Generation.Ordinal != 3 || r.Sequence != 2 {
		t.Fatalf("append after recovery = ordinal %d seq %d, want 3/2", r.Generation.Ordinal, r.Sequence)
	}
}

func TestIdentityEncodingRoundTrips(t *testing.T) {
	id := GenerationIdentity{Lane: recoveryLane, Ordinal: 7, SpoolID: mustUUIDv7(t), Identity: sessionA}
	got, err := decodeIdentity(encodeIdentity(id))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Lane != id.Lane || got.Ordinal != id.Ordinal || !bytes.Equal(got.SpoolID, id.SpoolID) ||
		!got.Identity.equal(id.Identity) {
		t.Fatalf("round trip = %+v, want %+v", got, id)
	}
}

func mustUUIDv7(t *testing.T) []byte {
	t.Helper()
	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		t.Fatalf("uuidv7: %v", err)
	}
	return id
}
