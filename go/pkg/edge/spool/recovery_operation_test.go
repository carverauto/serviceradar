// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"errors"
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
	destination, err := lanes.CreateRecoveryDestination(key, id, 0)
	if err != nil {
		t.Fatal(err)
	}
	controlKey := LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	control, err := lanes.CreateRecoveryDestination(controlKey, id, 0)
	if err != nil {
		t.Fatal(err)
	}
	grant, err := a.AcquireRecovery(destination.dir)
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
		ack.Dispositions = append(ack.Dispositions, &edgev1.EdgeRecordDisposition{Sequence: seq, EventId: r.EventID, Kind: kind})
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
	if err := f.operation.FreezePublications(records); err != nil {
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
		if strings.HasPrefix(name, "phase-coverage-") {
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
			// Generation identity/marker are already ordinary metadata. Appended files
			// and interrupted temporaries belong to the resumed grant.
			name := strings.TrimSuffix(e.Name(), ".tmp")
			if name == identityFile || name == closedFile || name == recoveryDestinationFile || name == evidenceFormatFile {
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
}

func TestRecoveryControlRestartReplaysFrozenPublicationAfterTornAppend(t *testing.T) {
	f := newRecoveryFixture(t, 1)
	expected := recoveryControlInputs(t, f)
	if err := f.operation.FreezePublications(expected); err != nil {
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
	replacement, err := f.lanes.CreateRecoveryDestination(f.control.id.Lane, f.plan.RecoveryID, 1)
	if err != nil {
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
