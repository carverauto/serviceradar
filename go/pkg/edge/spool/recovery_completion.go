// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

var ErrRecoveryCleanupPending = fmt.Errorf("%w: recovery destination awaits terminal evidence", ErrRetryable)

const maxRecoveryCompletionBytes = 64 << 10

type recoveryCleanupTarget struct {
	Identity                        GenerationIdentity
	Base, HighWater, NextGeneration uint64
	Archive                         string
	Descriptor                      recoveryArchiveDescriptor
	TerminalSHA256                  []byte
}

type recoveryCompletionRecord struct {
	Frozen           []byte
	Source           GenerationIdentity
	SourceCheckpoint []byte
	Resolution       recoveryResolutionRecord
	SourceArchive    recoveryArchiveDescriptor
	Targets          []recoveryCleanupTarget
}

// RecoveryCompletion is a paired compact cleanup intent. It survives collection
// of the large frozen/phase journals but grants no authority without a freshly
// validated original signed resolution and exact retained archive commitments.
type RecoveryCompletion struct {
	dir    string
	frozen [32]byte
	record recoveryCompletionRecord
	raw    []byte
}

// RecoveryCompletionGenerations are existing inventory handles; no method here
// constructs a new generation or acquires another recovery reservation.
type RecoveryCompletionGenerations struct {
	Source, Destination *Generation
	Controls            []*Generation
}

// FinishCleanup preserves terminal evidence and completes under the SAME grant.
// A current trusted-key validation is required on every invocation, including a
// restart. Copied data must be fully terminal; superseded controls are archived
// in full before their ambiguous transport slots can be retired.
func (o *RecoveryOperation) FinishCleanup(validated *edgerecord.ValidatedRecoveryResolution, controls []*Generation) error {
	if completion, err := OpenRecoveryCompletion(o.dir); err == nil {
		return completion.Finish(o.grant, RecoveryCompletionGenerations{o.source, o.destination, controls}, validated)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := o.RecordResolution(validated); err != nil {
		return err
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	handles := RecoveryCompletionGenerations{o.source, o.destination, controls}
	completion, err := OpenRecoveryCompletion(o.dir)
	if errors.Is(err, os.ErrNotExist) {
		completion, err = o.prepareCompletion(handles)
	}
	if err != nil {
		return err
	}
	return completion.Finish(o.grant, handles, validated)
}

func (o *RecoveryOperation) prepareCompletion(handles RecoveryCompletionGenerations) (*RecoveryCompletion, error) {
	if len(handles.Controls) > 2 {
		return nil, ErrReserveExhausted
	}
	controls := append([]*Generation(nil), handles.Controls...)
	for _, g := range controls {
		if g == nil {
			return nil, ErrRecoveryPlan
		}
	}
	sort.Slice(controls, func(i, j int) bool { return controls[i].RecoveryAttempt() < controls[j].RecoveryAttempt() })
	o.grant.alloc.mu.Lock()
	expected := make(map[string]bool, len(o.grant.controlAllowances))
	for path := range o.grant.controlAllowances {
		expected[path] = true
	}
	o.grant.alloc.mu.Unlock()
	for _, g := range controls {
		if g == nil || !expected[g.dir] || !bytes.Equal(g.RecoveryID(), o.plan.RecoveryID) || !g.id.Identity.equal(o.source.id.Identity) {
			return nil, ErrRecoveryPlan
		}
		delete(expected, g.dir)
	}
	if len(expected) != 0 {
		return nil, ErrRecoveryCoverage
	}
	resolutionRaw, err := readRecoveryPhase(o.dir, "resolved", o.frozen)
	if err != nil {
		return nil, err
	}
	var resolution recoveryResolutionRecord
	if err = decodeRecoveryJSON(resolutionRaw, &resolution); err != nil {
		return nil, err
	}
	_, sourceCheckpoint, err := o.readDeleteIntent()
	if err != nil {
		return nil, err
	}
	archive, err := o.readArchive()
	if err != nil {
		return nil, err
	}
	record := recoveryCompletionRecord{Frozen: bytes.Clone(o.frozen[:]), Source: o.source.Identity(), SourceCheckpoint: sourceCheckpoint, Resolution: resolution, SourceArchive: archive}
	generations := append([]*Generation{o.destination}, controls...)
	for i, g := range generations {
		if err = g.SealRecoveryDestination(); err != nil {
			return nil, err
		}
		name, artifact, full := destinationArchiveFile, ArtifactMapping, false
		if i > 0 {
			name = fmt.Sprintf("control-%03d.archive", g.RecoveryAttempt())
			artifact = ArtifactManifestPages
			full = true
		}
		target, err := o.archiveCleanupTarget(g, name, artifact, full)
		if err != nil {
			return nil, err
		}
		record.Targets = append(record.Targets, target)
	}
	raw, err := json.Marshal(record)
	if err != nil {
		return nil, err
	}
	if len(raw) > maxRecoveryCompletionBytes {
		return nil, ErrRecoverySplitRequired
	}
	if err = writeCompletionPair(o.dir, "completion", o.frozen, raw, o.grant); err != nil {
		return nil, err
	}
	return OpenRecoveryCompletion(o.dir)
}

func (o *RecoveryOperation) archiveCleanupTarget(g *Generation, name string, artifact Artifact, full bool) (recoveryCleanupTarget, error) {
	var target recoveryCleanupTarget
	var entries []recoveryArchiveEntry
	err := g.withOpen(func(s *Spool) error {
		s.mu.Lock()
		pending := !full && s.resolved != s.nextSeq-1
		s.mu.Unlock()
		if pending {
			return ErrRecoveryCleanupPending
		}
		if err := s.beginRecoveryHold(o.frozen, o.grant, false); err != nil {
			return err
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if !full && s.nextSeq-1 > s.baseSeq {
			proof, _, eligible, err := s.terminalProof()
			if err != nil {
				return err
			}
			if !eligible {
				return ErrRecoveryCleanupPending
			}
			target.TerminalSHA256 = bytes.Clone(proof[:])
		}
		target.Identity = g.Identity()
		target.Base = s.baseSeq
		target.HighWater = s.nextSeq - 1
		target.NextGeneration = s.nextGen
		target.Archive = name
		target.Descriptor.RetainedThrough = s.resolved
		var err error
		entries, err = collectRecoveryArchive(s, o.grant.alloc.budgets[artifact], full)
		return err
	})
	if err != nil {
		return target, err
	}
	header := recoveryArchiveHeader(o.frozen, target.Base, target.HighWater, target.Descriptor.RetainedThrough, len(entries))
	target.Descriptor.Size = uint64(len(header))
	for _, entry := range entries {
		target.Descriptor.Size += uint64(len(archiveEntryHeader(entry))) + entry.size
	}
	hash := sha256.New()
	produce := func(w io.Writer) error { return produceRecoveryArchive(w, header, entries) }
	if err = produce(hash); err != nil {
		return target, err
	}
	target.Descriptor.SHA256 = hash.Sum(nil)
	writer := recoveryArchiveWriter{o.dir, name, artifact, o.frozen, o.grant}
	if err = writer.write(target.Descriptor, produce); err != nil {
		return target, err
	}
	return target, nil
}

func writeCompletionPair(dir, key string, frozen [32]byte, payload []byte, grant *RecoveryGrant) error {
	if len(payload) > maxRecoveryCompletionBytes {
		return ErrRecoverySplitRequired
	}
	raw, err := encodeRecoveryPhase(frozen, key, payload)
	if err != nil {
		return err
	}
	for copy := 0; copy < 2; copy++ {
		path := filepath.Join(dir, fmt.Sprintf("%s-%c", key, 'a'+copy))
		existing := readRecoveryPhaseCopy(path, frozen, key)
		if existing.err == nil {
			if !bytes.Equal(existing.raw, raw) {
				return ErrRecoveryJournalConflict
			}
			continue
		}
		if !errors.Is(existing.err, os.ErrNotExist) {
			return existing.err
		}
		if err = grant.WriteBarrier(ArtifactMapping, path, raw); err != nil {
			return err
		}
	}
	return nil
}

func readCompletionPair(dir, key string, frozen [32]byte) ([]byte, error) {
	a := readRecoveryPhaseCopy(filepath.Join(dir, key+"-a"), frozen, key)
	b := readRecoveryPhaseCopy(filepath.Join(dir, key+"-b"), frozen, key)
	if a.err != nil || b.err != nil {
		return nil, errors.Join(ErrRecoveryJournalIncomplete, a.err, b.err)
	}
	if !bytes.Equal(a.raw, b.raw) {
		return nil, ErrRecoveryJournalConflict
	}
	payload, err := decodeRecoveryPhase(a.raw, frozen, key)
	if len(payload) > maxRecoveryCompletionBytes {
		return nil, ErrRecoveryJournalCorrupt
	}
	return payload, err
}

// OpenRecoveryCompletion reopens compact paired evidence without requiring a
// frozen journal. The signed original must still be revalidated before Finish.
func OpenRecoveryCompletion(dir string) (*RecoveryCompletion, error) {
	_, frozen, err := readStandaloneCompletion(dir, "completion", 0)
	if err != nil {
		return nil, err
	}
	payload, err := readCompletionPair(dir, "completion", frozen)
	if err != nil {
		return nil, err
	}
	var record recoveryCompletionRecord
	if err = decodeRecoveryJSON(payload, &record); err != nil {
		return nil, err
	}
	if !bytes.Equal(record.Frozen, frozen[:]) || len(record.Targets) < 1 || len(record.Targets) > 3 {
		return nil, ErrRecoveryJournalCorrupt
	}
	return &RecoveryCompletion{dir, frozen, record, payload}, nil
}

func readStandaloneCompletion(dir, key string, copyIndex int) ([]byte, [32]byte, error) {
	var frozen [32]byte
	f, err := os.Open(filepath.Join(dir, fmt.Sprintf("%s-%c", key, 'a'+copyIndex)))
	if err != nil {
		return nil, frozen, err
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxRecoveryCompletionBytes+recoveryPhaseOverhead+1))
	closeErr := f.Close()
	if err != nil {
		return nil, frozen, err
	}
	if closeErr != nil {
		return nil, frozen, closeErr
	}
	if len(raw) < recoveryPhaseOverhead || len(raw) > maxRecoveryCompletionBytes+recoveryPhaseOverhead {
		return nil, frozen, ErrRecoveryJournalCorrupt
	}
	copy(frozen[:], raw[8:40])
	_, err = decodeRecoveryPhase(raw, frozen, key)
	return raw, frozen, err
}

// RepairRecoveryCompletion recreates only exact intact paired bytes. It never
// selects between divergent valid copies or treats a read I/O failure as a torn
// write. Restored evidence still requires current receipt validation to finish.
func RepairRecoveryCompletion(dir string, grant *RecoveryGrant) (*RecoveryCompletion, error) {
	for _, key := range []string{"completion", recoveryPhaseCompleted} {
		a, _, aErr := readStandaloneCompletion(dir, key, 0)
		b, _, bErr := readStandaloneCompletion(dir, key, 1)
		if aErr == nil && bErr == nil {
			if !bytes.Equal(a, b) {
				return nil, ErrRecoveryJournalConflict
			}
			continue
		}
		if key == recoveryPhaseCompleted && errors.Is(aErr, os.ErrNotExist) && errors.Is(bErr, os.ErrNotExist) {
			continue
		}
		valid, damaged, damagedErr := a, 1, bErr
		if aErr != nil {
			valid, damaged, damagedErr = b, 0, aErr
		}
		if aErr != nil && bErr != nil {
			return nil, errors.Join(ErrRecoveryJournalIncomplete, aErr, bErr)
		}
		if !errors.Is(damagedErr, os.ErrNotExist) && !errors.Is(damagedErr, ErrRecoveryJournalCorrupt) {
			return nil, damagedErr
		}
		if err := grant.WriteBarrier(ArtifactMapping, filepath.Join(dir, fmt.Sprintf("%s-%c", key, 'a'+damaged)), valid); err != nil {
			return nil, err
		}
	}
	return OpenRecoveryCompletion(dir)
}

// SignedResolution returns detached original bytes for the current trust owner.
func (c *RecoveryCompletion) SignedResolution() (*edgev1.RecoveryResolvedV1, *edgev1.EdgeSignedCapabilityV1, error) {
	resolved := new(edgev1.RecoveryResolvedV1)
	capability := new(edgev1.EdgeSignedCapabilityV1)
	if err := proto.Unmarshal(c.record.Resolution.Resolved, resolved); err != nil {
		return nil, nil, err
	}
	if err := proto.Unmarshal(c.record.Resolution.Capability, capability); err != nil {
		return nil, nil, err
	}
	return resolved, capability, nil
}

// Generations identifies immutable retained handles required to resume cleanup.
func (c *RecoveryCompletion) Generations() (GenerationIdentity, GenerationIdentity, []GenerationIdentity) {
	controls := make([]GenerationIdentity, 0, len(c.record.Targets)-1)
	for _, target := range c.record.Targets[1:] {
		controls = append(controls, target.Identity.clone())
	}
	return c.record.Source.clone(), c.record.Targets[0].Identity.clone(), controls
}

func (c *RecoveryCompletion) validateReceipt(validated *edgerecord.ValidatedRecoveryResolution) error {
	resolved, capability, err := validated.Snapshot()
	if err != nil {
		return err
	}
	stored, claims, err := c.SignedResolution()
	if err != nil {
		return err
	}
	if !proto.Equal(resolved, stored) || !proto.Equal(capability, claims) {
		return edgerecord.ErrRecoveryResolution
	}
	if !bytes.Equal(claims.GetSource().GetNetworkScopeId(), c.record.Source.Identity.NetworkScopeID) || !bytes.Equal(claims.GetSource().GetOriginPrincipalId(), c.record.Source.Identity.AgentID) {
		return edgerecord.ErrRecoveryResolution
	}
	return nil
}

// verifySourceReclaimed checks that the source generation still matches its
// durable reclaim checkpoint and that the source terminal archive is intact.
func (c *RecoveryCompletion) verifySourceReclaimed(source *Generation) error {
	var sourceIntent recoveryDeleteIntent
	if err := decodeRecoveryJSON(c.record.SourceCheckpoint, &sourceIntent); err != nil {
		return err
	}
	sourceProof, err := os.ReadFile(filepath.Join(source.dir, dataName(sourceIntent.HighWater)+checkpointSuffix))
	if err != nil {
		return err
	}
	if !bytes.Equal(sourceProof, recoveryCheckpoint(sourceIntent, c.record.SourceCheckpoint)) {
		return ErrRecoveryCoverage
	}
	if err = source.withOpen(func(s *Spool) error {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.baseSeq != sourceIntent.HighWater || s.nextSeq-1 != sourceIntent.HighWater {
			return ErrRecoveryCoverage
		}
		return s.requireCurrentLayout()
	}); err != nil {
		return err
	}
	return verifyRecoveryArchive(filepath.Join(c.dir, recoveryArchiveFile), c.record.SourceArchive, c.frozen)
}

// Finish revalidates all compact commitments before retrying cleanup. The carrier
// must come from the caller's current retained trust policy, never cached trust
// at the time RecordResolution originally persisted the receipt.
func (c *RecoveryCompletion) Finish(grant *RecoveryGrant, handles RecoveryCompletionGenerations, validated *edgerecord.ValidatedRecoveryResolution) error {
	reopened, err := OpenRecoveryCompletion(c.dir)
	if err != nil {
		return err
	}
	if !bytes.Equal(reopened.raw, c.raw) {
		return ErrRecoveryJournalConflict
	}
	if err := c.validateReceipt(validated); err != nil {
		return err
	}
	controls := append([]*Generation(nil), handles.Controls...)
	for _, g := range controls {
		if g == nil {
			return ErrRecoveryPlan
		}
	}
	sort.Slice(controls, func(i, j int) bool { return controls[i].RecoveryAttempt() < controls[j].RecoveryAttempt() })
	generations := append([]*Generation{handles.Destination}, controls...)
	if handles.Source == nil || !bytes.Equal(encodeIdentity(handles.Source.id), encodeIdentity(c.record.Source)) || len(generations) != len(c.record.Targets) {
		return ErrRecoveryPlan
	}
	if grant == nil || handles.Destination == nil || handles.Destination.dir != grant.lane {
		return ErrOutsideLane
	}
	if err = c.verifySourceReclaimed(handles.Source); err != nil {
		return err
	}
	for i, target := range c.record.Targets {
		g := generations[i]
		if g == nil || g.spool.alloc != grant.alloc || !g.Closed() || !bytes.Equal(encodeIdentity(g.id), encodeIdentity(target.Identity)) {
			return ErrRecoveryPlan
		}
		if target.Archive != destinationArchiveFile && target.Archive != fmt.Sprintf("control-%03d.archive", g.RecoveryAttempt()) {
			return ErrRecoveryPlan
		}
		if err = verifyRecoveryArchive(filepath.Join(c.dir, target.Archive), target.Descriptor, c.frozen); err != nil {
			return err
		}
	}
	completed, err := c.Completed()
	if err != nil {
		return err
	}
	if completed {
		return grant.completeCleanup(c.dir, append([]*Generation{handles.Source}, generations...))
	}
	for i, target := range c.record.Targets {
		if err = c.reclaimTarget(grant, generations[i], target); err != nil {
			return err
		}
	}
	if err = c.collectTransient(grant); err != nil {
		return err
	}
	digest := sha256.Sum256(c.raw)
	if err = writeCompletionPair(c.dir, recoveryPhaseCompleted, c.frozen, digest[:], grant); err != nil {
		return err
	}
	if _, err = readCompletionPair(c.dir, recoveryPhaseCompleted, c.frozen); err != nil {
		return err
	}
	return grant.completeCleanup(c.dir, append([]*Generation{handles.Source}, generations...))
}

// Completed reports paired completion of physical cleanup and transient GC.
// It is inventory state only; Finish still requires current receipt validation.
func (c *RecoveryCompletion) Completed() (bool, error) {
	raw, err := readCompletionPair(c.dir, recoveryPhaseCompleted, c.frozen)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	digest := sha256.Sum256(c.raw)
	if !bytes.Equal(raw, digest[:]) {
		return false, ErrRecoveryJournalConflict
	}
	return true, nil
}

func (c *RecoveryCompletion) reclaimTarget(grant *RecoveryGrant, g *Generation, target recoveryCleanupTarget) error {
	raw, err := json.Marshal(target)
	if err != nil {
		return err
	}
	intent := recoveryDeleteIntent{ReclaimThrough: target.Base, HighWater: target.HighWater, NextGeneration: target.NextGeneration, CoverageSHA256: target.TerminalSHA256, ArchiveSHA256: target.Descriptor.SHA256}
	checkpoint := recoveryCheckpoint(intent, append(bytes.Clone(c.raw), raw...))
	return g.withOpen(func(s *Spool) error {
		err := func() error {
			s.mu.Lock()
			defer s.mu.Unlock()
			if target.HighWater == target.Base {
				return nil
			}
			if s.baseSeq == target.HighWater {
				stored, err := os.ReadFile(filepath.Join(g.dir, dataName(target.HighWater)+checkpointSuffix))
				if err != nil {
					return err
				}
				if !bytes.Equal(stored, checkpoint) {
					return ErrRecoveryCoverage
				}
				return grant.RunDestructive("finish completed recovery target cleanup", s.cleanupReclaimed)
			}
			if s.baseSeq != target.Base || s.nextSeq-1 != target.HighWater {
				return ErrRecoveryCoverage
			}
			hold, err := readRecoveryHold(s.recoveryHoldPath())
			if err != nil {
				return err
			}
			if !bytes.Equal(hold, recoveryHoldRecord(g.id, c.frozen)) {
				return ErrRecoveryHeld
			}
			const metadata = 2*4096 + checkpointSize + 8
			if err := grant.Charge(ArtifactFilesystemMetadata, metadata); err != nil {
				return err
			}
			if err := s.writeResolved(target.HighWater); err != nil {
				return grant.FailStop("checkpoint archived recovery target", err)
			}
			s.resolved = target.HighWater
			if err := grant.WriteBarrier(ArtifactFilesystemMetadata, filepath.Join(g.dir, dataName(target.HighWater)+checkpointSuffix), checkpoint); err != nil {
				return err
			}
			if err := grant.RunDestructive("reclaim completed recovery target", func() error { return s.publishReclaimed(dataName(target.HighWater)) }); err != nil {
				return err
			}
			return grant.Landed(ArtifactFilesystemMetadata, g.dir, metadata)
		}()
		if err != nil {
			return err
		}
		return s.releaseRecoveryHold(c.frozen, grant)
	})
}

func (c *RecoveryCompletion) collectTransient(grant *RecoveryGrant) error {
	entries, err := recoveryPhaseEntries(c.dir)
	if err != nil {
		return err
	}
	var remove []string
	for _, entry := range entries {
		name := entry.Name()
		phase := false
		if strings.HasPrefix(name, "phase-") {
			key := strings.TrimPrefix(strings.TrimSuffix(name, ".tmp"), "phase-")
			if !strings.HasSuffix(key, "-a") && !strings.HasSuffix(key, "-b") {
				return ErrRecoveryJournalCorrupt
			}
			key = key[:len(key)-2]
			if !validRecoveryPhaseKey(key) {
				return ErrRecoveryJournalCorrupt
			}
			phase = true
		}
		if name == recoveryCopyA || name == recoveryCopyB || name == recoveryCopyA+".tmp" || name == recoveryCopyB+".tmp" || phase {
			if entry.IsDir() {
				return ErrRecoveryJournalCorrupt
			}
			remove = append(remove, filepath.Join(c.dir, name))
		}
	}
	return grant.RunDestructive("collect resolved recovery proofs", func() error {
		for _, path := range remove {
			if err := grant.alloc.fs.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		return grant.alloc.fs.SyncDir(c.dir)
	})
}

func (g *RecoveryGrant) completeCleanup(dir string, generations []*Generation) error {
	charges := make(map[string]uint64, len(generations)+1)
	for _, generation := range generations {
		n, err := generation.spool.laneBytes()
		if err != nil {
			return err
		}
		charges[generation.dir] = n
	}
	n, err := regularFileBytes(dir)
	if err != nil {
		return err
	}
	charges[dir] = n
	g.step.Lock()
	defer g.step.Unlock()
	g.alloc.mu.Lock()
	defer g.alloc.mu.Unlock()
	if g.doneLocked() {
		return nil
	}
	if err = g.healthyLocked(); err != nil {
		return err
	}
	for owner, used := range charges {
		g.alloc.ordinary[owner] = used
	}
	g.finished = true
	g.sourceReleased = true
	g.artifactsReleased = true
	g.releaseStageLocked()
	return nil
}
