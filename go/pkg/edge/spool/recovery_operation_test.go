// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

type recoveryFixture struct {
	root, dir                    string
	lanes                        *LaneSet
	source, destination, control *Generation
	allocator                    *Allocator
	grant                        *RecoveryGrant
	operation                    *RecoveryOperation
	plan                         RecoveryPlan
	input                        AttributedAppend
	identity                     Identity
}

func recoveryOperationAllocator(t *testing.T) *Allocator {
	t.Helper()
	a, err := NewAllocator(AllocatorConfig{Capacity: 128 << 20, MinFree: 1 << 20, MaxConcurrentRecoveries: 1, Recovery: DefaultRecoveryFootprint()})
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func newRecoveryFixture(t *testing.T, copies int) *recoveryFixture {
	return newRecoveryFixtureWithTerminal(t, copies, nil)
}

func newRecoveryFixtureWithTerminal(t *testing.T, copies int, terminal func(*Generation, AttributedAppend)) *recoveryFixture {
	t.Helper()
	input, key, identity := attributionAppend(t, "metrics")
	root := t.TempDir()
	a := recoveryOperationAllocator(t)
	lanes := openAttributedLanes(t, root, identity, a, nil)
	if copies == 0 {
		if _, err := lanes.Rotate(key); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < copies; i++ {
		if _, err := lanes.AppendAttributed(key, identity, input); err != nil {
			t.Fatal(err)
		}
	}
	source, _ := lanes.OpenGeneration(key)
	source.spool.beforeBarrier = func(at barrier) error {
		if at == barrierRecord {
			return syscall.EIO
		}
		return nil
	}
	if _, err := lanes.AppendAttributed(key, identity, input); !errors.Is(err, syscall.EIO) {
		t.Fatalf("allocated ambiguous tail: %v", err)
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	a = recoveryOperationAllocator(t)
	lanes = openAttributedLanes(t, root, identity, a, nil)
	source, _ = lanes.OpenGeneration(key)
	if _, err := lanes.Rotate(key); err != nil {
		t.Fatal(err)
	}
	if terminal != nil {
		terminal(source, input)
	}
	id := recoveryUUID(83)
	destination, grant, err := lanes.BeginRecoveryDestination(source, id, 0, a)
	if err != nil {
		t.Fatal(err)
	}
	controlKey := LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	control, err := lanes.CreateRecoveryControlDestination(controlKey, id, 0, grant)
	if err != nil {
		t.Fatal(err)
	}
	plan := RecoveryPlan{RecoveryID: id, DetectedAtUnixNano: 1800000000000000000, Reason: "synthetic interrupted append", Source: source.Identity(), NewSpoolID: destination.Identity().SpoolID, First: 1, Last: uint64(copies + 1), HighWater: uint64(copies + 1)}
	for seq := uint64(1); seq <= uint64(copies); seq++ {
		witness, err := source.spool.retainedCopySource(seq)
		if err != nil {
			t.Fatal(err)
		}
		coordinates := bindingCoordinates(destination.id, seq, witness.record.EventID, witness.entry.coordinates.RecordSHA256)
		binding, err := edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, coordinates, witness.Attribution())
		if err != nil {
			t.Fatal(err)
		}
		plan.Slots = append(plan.Slots, RecoverySlot{Sequence: seq, Copy: &RecoveryCopyIntent{NewSequence: seq, EventID: witness.record.EventID, RecordSHA256: witness.entry.coordinates.RecordSHA256, SourceBindingSHA256: bytes.Clone(witness.entry.digest), AttributionBindingSHA256: binding}})
	}
	loss, err := source.RecoveryClassification(uint64(copies + 1))
	if err != nil {
		t.Fatal(err)
	}
	plan.Slots = append(plan.Slots, RecoverySlot{Sequence: uint64(copies + 1), Loss: loss})
	dir := t.TempDir()
	if _, err = FreezeRecovery(dir, grant, plan); err != nil {
		t.Fatal(err)
	}
	operation, err := OpenRecoveryOperation(dir, source, destination, grant)
	if err != nil {
		t.Fatal(err)
	}
	f := &recoveryFixture{root: root, dir: dir, lanes: lanes, source: source, destination: destination, control: control, allocator: a, grant: grant, operation: operation, plan: plan, input: input, identity: identity}
	t.Cleanup(func() {
		if err := f.lanes.Close(); err != nil {
			t.Error(err)
		}
	})
	return f
}

func recoveryControlInputs(t *testing.T, f *recoveryFixture) []AttributedAppend {
	return recoveryControlInputsAtEpoch(t, f, 0)
}

func recoveryControlInputsAtEpoch(t *testing.T, f *recoveryFixture, epochDelta uint64) []AttributedAppend {
	t.Helper()
	manifest, err := constructRecoveryManifest(f.plan)
	if err != nil {
		t.Fatal(err)
	}
	result := make([]AttributedAppend, len(manifest.Pages)+1)
	for i := range result {
		result[i], _, _ = attributionAppendMutated(t, "control", func(r *edgev1.EdgeRecordV1) {
			wrapper := &edgev1.EdgeRecoveryControlPayloadV1{}
			var scope []byte
			if i < len(manifest.Pages) {
				page := new(edgev1.EdgeLossManifestPageV1)
				if err := proto.Unmarshal(manifest.Pages[i], page); err != nil {
					t.Fatal(err)
				}
				wrapper.Body = &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page}
				scope = edgerecord.ManifestPageScopeDigest(page)
			} else {
				tomb := new(edgev1.SpoolLossTombstoneV1)
				if err := proto.Unmarshal(manifest.Tombstone, tomb); err != nil {
					t.Fatal(err)
				}
				wrapper.Body = &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb}
				scope = edgerecord.TombstoneScopeDigest(tomb)
			}
			payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(wrapper)
			if err != nil {
				t.Fatal(err)
			}
			r.Payload = payload
			hash := sha256.Sum256(payload)
			r.PayloadSha256 = hash[:]
			r.EncodedSize = uint32(len(payload))
			r.UncompressedSize = uint32(len(payload))
			r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE
			r.EventId[15] += byte(i + 1)
			r.NetworkScopeId = bytes.Clone(f.identity.NetworkScopeID)
			r.ProducerContext.OriginPrincipalId = bytes.Clone(f.identity.AgentID)
			production := r.ProductionCapability.GetProduction()
			production.NetworkScopeId = bytes.Clone(f.identity.NetworkScopeID)
			production.OriginPrincipalId = bytes.Clone(f.identity.AgentID)
			source := r.SourceAuthorization
			source.ContextId = bytes.Clone(f.plan.RecoveryID)
			source.ScopeId = bytes.Clone(f.plan.RecoveryID)
			source.ScopeSha256 = bytes.Clone(scope)
			claims := source.Capability.GetSource()
			claims.ContextId = bytes.Clone(source.ContextId)
			claims.ScopeId = bytes.Clone(source.ScopeId)
			claims.ScopeSha256 = bytes.Clone(scope)
			claims.NetworkScopeId = bytes.Clone(f.identity.NetworkScopeID)
			claims.OriginPrincipalId = bytes.Clone(f.identity.AgentID)
			if epochDelta != 0 {
				epoch := r.ProducerContext.GetAuthorityEpoch() + epochDelta
				r.ProducerContext.AuthorityEpoch = proto.Uint64(epoch)
				production.AuthorityEpoch = epoch
				claims.AuthorityEpoch = epoch
				r.EventId[14] += byte(epochDelta)
			}
		})
	}
	return result
}

func recoveryAuthoritativeAck(t *testing.T, g *Generation, records []AttributedAppend, kind edgev1.EdgeRecordDispositionKind) (*edgerecord.ValidatedAck, []byte) {
	t.Helper()
	session := edgerecord.Session{SpoolID: g.Identity().SpoolID, RouteProfile: g.id.Lane.RouteProfile, TrafficClass: g.id.Lane.TrafficClass, Nonce: bytes.Repeat([]byte{0x52}, 32), HighestSent: uint64(len(records)), NextSequence: uint64(len(records) + 1), FirstUnresolved: 1, SentEvents: map[uint64][]byte{}}
	ack := &edgev1.EdgeDeliveryAckV1{SpoolId: session.SpoolID, SessionNonce: session.Nonce, ResolvedThroughSequence: uint64(len(records))}
	for i, r := range records {
		seq := uint64(i + 1)
		session.SentEvents[seq] = r.EventID
		disposition := &edgev1.EdgeRecordDisposition{Sequence: seq, EventId: r.EventID, Kind: kind}
		if kind == edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT {
			disposition.RejectionCode = "SYNTHETIC_REJECTION"
		}
		ack.Dispositions = append(ack.Dispositions, disposition)
	}
	validated, err := edgerecord.ValidateAckEvidence(ack, session, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	return validated, raw
}

func prepareRecoveryPublications(t *testing.T, f *recoveryFixture) []AttributedAppend {
	t.Helper()
	records := recoveryControlInputs(t, f)
	if err := f.operation.FreezePublications(0, records); err != nil {
		t.Fatal(err)
	}
	if err := f.operation.BeginControlAttempt(f.control); err != nil {
		t.Fatal(err)
	}
	for i := range records {
		if _, err := f.operation.Publish(f.control, i); err != nil {
			t.Fatal(err)
		}
	}
	return records
}

func TestRecoveryCoverageRequiresAllocatedTailAndAuthoritativePublication(t *testing.T) {
	f := newRecoveryFixture(t, 9)
	held, err := f.source.RecoverySourceHeld()
	if err != nil || !held {
		t.Fatal("source sender not suspended", held, err)
	}
	held, err = f.destination.RecoverySourceHeld()
	if err != nil || held {
		t.Fatal("destination sender suppressed", held, err)
	}
	records := prepareRecoveryPublications(t, f)
	for seq := uint64(1); seq <= 9; seq++ {
		if _, err := f.operation.Copy(seq); err != nil {
			t.Fatal(err)
		}
	}
	_, early := recoveryAuthoritativeAck(t, f.destination, bytesRepeatedAppend(f.input, 9), edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	if err := f.destination.ResolveWithEvidence(9, early); !errors.Is(err, ErrRecoveryHeld) {
		t.Fatalf("early destination ACK escaped hold: %v", err)
	}
	if _, err := f.operation.SealCoverage(); err == nil {
		t.Fatal("nine copied records covered ten allocations without PubAck")
	}
	audit, _ := recoveryAuthoritativeAck(t, f.control, records, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY)
	if err := f.operation.CapturePublicationAck(f.control, 0, audit); !errors.Is(err, ErrRecoveryCoverage) {
		t.Fatalf("audit acceptance covered loss: %v", err)
	}
	accepted, terminal := recoveryAuthoritativeAck(t, f.control, records, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	for i := range records {
		if err := f.operation.CapturePublicationAck(f.control, i, accepted); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.control.ResolveWithEvidence(uint64(len(records)), terminal); err != nil {
		t.Fatal(err)
	}
	certificate, err := f.operation.SealCoverage()
	if err != nil {
		t.Fatal(err)
	}
	first, last := certificate.Interval()
	if first != 1 || last != 10 {
		t.Fatalf("wrong interval: %d %d", first, last)
	}
	if err = f.destination.ResolveWithEvidence(9, early); err != nil {
		t.Fatal("ACK did not retry after certificate", err)
	}
	if _, err = f.destination.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
		t.Fatal("destination witness ignored terminal prefix", err)
	}
	reopened, err := OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reopened.SealCoverage(); err != nil {
		t.Fatal("durable certificate depended on still-unresolved destination", err)
	}
	if _, err = os.Stat(filepath.Join(f.source.dir, segmentFile)); err != nil {
		t.Fatal("certificate prematurely deleted source", err)
	}
}

func bytesRepeatedAppend(input AttributedAppend, n int) []AttributedAppend {
	out := make([]AttributedAppend, n)
	for i := range out {
		out[i] = input
	}
	return out
}

// Crash injection uses the allocator's real durable-file boundary, not an
// operation callback that could accidentally supply the ordering being tested.
type recoveryCrashFS struct {
	fileSystem
	failOpen, failRemove string
}

func (f recoveryCrashFS) OpenFile(path string, flag int, mode os.FileMode) (durableFile, error) {
	if path == f.failOpen {
		return nil, syscall.EIO
	}
	return f.fileSystem.OpenFile(path, flag, mode)
}
func (f recoveryCrashFS) Remove(path string) error {
	if path == f.failRemove {
		return syscall.EIO
	}
	return f.fileSystem.Remove(path)
}

func resumeRecoveryFixture(t *testing.T, f *recoveryFixture) {
	t.Helper()
	var inventory []RecoveryArtifact
	addTree := func(root string, classify func(string, fs.DirEntry) (Artifact, bool)) {
		t.Helper()
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if art, ok := classify(path, entry); ok {
				inventory = append(inventory, RecoveryArtifact{art, path})
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	addTree(f.dir, func(path string, e fs.DirEntry) (Artifact, bool) {
		if e.IsDir() {
			return ArtifactFilesystemMetadata, false
		}
		name := e.Name()
		art := ArtifactJournalA
		if strings.HasSuffix(name, "-b") || strings.HasSuffix(name, "-b.tmp") {
			art = ArtifactJournalB
		}
		if strings.HasPrefix(name, "phase-coverage-") || strings.HasPrefix(name, recoveryArchiveFile) {
			art = ArtifactMapping
		}
		return art, true
	})
	for _, g := range []*Generation{f.source, f.destination} {
		addTree(filepath.Join(g.dir, recoveryDirectory), func(_ string, e fs.DirEntry) (Artifact, bool) {
			if e.IsDir() {
				return ArtifactFilesystemMetadata, true
			}
			return ArtifactMapping, true
		})
	}
	for _, g := range []*Generation{f.destination, f.control} {
		addTree(g.dir, func(path string, e fs.DirEntry) (Artifact, bool) {
			relative, _ := filepath.Rel(g.dir, path)
			if e.IsDir() || strings.HasPrefix(relative, recoveryDirectory+string(filepath.Separator)) {
				return 0, false
			}
			// Dedicated generation metadata and interrupted temporaries belong to
			// the original grant along with committed append files.
			name := strings.TrimSuffix(e.Name(), ".tmp")
			if name == closedFile {
				return 0, false
			}
			art := ArtifactDestinationSegment
			if name == attributionFile || name == relocationFile {
				art = ArtifactAttributionSidecar
			}
			if g == f.control {
				art = ArtifactManifestPages
			}
			return art, true
		})
	}
	destinationDir, sourceDir, controlDir := f.destination.dir, f.source.dir, f.control.dir
	terminalSlots := f.destination.NextSequence() - 1 - f.destination.Resolved()
	controlSlots := f.control.NextSequence() - 1 - f.control.Resolved()
	if err := f.lanes.Close(); err != nil {
		t.Fatal(err)
	}
	fresh := recoveryOperationAllocator(t)
	grant, err := fresh.ResumeRecoveryWithControls(destinationDir, []RecoveryControlInventory{{Directory: controlDir, TerminalSlots: controlSlots}}, inventory, terminalSlots)
	if err != nil {
		t.Fatal(err)
	}
	lanes := openAttributedLanes(t, f.root, f.identity, fresh, nil)
	for _, key := range lanes.Lanes() {
		for _, g := range lanes.Generations(key) {
			switch g.dir {
			case sourceDir:
				f.source = g
			case destinationDir:
				f.destination = g
			case controlDir:
				f.control = g
			}
		}
	}
	f.lanes, f.allocator, f.grant = lanes, fresh, grant
	f.operation = nil
}

func acknowledgeRecoveryPublications(t *testing.T, f *recoveryFixture, records []AttributedAppend) {
	t.Helper()
	ack, _ := recoveryAuthoritativeAck(t, f.control, records, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	for i := range records {
		if err := f.operation.CapturePublicationAck(f.control, i, ack); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRecoveryCoverageCrashRetainsHoldUntilBothCertificateCopies(t *testing.T) {
	for _, crash := range []string{"second_certificate", "release_hold", "divergent_certificate"} {
		t.Run(crash, func(t *testing.T) {
			f := newRecoveryFixture(t, 1)
			records := prepareRecoveryPublications(t, f)
			if _, err := f.operation.Copy(1); err != nil {
				t.Fatal(err)
			}
			acknowledgeRecoveryPublications(t, f, records)
			failing := recoveryCrashFS{fileSystem: osFS{}}
			if crash == "second_certificate" {
				failing.failOpen = recoveryPhasePath(f.dir, "coverage", 1) + ".tmp"
			} else {
				failing.failRemove = f.destination.spool.recoveryHoldPath()
			}
			f.allocator.fs = failing
			if _, err := f.operation.SealCoverage(); !errors.Is(err, syscall.EIO) {
				t.Fatalf("crash not reached: %v", err)
			}
			_, terminal := recoveryAuthoritativeAck(t, f.destination, []AttributedAppend{f.input}, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
			if err := f.destination.ResolveWithEvidence(1, terminal); !errors.Is(err, ErrRecoveryHeld) {
				t.Fatalf("interrupted coverage released hold: %v", err)
			}
			if crash == "divergent_certificate" {
				raw, err := readRecoveryPhase(f.dir, "coverage", f.operation.frozen)
				if err != nil {
					t.Fatal(err)
				}
				raw[len(raw)-1] ^= 1
				encoded, err := encodeRecoveryPhase(f.operation.frozen, "coverage", raw)
				if err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(recoveryPhasePath(f.dir, "coverage", 1), encoded, filePerm); err != nil {
					t.Fatal(err)
				}
			}
			resumeRecoveryFixture(t, f)
			if crash == "divergent_certificate" {
				if _, err := OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant); !errors.Is(err, ErrRecoveryJournalConflict) {
					t.Fatal("divergent pair proved progress", err)
				}
				if err := RepairRecoveryPhases(f.dir, f.grant); !errors.Is(err, ErrRecoveryJournalConflict) {
					t.Fatal("repair selected a conflicting copy", err)
				}
				if err := f.destination.ResolveWithEvidence(1, terminal); !errors.Is(err, ErrRecoveryHeld) {
					t.Fatal("conflict released hold", err)
				}
				return
			}
			if crash == "second_certificate" {
				if _, err := OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant); !errors.Is(err, ErrRecoveryJournalIncomplete) {
					t.Fatalf("single copy proved progress: %v", err)
				}
				if err := RepairRecoveryPhases(f.dir, f.grant); err != nil {
					t.Fatal(err)
				}
			}
			var err error
			f.operation, err = OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = f.operation.SealCoverage(); err != nil {
				t.Fatal(err)
			}
			if err = f.destination.ResolveWithEvidence(1, terminal); err != nil {
				t.Fatal("held ACK did not retry", err)
			}
			if _, err = os.Stat(filepath.Join(f.source.dir, segmentFile)); err != nil {
				t.Fatal("crash deleted source", err)
			}
		})
	}
}

func TestRecoveryCopiesRetainedTerminalPrefixBeforeAmbiguousGap(t *testing.T) {
	var originalTerminal []byte
	f := newRecoveryFixtureWithTerminal(t, 2, func(source *Generation, input AttributedAppend) {
		ack := &edgev1.EdgeDeliveryAckV1{SpoolId: source.id.SpoolID, SessionNonce: bytes.Repeat([]byte{0x61}, 32), ResolvedThroughSequence: 2, Dispositions: []*edgev1.EdgeRecordDisposition{
			{Sequence: 1, EventId: input.EventID, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE},
			{Sequence: 2, EventId: input.EventID, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT, RejectionCode: "SYNTHETIC_REJECTION"},
		}}
		var err error
		originalTerminal, err = proto.Marshal(ack)
		if err != nil {
			t.Fatal(err)
		}
		if err = source.ResolveWithEvidence(2, originalTerminal); err != nil {
			t.Fatal(err)
		}
		if source.spool.baseSeq != 0 {
			t.Fatal("partial terminal prefix physically reclaimed")
		}
		if _, err = source.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
			t.Fatal("ordinary copy witness accepted resolved source", err)
		}
	})
	records := prepareRecoveryPublications(t, f)
	for seq := uint64(1); seq <= 2; seq++ {
		if _, err := f.operation.Copy(seq); err != nil {
			t.Fatal("retained prefix was omitted", err)
		}
	}
	acknowledgeRecoveryPublications(t, f, records)
	certificate, err := f.operation.SealCoverage()
	if err != nil {
		t.Fatal(err)
	}
	first, last := certificate.Interval()
	if first != 1 || last != 3 {
		t.Fatalf("resolved watermark replaced physical base: %d..%d", first, last)
	}
	// Source evidence must survive this proof checkpoint; archive/reclamation is
	// a separate owner and is not authorized merely by terminal acceptance.
	entries, err := os.ReadDir(f.source.spool.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range entries {
		if !entry.IsDir() {
			raw, err := os.ReadFile(filepath.Join(f.source.spool.dataDir, entry.Name()))
			if err != nil {
				t.Fatal(err)
			}
			found = found || bytes.Contains(raw, originalTerminal)
		}
	}
	if !found {
		t.Fatal("original accepted/rejected terminal evidence disappeared")
	}
	if err = f.operation.ArchiveTerminalEvidence(); err != nil {
		t.Fatal(err)
	}
	archive, err := os.ReadFile(filepath.Join(f.dir, recoveryArchiveFile))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(archive, originalTerminal) || !bytes.Contains(archive, f.input.Body) {
		t.Fatal("archive omitted original rejection/raw record")
	}
}

func TestRecoveryControlRestartReplaysFrozenPublicationAfterTornAppend(t *testing.T) {
	f := newRecoveryFixture(t, 1)
	expected := recoveryControlInputs(t, f)
	if err := f.operation.FreezePublications(0, expected); err != nil {
		t.Fatal(err)
	}
	if err := f.operation.BeginControlAttempt(f.control); err != nil {
		t.Fatal(err)
	}
	f.control.spool.beforeBarrier = func(at barrier) error {
		if at == barrierCommitA {
			return syscall.EIO
		}
		return nil
	}
	if _, err := f.operation.Publish(f.control, 0); !errors.Is(err, syscall.EIO) {
		t.Fatal("control append did not tear", err)
	}
	oldControlDir := f.control.dir
	evidence, err := os.ReadFile(f.control.spool.evidencePath(copyA))
	if err != nil {
		t.Fatal(err)
	}
	resumeRecoveryFixture(t, f)
	f.operation, err = OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
	if err != nil {
		t.Fatal(err)
	}
	replacement, err := f.lanes.CreateRecoveryControlDestination(f.control.id.Lane, f.plan.RecoveryID, 1, f.grant)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.operation.ReplayPublications(0, 1); err != nil {
		t.Fatal(err)
	}
	if err = f.operation.BeginControlAttempt(replacement); err != nil {
		t.Fatal(err)
	}
	for i, want := range expected {
		receipt, err := f.operation.Publish(replacement, i)
		if err != nil {
			t.Fatal(err)
		}
		proof, err := replacement.CommittedAttribution(receipt.Sequence)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(proof.record.Body, want.Body) || !bytes.Equal(proof.record.EventID, want.EventID) {
			t.Fatal("restart regenerated signed bytes/event")
		}
	}
	retained, err := os.ReadFile(filepath.Join(oldControlDir, evidenceDirName(copyA), evidenceFile))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(evidence, retained) {
		t.Fatal("replacement erased ambiguous control evidence")
	}
	if usage := f.allocator.Usage(); usage.ActiveRecoveries != 1 {
		t.Fatal("control retry acquired another grant", usage)
	}
}

type archiveCrashFile struct {
	durableFile
	remaining int
}

func (f *archiveCrashFile) Write(raw []byte) (int, error) {
	if f.remaining == 0 {
		return 0, syscall.EIO
	}
	n, err := f.durableFile.Write(raw[:min(len(raw), f.remaining)])
	f.remaining -= n
	if err == nil && n < len(raw) {
		err = syscall.EIO
	}
	return n, err
}

type archiveCrashFS struct{ fileSystem }

func (f archiveCrashFS) OpenFile(path string, flag int, mode os.FileMode) (durableFile, error) {
	file, err := f.fileSystem.OpenFile(path, flag, mode)
	if err == nil && strings.HasSuffix(path, recoveryArchiveFile+".tmp") {
		return &archiveCrashFile{file, 117}, nil
	}
	return file, err
}

func TestRecoveryTerminalArchiveResumesWithoutDroppingEvidence(t *testing.T) {
	for _, mode := range []string{"partial", "corrupt_prefix", "capacity"} {
		t.Run(mode, func(t *testing.T) {
			f := newRecoveryFixtureWithTerminal(t, 1, func(source *Generation, input AttributedAppend) {
				ack := &edgev1.EdgeDeliveryAckV1{SpoolId: source.id.SpoolID, SessionNonce: bytes.Repeat([]byte{0x62}, 32), ResolvedThroughSequence: 1, Dispositions: []*edgev1.EdgeRecordDisposition{{Sequence: 1, EventId: input.EventID, Kind: edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT, RejectionCode: "SYNTHETIC_ARCHIVE"}}}
				raw, err := proto.Marshal(ack)
				if err != nil {
					t.Fatal(err)
				}
				if err = source.ResolveWithEvidence(1, raw); err != nil {
					t.Fatal(err)
				}
			})
			records := prepareRecoveryPublications(t, f)
			if _, err := f.operation.Copy(1); err != nil {
				t.Fatal(err)
			}
			acknowledgeRecoveryPublications(t, f, records)
			if _, err := f.operation.SealCoverage(); err != nil {
				t.Fatal(err)
			}
			if mode == "capacity" {
				if err := f.grant.Charge(ArtifactMapping, f.grant.Remaining(ArtifactMapping)-1); err != nil {
					t.Fatal(err)
				}
				if err := f.operation.ArchiveTerminalEvidence(); !errors.Is(err, ErrReserveExhausted) {
					t.Fatal("archive ignored exact capacity", err)
				}
				if _, err := os.Stat(filepath.Join(f.dir, recoveryArchiveFile+".tmp")); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("capacity refusal wrote archive", err)
				}
				if _, err := os.Stat(f.source.spool.segmentPath()); err != nil {
					t.Fatal("capacity refusal deleted source", err)
				}
				return
			}
			f.allocator.fs = archiveCrashFS{osFS{}}
			if err := f.operation.ArchiveTerminalEvidence(); !errors.Is(err, syscall.EIO) {
				t.Fatal("archive crash not reached", err)
			}
			path := filepath.Join(f.dir, recoveryArchiveFile+".tmp")
			prefix, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if len(prefix) != 117 {
				t.Fatalf("wrong crash prefix size: %d", len(prefix))
			}
			if mode == "corrupt_prefix" {
				prefix[len(prefix)-1] ^= 1
				if err = os.WriteFile(path, prefix, filePerm); err != nil {
					t.Fatal(err)
				}
			}
			resumeRecoveryFixture(t, f)
			f.operation, err = OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
			if err != nil {
				t.Fatal(err)
			}
			err = f.operation.ArchiveTerminalEvidence()
			if mode == "corrupt_prefix" {
				if !errors.Is(err, ErrRecoveryJournalConflict) {
					t.Fatal("corrupt prefix overwritten", err)
				}
				retained, err := os.ReadFile(path)
				if err != nil || !bytes.Equal(retained, prefix) {
					t.Fatal("corrupt evidence dropped", err)
				}
				if _, err = os.Stat(f.source.spool.segmentPath()); err != nil {
					t.Fatal("corrupt archive deleted source", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			complete, err := os.ReadFile(filepath.Join(f.dir, recoveryArchiveFile))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.HasPrefix(complete, prefix) || !bytes.Contains(complete, f.input.Body) {
				t.Fatal("resumed archive changed prefix or lost rejected record")
			}
			if err = f.operation.ArchiveTerminalEvidence(); err != nil {
				t.Fatal("archive replay was not idempotent", err)
			}
		})
	}
}

func recoveryResolutionEvidence(t *testing.T, f *recoveryFixture, alter func(*edgev1.RecoveryResolvedV1, *edgev1.EdgeSourceClaimsV1)) *edgerecord.ValidatedRecoveryResolution {
	t.Helper()
	tomb := new(edgev1.SpoolLossTombstoneV1)
	if err := proto.Unmarshal(f.operation.manifest.Tombstone, tomb); err != nil {
		t.Fatal(err)
	}
	body := &edgev1.RecoveryResolvedV1{RecoveryId: bytes.Clone(f.plan.RecoveryID), ManifestRootSha256: bytes.Clone(tomb.ManifestRootSha256), AppliedThroughSequence: f.plan.Last, ResolvedAtUnixNano: 1500}
	claims := &edgev1.EdgeSourceClaimsV1{Kind: edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL, NetworkScopeId: bytes.Clone(f.identity.NetworkScopeID), OriginPrincipalId: bytes.Clone(f.identity.AgentID), ContextId: bytes.Clone(f.plan.RecoveryID), ScopeId: bytes.Clone(f.plan.RecoveryID)}
	if alter != nil {
		alter(body, claims)
	}
	claims.ScopeSha256 = edgerecord.ResolvedScopeDigest(body)
	private := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x71}, ed25519.SeedSize))
	cap := &edgev1.EdgeSignedCapabilityV1{CapabilityVersion: 1, IssuerId: []byte("synthetic-core"), IssuerKeyId: []byte("synthetic-completion-key"), Algorithm: "ed25519", NotBeforeUnixNano: 1000, ExpiresAtUnixNano: 2000, Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: claims}}
	edgerecord.SignCapability(cap, private)
	policy := edgerecord.AuthorizationPolicy{Trust: attributionTrust(private.Public().(ed25519.PublicKey)), NowUnixNano: 3000, TrustPolicyEpoch: 1}
	proof, err := edgerecord.ValidateRecoveryResolution(body, cap, claims.NetworkScopeId, claims.OriginPrincipalId, policy)
	if err != nil {
		t.Fatal(err)
	}
	return proof
}

func TestRecoveryReclaimRequiresCompleteProofAndRetainsSignedCompletion(t *testing.T) {
	f := newRecoveryFixture(t, 2)
	if err := f.operation.ReclaimSource(); err == nil {
		t.Fatal("unproved source deleted")
	}
	records := prepareRecoveryPublications(t, f)
	for seq := uint64(1); seq <= 2; seq++ {
		if _, err := f.operation.Copy(seq); err != nil {
			t.Fatal(err)
		}
	}
	acknowledgeRecoveryPublications(t, f, records)
	if _, err := f.operation.SealCoverage(); err != nil {
		t.Fatal(err)
	}
	if err := f.operation.ReclaimSource(); err == nil {
		t.Fatal("source reclaimed without terminal archive checkpoint")
	}
	if err := f.operation.ArchiveTerminalEvidence(); err != nil {
		t.Fatal(err)
	}
	before, err := f.source.spool.laneBytes()
	if err != nil {
		t.Fatal(err)
	}
	if err = f.operation.ReclaimSource(); err != nil {
		t.Fatal(err)
	}
	if f.source.spool.baseSeq != 3 || f.source.Resolved() != 3 {
		t.Fatal("covered high-water not reclaimed")
	}
	after, err := f.source.spool.laneBytes()
	if err != nil || after >= before {
		t.Fatalf("source physical bytes not released: %d -> %d: %v", before, after, err)
	}
	if held, err := f.source.RecoverySourceHeld(); err != nil || held {
		t.Fatal("reclaimed old sender remains suspended", held, err)
	}
	if f.allocator.Usage().ActiveRecoveries != 1 {
		t.Fatal("released journals before signed completion")
	}
	for _, alter := range []func(*edgev1.RecoveryResolvedV1, *edgev1.EdgeSourceClaimsV1){
		func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSourceClaimsV1) { r.AppliedThroughSequence = 2 },
		func(r *edgev1.RecoveryResolvedV1, _ *edgev1.EdgeSourceClaimsV1) { r.ManifestRootSha256[0] ^= 1 },
		func(_ *edgev1.RecoveryResolvedV1, c *edgev1.EdgeSourceClaimsV1) {
			c.OriginPrincipalId = []byte("another-synthetic-agent")
		},
	} {
		if err = f.operation.RecordResolution(recoveryResolutionEvidence(t, f, alter)); !errors.Is(err, edgerecord.ErrRecoveryResolution) {
			t.Fatal("signed mismatched receipt released journals", err)
		}
	}
	if err = f.operation.RecordResolution(recoveryResolutionEvidence(t, f, nil)); err != nil {
		t.Fatal(err)
	}
	if f.allocator.Usage().ActiveRecoveries != 1 {
		t.Fatal("completion released grant before same-owner cleanup")
	}
	original, cap, err := f.operation.ReadSignedResolution()
	if err != nil || original.AppliedThroughSequence != 3 || len(cap.Signature) != ed25519.SignatureSize {
		t.Fatal("original signed completion not durable", err)
	}
	if _, err = os.Stat(filepath.Join(f.dir, recoveryArchiveFile)); err != nil {
		t.Fatal("terminal archive dropped on completion", err)
	}
	if _, err = OpenRecoveryJournal(f.dir); err != nil {
		t.Fatal("retained completed journal missing", err)
	}
}

func TestRecoveryReclaimResumesAroundPhysicalPublication(t *testing.T) {
	for _, boundary := range []barrier{barrierReclaimPrepared, barrierReclaimPublished} {
		t.Run(fmt.Sprintf("barrier_%d", boundary), func(t *testing.T) {
			f := newRecoveryFixture(t, 1)
			records := prepareRecoveryPublications(t, f)
			if _, err := f.operation.Copy(1); err != nil {
				t.Fatal(err)
			}
			acknowledgeRecoveryPublications(t, f, records)
			if _, err := f.operation.SealCoverage(); err != nil {
				t.Fatal(err)
			}
			if err := f.operation.ArchiveTerminalEvidence(); err != nil {
				t.Fatal(err)
			}
			f.source.spool.beforeBarrier = func(at barrier) error {
				if at == boundary {
					return syscall.EIO
				}
				return nil
			}
			if err := f.operation.ReclaimSource(); !errors.Is(err, syscall.EIO) {
				t.Fatal("reclaim crash not reached", err)
			}
			resumeRecoveryFixture(t, f)
			var err error
			f.operation, err = OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
			if err != nil {
				t.Fatal(err)
			}
			if err = f.operation.ReclaimSource(); err != nil {
				t.Fatal("reclaim did not resume", err)
			}
			if f.source.spool.baseSeq != 2 {
				t.Fatal("source not reclaimed")
			}
			if err = f.operation.RecordResolution(recoveryResolutionEvidence(t, f, nil)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRecoveryAuthorityAttemptsKeepIndependentReceiptsAndFrozenBodies(t *testing.T) {
	f := newRecoveryFixture(t, 0)
	original := prepareRecoveryPublications(t, f)
	before, err := os.ReadFile(recoveryPhasePath(f.dir, recoveryPublicationsKey(0), 0))
	if err != nil {
		t.Fatal(err)
	}
	oldAck, _ := recoveryAuthoritativeAck(t, f.control, original, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	if err := f.operation.CapturePublicationAck(f.control, 0, oldAck); err != nil {
		t.Fatal(err)
	}
	refreshed := recoveryControlInputsAtEpoch(t, f, 1)
	if err := f.operation.FreezePublications(0, refreshed); !errors.Is(err, ErrRecoveryJournalConflict) {
		t.Fatalf("rewrote frozen authority attempt: %v", err)
	}
	if err := f.operation.FreezePublications(1, refreshed); err != nil {
		t.Fatal(err)
	}
	second, err := f.lanes.CreateRecoveryControlDestination(f.control.id.Lane, f.plan.RecoveryID, 1, f.grant)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.operation.BeginControlAttempt(second); err != nil {
		t.Fatal(err)
	}
	for i := range refreshed {
		if _, err := f.operation.Publish(second, i); err != nil {
			t.Fatal(err)
		}
		proof, err := second.CommittedAttribution(uint64(i + 1))
		if err != nil || !bytes.Equal(proof.record.Body, refreshed[i].Body) || bytes.Equal(proof.record.Body, original[i].Body) {
			t.Fatalf("authority attempt did not retain its own exact bytes: %v", err)
		}
	}
	audit, _ := recoveryAuthoritativeAck(t, second, refreshed, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY)
	if err := f.operation.CapturePublicationAck(second, 1, audit); !errors.Is(err, ErrRecoveryCoverage) {
		t.Fatalf("audit-only counted as applied publication: %v", err)
	}
	if _, err := f.operation.SealCoverage(); err == nil {
		t.Fatal("coverage sealed without authoritative tombstone")
	}
	current, _ := recoveryAuthoritativeAck(t, second, refreshed, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	if err := f.operation.CapturePublicationAck(second, 1, current); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reopened.SealCoverage(); err != nil {
		t.Fatalf("reopened mixed-attempt receipts lost: %v", err)
	}
	after, err := os.ReadFile(recoveryPhasePath(f.dir, recoveryPublicationsKey(0), 0))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("new attempt changed original bundle", err)
	}
	beforeUsage := f.allocator.Usage()
	if _, err := f.lanes.CreateRecoveryControlDestination(f.control.id.Lane, f.plan.RecoveryID, MaxRecoveryControlAttempts, f.grant); !errors.Is(err, ErrRecoverySplitRequired) {
		t.Fatalf("unbounded retained attempts: %v", err)
	}
	if f.allocator.Usage() != beforeUsage {
		t.Fatal("refused attempt consumed reserve")
	}
}

// This is a serialization bound, not a semantic control fixture. It measures the
// largest permitted byte arrays through the actual persisted JSON and framing.
func TestRecoveryTwoAuthorityAttemptSerializationFitsReservedBudget(t *testing.T) {
	records := make([]frozenRecoveryPublication, maxRecoveryPublications)
	remaining := MaxRecoveryPublicationBytes
	for i := range records {
		// One-byte remainder maximizes base64 padding for all but the last body.
		size := 1
		if i == len(records)-1 {
			size = remaining
		}
		records[i] = frozenRecoveryPublication{EventID: bytes.Repeat([]byte{1}, 16), Body: bytes.Repeat([]byte{2}, size), Attribution: bytes.Repeat([]byte{3}, maxFrozenRecoveryAttributionBytes)}
		remaining -= size
	}
	raw, err := json.Marshal(records)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > maxRecoveryPublicationBundleBytes {
		t.Fatalf("serialized bundle %d exceeds bound %d", len(raw), maxRecoveryPublicationBundleBytes)
	}
	framed, err := encodeRecoveryPhase([32]byte{}, recoveryPublicationsKey(1), raw)
	if err != nil {
		t.Fatal(err)
	}
	total := MaxRecoveryControlAttempts * len(framed)
	// Every metadata phase gets its complete enforced payload allowance.
	for _, key := range []string{"attempt-000", "attempt-001", "ack-000", "ack-001", "ack-002", "ack-003", "ack-004", "archive", "delete", "reclaimed", "resolved"} {
		phase, err := encodeRecoveryPhase([32]byte{}, key, make([]byte, maxRecoveryMetadataPhaseBytes))
		if err != nil {
			t.Fatal(err)
		}
		total += len(phase)
	}
	coverage, err := encodeRecoveryPhase([32]byte{}, "coverage", make([]byte, maxRecoveryCoverageBytes))
	if err != nil {
		t.Fatal(err)
	}
	total += len(coverage)
	if total > recoveryPhaseWorstCaseBytes || recoveryPhaseWorstCaseBytes > MaxRecoveryPhaseBytes {
		t.Fatalf("serialized phase budget: actual=%d bound=%d limit=%d", total, recoveryPhaseWorstCaseBytes, MaxRecoveryPhaseBytes)
	}
	if _, err := encodeRecoveryPhase([32]byte{}, "resolved", make([]byte, maxRecoveryMetadataPhaseBytes+1)); !errors.Is(err, ErrRecoverySplitRequired) {
		t.Fatalf("metadata consumed another phase's reserve: %v", err)
	}
	footprint := DefaultRecoveryFootprint()
	if err := footprint.ValidateCoordinator(); err != nil {
		t.Fatal(err)
	}
	if footprint.JournalCopy < uint64(2*(MaxRecoveryJournalBytes+total)) || footprint.ManifestPages < uint64(2*MaxRecoveryControlAttempts*recoveryControlAttemptBytes+(64<<10)) {
		t.Fatal("default omits paired repairs or complete control archives")
	}
	t.Logf("maximum serialized bundle=%d, complete phase bound=%d, phase cap=%d", len(raw), recoveryPhaseWorstCaseBytes, MaxRecoveryPhaseBytes)
}
