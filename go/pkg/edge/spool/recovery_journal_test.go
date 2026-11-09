// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// All coordinates and evidence in this file are invented synthetic values.
func recoveryUUID(seed byte) []byte {
	b := bytes.Repeat([]byte{seed}, 16)
	b[6] = 0x70
	b[8] = 0x80
	return b
}
func recoveryDigest(seed byte) []byte { return bytes.Repeat([]byte{seed}, 32) }
func recoveryLoss(seq uint64, reason edgev1.EdgeUnattributableReason) RecoverySlot {
	return RecoverySlot{Sequence: seq, Loss: &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq,
		Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{Unattributable: &edgev1.EdgeUnattributableV1{Reason: reason}}}}
}
func recoveryActive(seq uint64) RecoverySlot {
	return RecoverySlot{Sequence: seq, Loss: &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{AttributedActive: &edgev1.EdgeAttributedActiveV1{
			Identity: &edgev1.EdgeAttributedSpanIdentityV1{ProducerAssignmentId: recoveryUUID(4), RunId: recoveryUUID(5), ProductionScopeId: recoveryUUID(6), RunShard: 2, AuthorityEpoch: 5, ScopeSha256: recoveryDigest(7), ContractBundleSha256: recoveryDigest(8), Source: &edgev1.EdgeSourceSpanIdentityV1{Kind: edgev1.EdgeSourceAuthorizationKind(1), ContextId: recoveryUUID(21), SourceScopeId: recoveryUUID(22), SourceScopeSha256: recoveryDigest(23)}}, RangeSha256: recoveryDigest(9)}}}}
}
func recoveryPreserved(seq uint64) RecoverySlot {
	return RecoverySlot{Sequence: seq, Copy: &RecoveryCopyIntent{NewSequence: 1, EventID: recoveryUUID(10), RecordSHA256: recoveryDigest(11), SourceBindingSHA256: recoveryDigest(12), AttributionBindingSHA256: recoveryDigest(13)}}
}
func recoveryPlan(slots ...RecoverySlot) RecoveryPlan {
	return RecoveryPlan{RecoveryID: recoveryUUID(1), DetectedAtUnixNano: 1800000000000000000, Reason: "synthetic damaged segment", NewSpoolID: recoveryUUID(2), Source: GenerationIdentity{Ordinal: 1, SpoolID: recoveryUUID(3),
		Identity: Identity{NetworkScopeID: recoveryUUID(14), AgentID: []byte("agent-test-01")},
		Lane:     LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}},
		First: slots[0].Sequence, Last: slots[len(slots)-1].Sequence, HighWater: slots[len(slots)-1].Sequence, Slots: slots}
}
func recoveryGrant(t *testing.T, dir string, journalBudget uint64) *RecoveryGrant {
	t.Helper()
	a, err := NewAllocator(AllocatorConfig{Capacity: 64 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1,
		Recovery: Footprint{DestinationSegment: 1 << 20, AttributionSidecar: 1 << 20, JournalCopy: journalBudget, ManifestPages: 256 << 10, Mapping: 1 << 20, FilesystemMetadata: 4096}})
	if err != nil {
		t.Fatal(err)
	}
	g, err := a.AcquireRecovery(dir)
	if err != nil {
		t.Fatal(err)
	}
	return g
}
func reopenedRecoveryJournal(t *testing.T, p RecoveryPlan) (string, *RecoveryJournal) {
	t.Helper()
	dir := t.TempDir()
	if _, err := FreezeRecovery(dir, recoveryGrant(t, dir, 2*MaxRecoveryJournalBytes), p); err != nil {
		t.Fatal(err)
	}
	j, err := OpenRecoveryJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	return dir, j
}
func recoveryPages(t *testing.T, j *RecoveryJournal) []*edgev1.EdgeLossManifestPageV1 {
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

const recoveryMissing = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING
const recoveryTorn = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL

func TestJournalDerivedCoarsening(t *testing.T) {
	changed := recoveryActive(2)
	changed.Loss.GetAttributedActive().RangeSha256 = recoveryDigest(17)
	for _, tc := range []struct {
		name  string
		slots []RecoverySlot
		want  [][2]uint64
	}{
		{"equal adjacent bodies", []RecoverySlot{recoveryActive(1), recoveryActive(2)}, [][2]uint64{{1, 2}}},
		{"preserved gap", []RecoverySlot{recoveryActive(1), recoveryPreserved(2), recoveryActive(3)}, [][2]uint64{{1, 1}, {3, 3}}},
		{"different attributed body", []RecoverySlot{recoveryActive(1), changed}, [][2]uint64{{1, 1}, {2, 2}}},
		{"different unattributable reason", []RecoverySlot{recoveryLoss(1, recoveryMissing), recoveryLoss(2, recoveryTorn)}, [][2]uint64{{1, 1}, {2, 2}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, j := reopenedRecoveryJournal(t, recoveryPlan(tc.slots...))
			snap, err := j.FrozenPlan()
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
			for _, p := range recoveryPages(t, j) {
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
	p := recoveryPlan(recoveryPreserved(9))
	p.ReclaimThrough = 8
	p.Last = 10
	p.HighWater = 10
	dir := t.TempDir()
	g := recoveryGrant(t, dir, 2*MaxRecoveryJournalBytes)
	if j, err := FreezeRecovery(dir, g, p); j != nil || !errors.Is(err, ErrRecoveryPlan) {
		t.Fatalf("9/10 incomplete interval = %v, %v", j, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatalf("invalid plan wrote evidence: %v %v", entries, err)
	}
	p.Slots = append(p.Slots, recoveryLoss(10, recoveryTorn))
	_, j := reopenedRecoveryJournal(t, p)
	s, err := j.FrozenPlan()
	if err != nil {
		t.Fatal(err)
	}
	if s.ReclaimThrough != 8 || s.HighWater != 10 || s.Slots[0].Copy == nil || s.Slots[1].Loss == nil {
		t.Fatal("lost allocated high-water or copy/loss partition")
	}
	if got := recoveryPages(t, j)[0].ClassificationSpans; len(got) != 1 || got[0].FromSequence != 10 || got[0].ThroughSequence != 10 {
		t.Fatalf("uncommitted allocation is not a singleton loss: %v", got)
	}
	if _, err := RecoveryJournalBytes(recoveryPlan(recoveryPreserved(1))); !errors.Is(err, ErrRecoveryNoLoss) {
		t.Fatalf("copies-only invented loss: %v", err)
	}
}

func TestJournalBoundsAndPageChain(t *testing.T) {
	slots := make([]RecoverySlot, edgerecord.MaxRecoverySlots)
	for i := range slots {
		reason := recoveryMissing
		if i%2 != 0 {
			reason = recoveryTorn
		}
		slots[i] = recoveryLoss(uint64(i+1), reason)
	}
	p := recoveryPlan(slots...)
	_, j := reopenedRecoveryJournal(t, p)
	got := recoveryPages(t, j)
	if len(got) != 4 || got[0].ClassificationSpans[0].FromSequence != 1 || got[3].ClassificationSpans[255].ThroughSequence != 1024 {
		t.Fatal("bounded allocated interval did not retain all 1024 singleton losses")
	}
	p.Slots = append(p.Slots, recoveryLoss(1025, recoveryMissing))
	p.Last = 1025
	p.HighWater = 1025
	if _, err := RecoveryJournalBytes(p); !errors.Is(err, ErrRecoverySplitRequired) {
		t.Fatalf("oversized interval = %v", err)
	}
	// Rich attributed bodies exceed the aggregate wire cap before the slot cap.
	for i := range slots {
		slots[i] = recoveryActive((1 << 60) + uint64(i))
		slots[i].Loss.GetAttributedActive().Identity.RunShard = ^uint32(0) - uint32(i)
		slots[i].Loss.GetAttributedActive().Identity.AuthorityEpoch = ^uint64(0)
	}
	p = recoveryPlan(slots...)
	if _, err := RecoveryJournalBytes(p); !errors.Is(err, ErrRecoverySplitRequired) || !errors.Is(err, edgerecord.ErrManifestBounds) {
		t.Fatalf("oversized exact manifest = %v", err)
	}
}

func TestJournalRepairRequiresOneUnambiguousCopy(t *testing.T) {
	for _, damage := range []string{"missing", "torn", "checksum", "unsupported", "both torn", "divergent"} {
		t.Run(damage, func(t *testing.T) {
			dir, _ := reopenedRecoveryJournal(t, recoveryPlan(recoveryLoss(1, recoveryMissing)))
			aPath, bPath := filepath.Join(dir, recoveryCopyA), filepath.Join(dir, recoveryCopyB)
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
				binary.BigEndian.PutUint64(bad[len(recoveryJournalMagic):recoveryJournalHeader], 99)
				repairable = false
			case "both torn":
				bad = bad[:9]
				if err := os.WriteFile(aPath, bad, 0600); err != nil {
					t.Fatal(err)
				}
				repairable = false
			case "divergent":
				other, _ := reopenedRecoveryJournal(t, recoveryPlan(recoveryLoss(1, recoveryTorn)))
				bad, err = os.ReadFile(filepath.Join(other, recoveryCopyB))
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
			if j, err := OpenRecoveryJournal(dir); j != nil || err == nil {
				t.Fatalf("damaged pair became usable: %v %v", j, err)
			}
			j, err := RepairRecoveryJournal(dir, recoveryGrant(t, dir, 2*MaxRecoveryJournalBytes))
			if repairable {
				if err != nil {
					t.Fatal(err)
				}
				_ = recoveryPages(t, j)
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
				if damage == "divergent" && !errors.Is(err, ErrRecoveryJournalConflict) {
					t.Fatalf("divergence = %v", err)
				}
				if damage == "unsupported" && !errors.Is(err, ErrRecoveryJournalVersion) {
					t.Fatalf("unsupported = %v", err)
				}
			}
		})
	}
}

func TestJournalReserveFailureRetainsEvidence(t *testing.T) {
	p := recoveryPlan(recoveryLoss(1, recoveryMissing))
	size, err := RecoveryJournalBytes(p)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	g := recoveryGrant(t, dir, size-1)
	if j, err := FreezeRecovery(dir, g, p); j != nil || !errors.Is(err, ErrReserveExhausted) {
		t.Fatalf("undersized reserve = %v %v", j, err)
	}
	if _, err := os.Stat(filepath.Join(dir, recoveryCopyA)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("write preceded reserve: %v", err)
	}
	// A first copy is not sufficient after a process stops between the barriers.
	good, _ := reopenedRecoveryJournal(t, p)
	raw, err := os.ReadFile(filepath.Join(good, recoveryCopyA))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, recoveryCopyA), raw, 0600); err != nil {
		t.Fatal(err)
	}
	if j, err := OpenRecoveryJournal(dir); j != nil || !errors.Is(err, ErrRecoveryJournalIncomplete) {
		t.Fatalf("single-copy freeze accepted: %v %v", j, err)
	}
	if _, err := RepairRecoveryJournal(dir, g); err == nil {
		t.Fatal("failed grant reused for repair")
	}
	before, err := os.ReadFile(filepath.Join(dir, recoveryCopyA))
	if err != nil || !bytes.Equal(before, raw) {
		t.Fatal("failed repair lost intact copy")
	}
	if _, err := RepairRecoveryJournal(dir, recoveryGrant(t, dir, size)); err != nil {
		t.Fatal(err)
	}
}

func TestJournalImmutableIdentityAndSnapshots(t *testing.T) {
	p := recoveryPlan(recoveryActive(1))
	dir, j := reopenedRecoveryJournal(t, p)
	snap, err := j.FrozenPlan()
	if err != nil {
		t.Fatal(err)
	}
	snap.Source.Identity.AgentID[0] ^= 1
	snap.Slots[0].Loss.GetAttributedActive().RangeSha256[0] ^= 1
	again, err := j.FrozenPlan()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again.Source.Identity.AgentID, p.Source.Identity.AgentID) || !proto.Equal(again.Slots[0].Loss, p.Slots[0].Loss) {
		t.Fatal("caller mutated frozen journal")
	}
	p.NewSpoolID = recoveryUUID(20)
	if _, err := FreezeRecovery(dir, recoveryGrant(t, dir, 2*MaxRecoveryJournalBytes), p); !errors.Is(err, ErrRecoveryJournalConflict) {
		t.Fatalf("refreeze replaced identity: %v", err)
	}
	_, err = OpenRecoveryJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
}

func TestJournalCoarseningComparesEveryAttributedMember(t *testing.T) {
	mutations := map[string]func(*edgev1.EdgeAttributedActiveV1){
		"assignment":       func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ProducerAssignmentId = recoveryUUID(30) },
		"run":              func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.RunId = recoveryUUID(30) },
		"shard":            func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.RunShard++ },
		"epoch":            func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.AuthorityEpoch++ },
		"production scope": func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ProductionScopeId = recoveryUUID(30) },
		"scope hash":       func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ScopeSha256 = recoveryDigest(30) },
		"contract hash":    func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.ContractBundleSha256 = recoveryDigest(30) },
		"source presence":  func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source = nil },
		"source kind":      func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.Kind = edgev1.EdgeSourceAuthorizationKind(4) },
		"source context":   func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.ContextId = recoveryUUID(30) },
		"source scope":     func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.SourceScopeId = recoveryUUID(30) },
		"source hash":      func(b *edgev1.EdgeAttributedActiveV1) { b.Identity.Source.SourceScopeSha256 = recoveryDigest(30) },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			second := recoveryActive(2)
			mutate(second.Loss.GetAttributedActive())
			_, j := reopenedRecoveryJournal(t, recoveryPlan(recoveryActive(1), second))
			if got := recoveryPages(t, j)[0].ClassificationSpans; len(got) != 2 {
				t.Fatalf("distinct %s coarsened into %d spans", name, len(got))
			}
		})
	}
}

func TestJournalRejectsInvalidEvidenceBeforeWriting(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*RecoveryPlan)
		want   error
	}{
		{"missing detection time", func(p *RecoveryPlan) { p.DetectedAtUnixNano = 0 }, ErrRecoveryPlan},
		{"missing reason", func(p *RecoveryPlan) { p.Reason = "" }, ErrRecoveryPlan},
		{"unset body", func(p *RecoveryPlan) { p.Slots[0].Loss.Classification = nil }, edgerecord.ErrManifestSpanBody},
		{"unknown body fields", func(p *RecoveryPlan) { p.Slots[0].Loss.ProtoReflect().SetUnknown([]byte{0xf8, 0x07, 0x01}) }, edgerecord.ErrUnknownFields},
		{"non singleton", func(p *RecoveryPlan) { p.Slots[0].Loss.ThroughSequence = 2 }, ErrRecoveryPlan},
		{"both bodies", func(p *RecoveryPlan) { p.Slots[0].Copy = recoveryPreserved(1).Copy }, ErrRecoveryPlan},
		{"outside high water", func(p *RecoveryPlan) { p.HighWater = 0 }, ErrRecoveryPlan},
		{"reclaimed slot", func(p *RecoveryPlan) { p.ReclaimThrough = 1 }, ErrRecoveryPlan},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := recoveryPlan(recoveryActive(1))
			tc.mutate(&p)
			dir := t.TempDir()
			if j, err := FreezeRecovery(dir, recoveryGrant(t, dir, 2*MaxRecoveryJournalBytes), p); j != nil || !errors.Is(err, tc.want) {
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
	p := recoveryPlan(recoveryLoss(1, recoveryMissing))
	size, err := RecoveryJournalBytes(p)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	g := recoveryGrant(t, dir, size)
	if _, err := FreezeRecovery(dir, g, p); err != nil {
		t.Fatal(err)
	}
	bPath := filepath.Join(dir, recoveryCopyB)
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
	if _, err := RepairRecoveryJournal(dir, g); err == nil {
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
	if _, err := RepairRecoveryJournal(dir, g); !errors.Is(err, ErrReserveExhausted) {
		t.Fatalf("unreserved rewrite = %v", err)
	}
	after, err := os.ReadFile(bPath)
	if err != nil || !bytes.Equal(after, bad) {
		t.Fatal("failed reserved rewrite destroyed retained evidence")
	}
	if _, err := RepairRecoveryJournal(dir, recoveryGrant(t, dir, size)); err != nil {
		t.Fatal(err)
	}
}

func TestJournalRejectsPagesThatDisagreeWithSingletonEvidence(t *testing.T) {
	dir, j := reopenedRecoveryJournal(t, recoveryPlan(recoveryActive(1), recoveryActive(2)))
	snap, err := j.FrozenPlan()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := j.BuildManifest()
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a writer that persisted a valid checksum and valid final pages but
	// changed one singleton classification after the pages were constructed.
	snap.Slots[1].Loss.GetAttributedActive().RangeSha256 = recoveryDigest(31)
	payload, err := json.Marshal(frozenRecoveryRecord{Plan: snap, Manifest: manifest})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, recoveryCopyA))
	if err != nil {
		t.Fatal(err)
	}
	changed := append(append([]byte(nil), raw[:recoveryJournalHeader]...), payload...)
	sum := sha256.Sum256(changed)
	changed = append(changed, sum[:]...)
	for _, name := range []string{recoveryCopyA, recoveryCopyB} {
		if err := os.WriteFile(filepath.Join(dir, name), changed, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if j, err := OpenRecoveryJournal(dir); j != nil || !errors.Is(err, ErrRecoveryJournalCorrupt) {
		t.Fatalf("page-only evidence accepted: %v %v", j, err)
	}
}

// This crosses append admission, frozen per-sequence evidence and reopened page
// construction. Alternating complete maximum bodies prevent coarsening from
// accidentally hiding an underestimated encoded-size budget.
func TestRecoveryMaximalAdmissionFitsFrozenManifest(t *testing.T) {
	bounds := segmentBounds{limits: defaultSegmentLimits()}
	keys := [][]byte{attrKey("maximum-body-a"), attrKey("maximum-body-b")}
	var slots []RecoverySlot
	for i := 0; bounds.refusalFor(keys[i%2]) == ""; i++ {
		seq := uint64(math.MaxUint64-edgerecord.MaxRecoverySlots-1) + uint64(i)
		span := maxAttributedSpanAt(seq)
		span.GetAttributedActive().RangeSha256[0] = byte(i % 2)
		slots = append(slots, RecoverySlot{Sequence: seq, Loss: span})
		bounds.observe(keys[i%2])
	}
	if len(slots) != 817 {
		t.Fatalf("maximum admitted attributed interval changed: %d", len(slots))
	}
	plan := recoveryPlan(slots...)
	plan.ReclaimThrough = plan.First - 1
	_, journal := reopenedRecoveryJournal(t, plan)
	manifest, err := journal.BuildManifest()
	if err != nil {
		t.Fatal(err)
	}
	total := 0
	spans := 0
	for _, raw := range manifest.Pages {
		total += len(raw)
		page := new(edgev1.EdgeLossManifestPageV1)
		if err = proto.Unmarshal(raw, page); err != nil {
			t.Fatal(err)
		}
		spans += len(page.ClassificationSpans)
	}
	if len(manifest.Pages) != 4 || spans != 817 || total > edgerecord.MaxManifestBytes {
		t.Fatalf("maximum frozen manifest: pages=%d spans=%d bytes=%d", len(manifest.Pages), spans, total)
	}
	t.Logf("maximum-body frozen manifest: %d pages, %d spans, %d encoded bytes", len(manifest.Pages), spans, total)
}
