// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package recovery

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// All coordinates and evidence in this file are invented synthetic values.
func uuid(seed byte) []byte   { b := bytes.Repeat([]byte{seed}, 16); b[6] = 0x70; b[8] = 0x80; return b }
func digest(seed byte) []byte { return bytes.Repeat([]byte{seed}, 32) }
func loss(seq uint64, reason edgev1.EdgeUnattributableReason) Slot {
	return Slot{Sequence: seq, Loss: &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq,
		Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{Unattributable: &edgev1.EdgeUnattributableV1{Reason: reason}}}}
}
func active(seq uint64) Slot {
	return Slot{Sequence: seq, Loss: &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{AttributedActive: &edgev1.EdgeAttributedActiveV1{
			Identity: &edgev1.EdgeAttributedSpanIdentityV1{ProducerAssignmentId: uuid(4), RunId: uuid(5), ProductionScopeId: uuid(6), RunShard: 2, AuthorityEpoch: 5, ScopeSha256: digest(7), ContractBundleSha256: digest(8), Source: &edgev1.EdgeSourceSpanIdentityV1{Kind: edgev1.EdgeSourceAuthorizationKind(1), ContextId: uuid(21), SourceScopeId: uuid(22), SourceScopeSha256: digest(23)}}, RangeSha256: digest(9)}}}}
}
func preserved(seq uint64) Slot {
	return Slot{Sequence: seq, Copy: &CopyIntent{NewSequence: 1, EventID: uuid(10), RecordSHA256: digest(11), SourceBindingSHA256: digest(12), AttributionBindingSHA256: digest(13)}}
}
func plan(slots ...Slot) Plan {
	return Plan{RecoveryID: uuid(1), DetectedAtUnixNano: 1800000000000000000, Reason: "synthetic damaged segment", NewSpoolID: uuid(2), Source: spool.GenerationIdentity{Ordinal: 1, SpoolID: uuid(3),
		Identity: spool.Identity{NetworkScopeID: uuid(14), AgentID: []byte("agent-test-01")},
		Lane:     spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}},
		First: slots[0].Sequence, Last: slots[len(slots)-1].Sequence, HighWater: slots[len(slots)-1].Sequence, Slots: slots}
}
func grant(t *testing.T, dir string, journalBudget uint64) *spool.RecoveryGrant {
	t.Helper()
	a, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: 64 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1,
		Recovery: spool.Footprint{DestinationSegment: 1 << 20, AttributionSidecar: 1 << 20, JournalCopy: journalBudget, ManifestPages: 256 << 10, Mapping: 1 << 20, FilesystemMetadata: 4096}})
	if err != nil {
		t.Fatal(err)
	}
	g, err := a.AcquireRecovery(dir)
	if err != nil {
		t.Fatal(err)
	}
	return g
}
func frozen(t *testing.T, p Plan) (string, *Journal) {
	t.Helper()
	dir := t.TempDir()
	if _, err := Freeze(dir, grant(t, dir, 2*MaxJournalBytes), p); err != nil {
		t.Fatal(err)
	}
	j, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	return dir, j
}
func pages(t *testing.T, j *Journal) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()
	m, err := j.BuildManifest()
	if err != nil {
		t.Fatal(err)
	}
	result := make([]*edgev1.EdgeLossManifestPageV1, len(m.Pages))
	for i, raw := range m.Pages {
		result[i] = new(edgev1.EdgeLossManifestPageV1)
		if err := proto.Unmarshal(raw, result[i]); err != nil {
			t.Fatal(err)
		}
	}
	var tomb edgev1.SpoolLossTombstoneV1
	if err := proto.Unmarshal(m.Tombstone, &tomb); err != nil {
		t.Fatal(err)
	}
	if err := edgerecord.ValidateManifestChainFromRaw(m.Pages, tomb.ManifestRootSha256); err != nil {
		t.Fatal(err)
	}
	if tomb.DetectedAtUnixNano != 1800000000000000000 || tomb.Reason != "synthetic damaged segment" {
		t.Fatal("tombstone omitted frozen detection evidence")
	}
	if err := edgerecord.ValidateTombstone(&tomb, result); err != nil {
		t.Fatal(err)
	}
	return result
}

const missing = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING
const torn = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL

func TestJournalDerivedCoarsening(t *testing.T) {
	changed := active(2)
	changed.Loss.GetAttributedActive().RangeSha256 = digest(17)
	for _, tc := range []struct {
		name  string
		slots []Slot
		want  [][2]uint64
	}{
		{"equal adjacent bodies", []Slot{active(1), active(2)}, [][2]uint64{{1, 2}}},
		{"preserved gap", []Slot{active(1), preserved(2), active(3)}, [][2]uint64{{1, 1}, {3, 3}}},
		{"different attributed body", []Slot{active(1), changed}, [][2]uint64{{1, 1}, {2, 2}}},
		{"different unattributable reason", []Slot{loss(1, missing), loss(2, torn)}, [][2]uint64{{1, 1}, {2, 2}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, j := frozen(t, plan(tc.slots...))
			snap, err := j.Snapshot()
			if err != nil {
				t.Fatal(err)
			}
			if len(snap.Slots) != len(tc.slots) {
				t.Fatal("journal dropped original slot evidence")
			}
			for i, s := range snap.Slots {
				if s.Sequence != tc.slots[i].Sequence || !proto.Equal(s.Loss, tc.slots[i].Loss) || !reflect.DeepEqual(s.Copy, tc.slots[i].Copy) {
					t.Fatalf("changed singleton evidence at %d", i)
				}
			}
			var got [][2]uint64
			for _, p := range pages(t, j) {
				for _, s := range p.ClassificationSpans {
					got = append(got, [2]uint64{s.FromSequence, s.ThroughSequence})
				}
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("reopened journal spans %v, want %v", got, tc.want)
			}
		})
	}
}

func TestJournalRequiresCompleteAllocatedInterval(t *testing.T) {
	p := plan(preserved(9))
	p.ReclaimThrough = 8
	p.Last = 10
	p.HighWater = 10
	dir := t.TempDir()
	g := grant(t, dir, 2*MaxJournalBytes)
	if j, err := Freeze(dir, g, p); j != nil || !errors.Is(err, ErrPlan) {
		t.Fatalf("9/10 incomplete interval = %v, %v", j, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatalf("invalid plan wrote evidence: %v %v", entries, err)
	}
	p.Slots = append(p.Slots, loss(10, torn))
	_, j := frozen(t, p)
	s, err := j.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if s.ReclaimThrough != 8 || s.HighWater != 10 || s.Slots[0].Copy == nil || s.Slots[1].Loss == nil {
		t.Fatal("lost allocated high-water or copy/loss partition")
	}
	if got := pages(t, j)[0].ClassificationSpans; len(got) != 1 || got[0].FromSequence != 10 || got[0].ThroughSequence != 10 {
		t.Fatalf("uncommitted allocation is not a singleton loss: %v", got)
	}
	if _, err := JournalBytes(plan(preserved(1))); !errors.Is(err, ErrNoLoss) {
		t.Fatalf("copies-only invented loss: %v", err)
	}
}

func TestJournalBoundsAndPageChain(t *testing.T) {
	slots := make([]Slot, edgerecord.MaxRecoverySlots)
	for i := range slots {
		reason := missing
		if i%2 != 0 {
			reason = torn
		}
		slots[i] = loss(uint64(i+1), reason)
	}
	p := plan(slots...)
	_, j := frozen(t, p)
	got := pages(t, j)
	if len(got) != 4 || got[0].ClassificationSpans[0].FromSequence != 1 || got[3].ClassificationSpans[255].ThroughSequence != 1024 {
		t.Fatal("bounded allocated interval did not retain all 1024 singleton losses")
	}
	p.Slots = append(p.Slots, loss(1025, missing))
	p.Last = 1025
	p.HighWater = 1025
	if _, err := JournalBytes(p); !errors.Is(err, ErrSplitRequired) {
		t.Fatalf("oversized interval = %v", err)
	}
	// Rich attributed bodies exceed the aggregate wire cap before the slot cap.
	for i := range slots {
		slots[i] = active((1 << 60) + uint64(i))
		slots[i].Loss.GetAttributedActive().Identity.RunShard = ^uint32(0) - uint32(i)
		slots[i].Loss.GetAttributedActive().Identity.AuthorityEpoch = ^uint64(0)
	}
	p = plan(slots...)
	if _, err := JournalBytes(p); !errors.Is(err, ErrSplitRequired) || !errors.Is(err, edgerecord.ErrManifestBounds) {
		t.Fatalf("oversized exact manifest = %v", err)
	}
}

func TestJournalRepairRequiresOneUnambiguousCopy(t *testing.T) {
	for _, damage := range []string{"missing", "torn", "checksum", "unsupported", "both torn", "divergent"} {
		t.Run(damage, func(t *testing.T) {
			dir, _ := frozen(t, plan(loss(1, missing)))
			aPath, bPath := filepath.Join(dir, copyA), filepath.Join(dir, copyB)
			intact, err := os.ReadFile(aPath)
			if err != nil {
				t.Fatal(err)
			}
			bad := append([]byte(nil), intact...)
			repairable := true
			switch damage {
			case "missing":
				if err := os.Remove(bPath); err != nil {
					t.Fatal(err)
				}
			case "torn":
				bad = bad[:len(bad)/2]
			case "checksum":
				bad[len(bad)-1] ^= 1
			case "unsupported":
				binary.BigEndian.PutUint64(bad[len(journalMagic):journalHeader], 99)
				repairable = false
			case "both torn":
				bad = bad[:9]
				if err := os.WriteFile(aPath, bad, 0600); err != nil {
					t.Fatal(err)
				}
				repairable = false
			case "divergent":
				other, _ := frozen(t, plan(loss(1, torn)))
				bad, err = os.ReadFile(filepath.Join(other, copyB))
				if err != nil {
					t.Fatal(err)
				}
				repairable = false
			}
			if damage != "missing" {
				if err := os.WriteFile(bPath, bad, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if j, err := Open(dir); j != nil || err == nil {
				t.Fatalf("damaged pair became usable: %v %v", j, err)
			}
			j, err := Repair(dir, grant(t, dir, 2*MaxJournalBytes))
			if repairable {
				if err != nil {
					t.Fatal(err)
				}
				_ = pages(t, j)
				a, _ := os.ReadFile(aPath)
				b, _ := os.ReadFile(bPath)
				if !bytes.Equal(a, intact) || !bytes.Equal(b, intact) {
					t.Fatal("repair did not preserve exact intact bytes")
				}
			} else {
				if j != nil || err == nil {
					t.Fatalf("ambiguous evidence repaired: %v %v", j, err)
				}
				after, e := os.ReadFile(bPath)
				if e != nil || !bytes.Equal(after, bad) {
					t.Fatal("failed repair changed retained evidence")
				}
				if damage == "divergent" && !errors.Is(err, ErrJournalConflict) {
					t.Fatalf("divergence = %v", err)
				}
				if damage == "unsupported" && !errors.Is(err, ErrJournalVersion) {
					t.Fatalf("unsupported = %v", err)
				}
			}
		})
	}
}

func TestJournalReserveFailureRetainsEvidence(t *testing.T) {
	p := plan(loss(1, missing))
	size, err := JournalBytes(p)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	g := grant(t, dir, size-1)
	if j, err := Freeze(dir, g, p); j != nil || !errors.Is(err, spool.ErrReserveExhausted) {
		t.Fatalf("undersized reserve = %v %v", j, err)
	}
	if _, err := os.Stat(filepath.Join(dir, copyA)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("write preceded reserve: %v", err)
	}
	// A first copy is not sufficient after a process stops between the barriers.
	good, _ := frozen(t, p)
	raw, err := os.ReadFile(filepath.Join(good, copyA))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, copyA), raw, 0600); err != nil {
		t.Fatal(err)
	}
	if j, err := Open(dir); j != nil || !errors.Is(err, ErrJournalIncomplete) {
		t.Fatalf("single-copy freeze accepted: %v %v", j, err)
	}
	if _, err := Repair(dir, g); err == nil {
		t.Fatal("failed grant reused for repair")
	}
	before, err := os.ReadFile(filepath.Join(dir, copyA))
	if err != nil || !bytes.Equal(before, raw) {
		t.Fatal("failed repair lost intact copy")
	}
	if _, err := Repair(dir, grant(t, dir, size)); err != nil {
		t.Fatal(err)
	}
}

func TestJournalImmutableIdentityAndSnapshots(t *testing.T) {
	p := plan(active(1))
	dir, j := frozen(t, p)
	snap, err := j.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	snap.Source.Identity.AgentID[0] ^= 1
	snap.Slots[0].Loss.GetAttributedActive().RangeSha256[0] ^= 1
	again, err := j.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again.Source.Identity.AgentID, p.Source.Identity.AgentID) || !proto.Equal(again.Slots[0].Loss, p.Slots[0].Loss) {
		t.Fatal("caller mutated frozen journal")
	}
	p.NewSpoolID = uuid(20)
	if _, err := Freeze(dir, grant(t, dir, 2*MaxJournalBytes), p); !errors.Is(err, ErrJournalConflict) {
		t.Fatalf("refreeze replaced identity: %v", err)
	}
	_, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
}

func TestJournalCoarseningComparesEveryAttributedMember(t *testing.T) {
	mutations := map[string]func(*edgev1.EdgeAttributedActiveV1){
		"assignment":       func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ProducerAssignmentId = uuid(30) },
		"run":              func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.RunId = uuid(30) },
		"shard":            func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.RunShard++ },
		"epoch":            func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.AuthorityEpoch++ },
		"production scope": func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ProductionScopeId = uuid(30) },
		"scope hash":       func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ScopeSha256 = digest(30) },
		"contract hash":    func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ContractBundleSha256 = digest(30) },
		"source presence":  func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source = nil },
		"source kind":      func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.Kind = edgev1.EdgeSourceAuthorizationKind(4) },
		"source context":   func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.ContextId = uuid(30) },
		"source scope":     func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.SourceScopeId = uuid(30) },
		"source hash":      func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.SourceScopeSha256 = digest(30) },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			second := active(2)
			mutate(second.Loss.GetAttributedActive())
			_, j := frozen(t, plan(active(1), second))
			if got := pages(t, j)[0].ClassificationSpans; len(got) != 2 {
				t.Fatalf("distinct %s coarsened into %d spans", name, len(got))
			}
		})
	}
}

func TestJournalRejectsInvalidEvidenceBeforeWriting(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*Plan)
		want   error
	}{
		{"missing detection time", func(p *Plan) { p.DetectedAtUnixNano = 0 }, ErrPlan},
		{"missing reason", func(p *Plan) { p.Reason = "" }, ErrPlan},
		{"unset body", func(p *Plan) { p.Slots[0].Loss.Classification = nil }, edgerecord.ErrManifestSpanBody},
		{"unknown body fields", func(p *Plan) { p.Slots[0].Loss.ProtoReflect().SetUnknown([]byte{0xf8, 0x07, 0x01}) }, edgerecord.ErrUnknownFields},
		{"non singleton", func(p *Plan) { p.Slots[0].Loss.ThroughSequence = 2 }, ErrPlan},
		{"both bodies", func(p *Plan) { p.Slots[0].Copy = preserved(1).Copy }, ErrPlan},
		{"outside high water", func(p *Plan) { p.HighWater = 0 }, ErrPlan},
		{"reclaimed slot", func(p *Plan) { p.ReclaimThrough = 1 }, ErrPlan},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := plan(active(1))
			tc.mutate(&p)
			dir := t.TempDir()
			if j, err := Freeze(dir, grant(t, dir, 2*MaxJournalBytes), p); j != nil || !errors.Is(err, tc.want) {
				t.Fatalf("invalid evidence = %v %v, want %v", j, err, tc.want)
			}
			entries, err := os.ReadDir(dir)
			if err != nil || len(entries) != 0 {
				t.Fatal("invalid evidence reached disk")
			}
		})
	}
}

func TestJournalRepairCannotHideReadFailureOrExceedReserve(t *testing.T) {
	p := plan(loss(1, missing))
	size, err := JournalBytes(p)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	g := grant(t, dir, size)
	if _, err := Freeze(dir, g, p); err != nil {
		t.Fatal(err)
	}
	bPath := filepath.Join(dir, copyB)
	intact, err := os.ReadFile(bPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(bPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(bPath, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := Repair(dir, g); err == nil {
		t.Fatal("filesystem read error treated as missing evidence")
	}
	info, err := os.Stat(bPath)
	if err != nil || !info.IsDir() {
		t.Fatal("failed read caused journal replacement")
	}
	if err := os.Remove(bPath); err != nil {
		t.Fatal(err)
	}
	bad := intact[:len(intact)/2]
	if err := os.WriteFile(bPath, bad, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Repair(dir, g); !errors.Is(err, spool.ErrReserveExhausted) {
		t.Fatalf("unreserved rewrite = %v", err)
	}
	after, err := os.ReadFile(bPath)
	if err != nil || !bytes.Equal(after, bad) {
		t.Fatal("failed reserved rewrite destroyed retained evidence")
	}
	if _, err := Repair(dir, grant(t, dir, size)); err != nil {
		t.Fatal(err)
	}
}

func TestJournalRejectsPagesThatDisagreeWithSingletonEvidence(t *testing.T) {
	dir, j := frozen(t, plan(active(1), active(2)))
	snap, err := j.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := j.BuildManifest()
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a writer that persisted a valid checksum and valid final pages but
	// changed one singleton classification after the pages were constructed.
	snap.Slots[1].Loss.GetAttributedActive().RangeSha256 = digest(31)
	payload, err := json.Marshal(frozenRecord{Plan: snap, Manifest: manifest})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, copyA))
	if err != nil {
		t.Fatal(err)
	}
	changed := append(append([]byte(nil), raw[:journalHeader]...), payload...)
	sum := sha256.Sum256(changed)
	changed = append(changed, sum[:]...)
	for _, name := range []string{copyA, copyB} {
		if err := os.WriteFile(filepath.Join(dir, name), changed, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if j, err := Open(dir); j != nil || !errors.Is(err, ErrJournalCorrupt) {
		t.Fatalf("page-only evidence accepted: %v %v", j, err)
	}
}
