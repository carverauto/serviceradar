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
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

type pendingAttribution struct {
	grant            *RecoveryGrant
	validated        *edgerecord.ValidatedAttribution
	source           *CommittedAttribution
	entry            attributionEntry
	raw              []byte
	relocationRaw    []byte
	relocationDigest []byte
}

// CommitAttributed stores the validated record and independently readable
// attribution before issuing a receipt. The exact body is checked before any
// capacity charge, sequence allocation, or storage write.
func (s *Spool) CommitAttributed(a AttributedAppend) (CommitReceipt, error) {
	return s.commit("", a.EventID, a.Body, Bindings{ReceiptSHA256: a.ReceiptSHA256}, &pendingAttribution{validated: &a.Validated})
}

// CommitRelocated carries a reopened source slot through the same commit barrier.
// It does not consult current authority or re-authorize historical work: the
// surviving source binding proves which attribution was accepted originally.
func (s *Spool) CommitRelocated(source CommittedAttribution, grant *RecoveryGrant) (CommitReceipt, error) {
	if !source.valid {
		return CommitReceipt{}, ErrCommittedAttribution
	}
	if grant == nil {
		return CommitReceipt{}, ErrInvalidAllocatorConfig
	}
	return s.commit("", source.record.EventID, source.record.Body, Bindings{}, &pendingAttribution{source: &source, grant: grant})
}

// AppendAttributed checks the sealed record before creating any lane generation.
func (ls *LaneSet) AppendAttributed(key LaneKey, presented Identity, a AttributedAppend) (Receipt, error) {
	return ls.appendWithAttribution(key, presented, a.EventID, a.Body, Bindings{ReceiptSHA256: a.ReceiptSHA256}, &pendingAttribution{validated: &a.Validated})
}

// AppendRelocated commits a verified source under the lane's current generation.
func (ls *LaneSet) AppendRelocated(source CommittedAttribution, grant *RecoveryGrant) (Receipt, error) {
	if !source.valid {
		return Receipt{}, ErrCommittedAttribution
	}
	if grant == nil {
		return Receipt{}, ErrInvalidAllocatorConfig
	}
	return ls.appendWithAttribution(source.generation.Lane, source.generation.Identity, source.record.EventID, source.record.Body, Bindings{}, &pendingAttribution{source: &source, grant: grant})
}

func (s *Spool) prepareAttribution(seq uint64, eventID, body []byte, p *pendingAttribution) error {
	if s.attributionIdentity == nil {
		return ErrAttributionRequired
	}
	if s.evidenceVersion != evidenceVersion2 {
		return ErrRotationRequired
	}
	hash := sha256.Sum256(body)
	c := bindingCoordinates(*s.attributionIdentity, seq, eventID, hash[:])
	var a edgerecord.RecoveryAttribution
	var digest []byte
	var err error
	if p.validated != nil {
		a = p.validated.Attribution()
		digest, err = p.validated.Bind(c, a)
	} else if p.source != nil && p.source.valid {
		source := p.source
		if !source.generation.Identity.equal(s.attributionIdentity.Identity) || source.generation.Lane != s.attributionIdentity.Lane ||
			!bytes.Equal(source.record.EventID, eventID) || !bytes.Equal(source.entry.coordinates.RecordSHA256, hash[:]) {
			return ErrAttributionRequired
		}
		a = source.Attribution()
		digest, err = edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, c, a)
	} else {
		return ErrAttributionRequired
	}
	if err != nil {
		return errors.Join(ErrPermanent, err)
	}
	p.entry = attributionEntry{coordinates: c, attribution: a, digest: digest}
	p.raw, err = encodeAttributionEntry(p.entry)
	if err != nil {
		return err
	}
	if p.source != nil {
		mapping := relocationMapping{source: p.source.generation, destination: *s.attributionIdentity,
			sourceSequence: p.source.record.Sequence, destinationSequence: seq, eventID: eventID, recordHash: hash[:], sourceBinding: p.source.entry.digest, destinationBinding: digest}
		payload := mapping.encode()
		p.relocationDigest = relocationDigest(payload)
		p.relocationRaw, err = encodeSidecar(relocationMagic, 1, seq, payload)
	}
	return err
}

func (s *Spool) attributionCost(p *pendingAttribution) (uint64, error) {
	if p == nil {
		return 0, nil
	}
	total, err := s.sidecarGrowth(attributionFile, s.nextSeq)
	if err != nil {
		return 0, err
	}
	if p.relocationRaw != nil {
		n, err := s.sidecarGrowth(relocationFile, s.nextSeq)
		if err != nil {
			return 0, err
		}
		total += n
	}
	return total, nil
}

func (s *Spool) persistAttribution(seq uint64, p *pendingAttribution) error {
	if p == nil {
		return nil
	}
	if err := s.writeSidecar(attributionFile, seq, p.raw, barrierAttribution, barrierAttributionDir); err != nil {
		return err
	}
	if p.relocationRaw != nil {
		return s.writeSidecar(relocationFile, seq, p.relocationRaw, barrierRelocation, barrierRelocationDir)
	}
	return nil
}

type relocationMapping struct {
	source, destination                                    GenerationIdentity
	sourceSequence, destinationSequence                    uint64
	eventID, recordHash, sourceBinding, destinationBinding []byte
}

func (m relocationMapping) encode() []byte {
	var b []byte
	for _, id := range []GenerationIdentity{m.source, m.destination} {
		raw := encodeIdentity(id)
		b = binary.BigEndian.AppendUint16(b, uint16(len(raw)))
		b = append(b, raw...)
	}
	b = binary.BigEndian.AppendUint64(b, m.sourceSequence)
	b = binary.BigEndian.AppendUint64(b, m.destinationSequence)
	for _, v := range [][]byte{m.eventID, m.recordHash, m.sourceBinding, m.destinationBinding} {
		b = append(b, v...)
	}
	return b
}

func decodeRelocation(b []byte) (relocationMapping, error) {
	var m relocationMapping
	for _, id := range []*GenerationIdentity{&m.source, &m.destination} {
		if len(b) < 2 {
			return m, ErrCommittedAttribution
		}
		n := int(binary.BigEndian.Uint16(b))
		b = b[2:]
		if n > len(b) {
			return m, ErrCommittedAttribution
		}
		value, err := decodeIdentity(b[:n])
		if err != nil {
			return m, err
		}
		*id = value
		b = b[n:]
	}
	if len(b) != 16+16+32+32+32 {
		return m, ErrCommittedAttribution
	}
	m.sourceSequence = binary.BigEndian.Uint64(b)
	m.destinationSequence = binary.BigEndian.Uint64(b[8:])
	b = b[16:]
	m.eventID = bytes.Clone(b[:16])
	m.recordHash = bytes.Clone(b[16:48])
	m.sourceBinding = bytes.Clone(b[48:80])
	m.destinationBinding = bytes.Clone(b[80:112])
	if m.sourceSequence == 0 || m.destinationSequence == 0 {
		return m, ErrCommittedAttribution
	}
	return m, nil
}

func relocationDigest(payload []byte) []byte {
	h := sha256.New()
	h.Write([]byte("serviceradar.edge.spool.relocation.v1"))
	h.Write(payload)
	return h.Sum(nil)
}

func (s *Spool) inspectRelocation(entry attributionEntry, valid []evidenceEntry) (*relocationMapping, []byte, bool, error) {
	payload, state, err := s.readSidecar(relocationFile, relocationMagic, entry.coordinates.Sequence)
	if err != nil {
		return nil, nil, false, err
	}
	required := false
	for _, e := range valid {
		required = required || e.flags&flagRelocationBinding != 0
	}
	if !required {
		return nil, nil, state != AttributionAbsent, nil
	}
	if state != AttributionVerifies {
		return nil, nil, true, nil
	}
	digest := relocationDigest(payload)
	for _, e := range valid {
		if e.flags&flagRelocationBinding == 0 || !bytes.Equal(e.relocationSHA256[:], digest) {
			return nil, nil, true, nil
		}
	}
	m, err := decodeRelocation(payload)
	if err != nil {
		return nil, nil, true, nil
	}
	if !bytes.Equal(encodeIdentity(m.destination), encodeIdentity(*s.attributionIdentity)) ||
		!m.source.Identity.equal(m.destination.Identity) || m.source.Lane != m.destination.Lane ||
		m.destinationSequence != entry.coordinates.Sequence || !bytes.Equal(m.eventID, entry.coordinates.EventID) ||
		!bytes.Equal(m.recordHash, entry.coordinates.RecordSHA256) || !bytes.Equal(m.destinationBinding, entry.digest) {
		return nil, nil, true, nil
	}
	sourceDigest, err := edgerecord.LocalBindingDigest(1, bindingCoordinates(m.source, m.sourceSequence, m.eventID, m.recordHash), entry.attribution)
	if err != nil || !bytes.Equal(sourceDigest, m.sourceBinding) {
		return nil, nil, true, nil
	}
	return &m, digest, false, nil
}

// CommittedAttribution can only be created by reopening a sender-visible slot.
// Its detached record, sidecar and mapping are immutable to callers. It is evidence
// of this observation, not permission to delete anything: coverage must reopen it
// again at its destructive boundary.
type CommittedAttribution struct {
	valid         bool
	generation    GenerationIdentity
	record        Record
	entry         attributionEntry
	mapping       *relocationMapping
	mappingDigest []byte
	highWater     uint64
}

func (c CommittedAttribution) Coordinates() edgerecord.LocalBindingCoordinates {
	return bindingCoordinates(c.generation.clone(), c.record.Sequence, bytes.Clone(c.record.EventID), bytes.Clone(c.entry.coordinates.RecordSHA256))
}
func (c CommittedAttribution) Attribution() edgerecord.RecoveryAttribution {
	span := proto.Clone(attributionSpan(c.record.Sequence, c.entry.attribution)).(*edgev1.EdgeClassificationSpanV1)
	a, _ := spanAttribution(span)
	return a
}
func (c CommittedAttribution) BindingDigest() []byte { return bytes.Clone(c.entry.digest) }
func (c CommittedAttribution) MappingDigest() []byte { return bytes.Clone(c.mappingDigest) }
func (c CommittedAttribution) HighWater() uint64     { return c.highWater }
func (c CommittedAttribution) SourceCoordinates() (edgerecord.LocalBindingCoordinates, bool) {
	if c.mapping == nil {
		return edgerecord.LocalBindingCoordinates{}, false
	}
	m := c.mapping
	return bindingCoordinates(m.source.clone(), m.sourceSequence, bytes.Clone(m.eventID), bytes.Clone(m.recordHash)), true
}

func (g *Generation) CommittedAttribution(seq uint64) (CommittedAttribution, error) {
	return g.spool.CommittedAttribution(seq)
}

// CommittedAttribution does bounded positional reads rather than recovering the
// whole segment for each relocated slot. Observed commit copies are synced before
// sealing, so a concurrent writer's buffered marker cannot stand in for durability.
func (s *Spool) CommittedAttribution(seq uint64) (CommittedAttribution, error) {
	observed, err := s.observeAttribution(seq)
	if err != nil {
		return CommittedAttribution{}, err
	}
	if observed.resolved >= seq || ResolveSlot(observed.observation).Outcome != OutcomeCommitted || observed.entry.digest == nil {
		return CommittedAttribution{}, ErrCommittedAttribution
	}
	return CommittedAttribution{valid: true, generation: observed.generation, record: observed.record, entry: observed.entry, mapping: observed.mapping, mappingDigest: observed.mappingDigest, highWater: observed.highWater}, nil
}

// RecoveryClassification returns the complete singleton loss classification from
// current disk evidence. A damaged binding produces the existing unattributable
// reason; intact attribution remains readable when the record is corrupt.
func (g *Generation) RecoveryClassification(seq uint64) (*edgev1.EdgeClassificationSpanV1, error) {
	return g.spool.RecoveryClassification(seq)
}
func (s *Spool) RecoveryClassification(seq uint64) (*edgev1.EdgeClassificationSpanV1, error) {
	observed, err := s.observeAttribution(seq)
	if err != nil {
		return nil, err
	}
	resolution := ResolveSlot(observed.observation)
	if observed.resolved >= seq || !resolution.EntersCoverage() {
		return nil, ErrCommittedAttribution
	}
	if resolution.Coverage.Attributed {
		return attributionSpan(seq, observed.entry.attribution), nil
	}
	return &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq, Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{Unattributable: &edgev1.EdgeUnattributableV1{Reason: resolution.Coverage.Reason}}}, nil
}

type attributionObservation struct {
	generation          GenerationIdentity
	observation         SlotObservation
	record              Record
	entry               attributionEntry
	mapping             *relocationMapping
	mappingDigest       []byte
	highWater, resolved uint64
}

func (s *Spool) observeAttribution(seq uint64) (attributionObservation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out attributionObservation
	if s.attributionIdentity == nil {
		return out, ErrAttributionRequired
	}
	fresh := &Spool{dir: s.dir, dataDir: s.dir, attributionIdentity: s.attributionIdentity, bindings: s.bindings, evidenceVersion: evidenceVersion}
	raw, err := os.ReadFile(filepath.Join(s.dir, identityFile))
	if err != nil {
		return out, err
	}
	id, err := decodeIdentity(raw)
	if err != nil || !bytes.Equal(encodeIdentity(id), encodeIdentity(*s.attributionIdentity)) {
		return out, ErrCorruptGeneration
	}
	format, err := os.ReadFile(filepath.Join(s.dir, evidenceFormatFile))
	if err == nil {
		if string(format) != evidenceFormatV2 {
			return out, ErrCorruptGeneration
		}
		fresh.evidenceVersion = evidenceVersion2
	} else if !errors.Is(err, os.ErrNotExist) {
		return out, err
	}
	if err = fresh.loadLayout(); err != nil {
		return out, err
	}
	if seq <= fresh.baseSeq {
		return out, ErrCommittedAttribution
	}
	f, err := os.Open(fresh.segmentPath())
	if err != nil {
		return out, err
	}
	fresh.seg = f
	defer fresh.closeFiles()
	readers, high, err := fresh.evidenceReaders(seq)
	if err != nil {
		return out, err
	}
	sidecarHigh, err := fresh.sidecarHighWater()
	if err != nil {
		return out, err
	}
	high = max(high, sidecarHigh, s.nextSeq-1)
	info, err := f.Stat()
	if err != nil {
		return out, err
	}
	fresh.segSize = info.Size()
	resolved, err := fresh.readResolved()
	if err != nil {
		return out, err
	}
	if seq > high {
		return out, ErrCommittedAttribution
	}
	views, _, _, err := readSlotEvidence(readers, seq, make([]byte, fresh.evidenceEntrySize()), fresh.evidenceVersion)
	if err != nil {
		return out, err
	}
	obs, loc, _, err := fresh.observeSlot(seq, views, nil)
	if err != nil {
		return out, err
	}
	obs.Allocated = true
	_, valid := combineViews(views)
	if obs.Bytes == BytesMissing && len(valid) > 0 && loc.offset+int64(loc.length) > fresh.segSize {
		committed := false
		for _, v := range views {
			committed = committed || v.kind == viewCommitted
		}
		obs.InTornTail = !committed
	}
	if prior, ok := s.restart.Slot(seq); ok && prior.Coverage.Reason == edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL && obs.Attribution.State == AttributionAbsent && obs.Evidence != EvidenceCommitted {
		obs.InTornTail = true
	}
	var entry attributionEntry
	var mapping *relocationMapping
	var digest []byte
	if len(valid) > 0 {
		event, hash := agreedIdentity(valid)
		entry, _, err = fresh.inspectAttribution(SlotEvidence{Sequence: seq, EventID: event, RecordSHA256: hash})
		if err != nil {
			return out, err
		}
		if obs.Attribution.State == AttributionVerifies {
			mapping, digest, _, err = fresh.inspectRelocation(entry, valid)
			if err != nil {
				return out, err
			}
		}
	}
	var record Record
	if ResolveSlot(obs).Outcome == OutcomeCommitted {
		record, err = readRecordAt(fresh.seg, loc)
		if err != nil {
			return out, err
		}
	}
	for _, copy := range fresh.evidence {
		if copy != nil {
			if err = copy.Sync(); err != nil {
				return out, err
			}
		}
	}
	if err = fsyncDir(fresh.dataDir); err != nil {
		return out, err
	}
	if err = fresh.requireCurrentLayout(); err != nil {
		return out, err
	}
	return attributionObservation{generation: id, observation: obs, record: record, entry: entry, mapping: mapping, mappingDigest: digest, highWater: high, resolved: resolved}, nil
}

// recoveryAppendCosts charges every overwrite and every newly occupied byte,
// including sparse holes left by interrupted allocations. All files remain owned
// by the destination generation after the recovery artifacts are released.
func (s *Spool) recoveryAppendCosts(bodyLen int, p *pendingAttribution) ([]recoveryAppendCost, error) {
	costs := []recoveryAppendCost{{Artifact: ArtifactDestinationSegment, Path: s.segmentPath(), Written: uint64(minRecordLen + bodyLen), Growth: uint64(minRecordLen + bodyLen)}}
	end := s.evidencePosition(s.nextSeq, stateCommitted) + s.evidenceEntrySize()
	for c := range evidenceCopies {
		path := s.evidencePath(c)
		size, err := fileSizeOrAbsent(path)
		if err != nil {
			return nil, err
		}
		growth := uint64(max(end-size, 0))
		written := max(uint64(2*s.evidenceEntrySize()), growth)
		costs = append(costs, recoveryAppendCost{Artifact: ArtifactDestinationSegment, Path: path, Written: written, Growth: growth})
	}
	names := []string{attributionFile}
	if p.relocationRaw != nil {
		names = append(names, relocationFile)
	}
	for _, name := range names {
		growth, err := s.sidecarGrowth(name, s.nextSeq)
		if err != nil {
			return nil, err
		}
		costs = append(costs, recoveryAppendCost{Artifact: ArtifactAttributionSidecar, Path: filepath.Join(s.dataDir, name), Written: max(sidecarSlotSize, growth), Growth: growth})
	}
	return costs, nil
}
func fileSizeOrAbsent(path string) (int64, error) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}
