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
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
)

// openEvidence opens the evidence copies that exist. A missing copy is created, and
// made discoverable, by the next commit. Nothing here rewrites a copy: an incomplete
// trailing entry reads as absent, and the fixed position it occupies is simply
// written again by the commit that owns it.
func (s *Spool) openEvidence() error {
	for c := range evidenceCopies {
		path := s.evidencePath(c)
		f, err := os.OpenFile(path, os.O_RDWR, filePerm)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fmt.Errorf("spool: open evidence copy %c: %w", copyTag(c), err)
		}
		s.evidence[c] = f
		if err := fsyncDir(filepath.Dir(path)); err != nil {
			return err
		}
		s.evidenceDurable[c] = true
	}
	return nil
}

// recover resolves every slot. The work is two sequential passes -- one over the
// segment, one over both evidence copies in lockstep -- so it is bounded by the
// segment's files, not by how many slots turn out to be damaged.
func (s *Spool) recover() error {
	chain, err := s.scanChain()
	if err != nil {
		return err
	}
	readers, evidenceSlots, err := s.evidenceReaders()
	if err != nil {
		return err
	}

	// pendingSlot is a slot that did not resolve COMMITTED. bytesAbsent records whether
	// its record bytes are missing outright rather than present but damaged; only a
	// missing record can lie in the torn tail.
	type pendingSlot struct {
		obs         SlotObservation
		bytesAbsent bool
	}
	var (
		pending      []pendingSlot
		lastEvidence uint64
		maxGen       uint64
		maxComplete  uint64
		tailClaimed  bool
		cursor       int
	)
	buf := make([]byte, evidenceEntryLen)
	top := max(evidenceSlots, chain.maxHeaderSeq)
	s.slots = make([]slotLoc, 0, top)

	for seq := uint64(1); seq <= top; seq++ {
		views, present, gen, err := readSlotEvidence(readers, seq, buf)
		if err != nil {
			return err
		}
		maxGen = max(maxGen, gen)
		if present {
			lastEvidence = seq
		}
		for cursor < len(chain.records) && chain.records[cursor].seq < seq {
			cursor++
		}
		var rec *chainRecord
		if cursor < len(chain.records) && chain.records[cursor].seq == seq {
			rec = &chain.records[cursor]
		}

		obs, loc, hasEvidence, bytesAbsent, err := s.observeSlot(seq, views, rec)
		if err != nil {
			return err
		}
		if hasEvidence && chain.tail != nil && loc.offset == chain.tail.offset {
			tailClaimed = true
		}
		if obs.CompleteRecord {
			maxComplete = max(maxComplete, seq)
		}
		if ResolveSlot(obs).Outcome == OutcomeCommitted {
			loc.committed = true
		} else {
			pending = append(pending, pendingSlot{obs: obs, bytesAbsent: bytesAbsent})
		}
		s.slots = append(s.slots, loc)
	}

	// Every sequence up to the highest one any evidence or record names is allocated:
	// sequences are assigned contiguously, so a gap below it is a slot whose evidence
	// was lost, not a slot that never existed.
	highWater := max(lastEvidence, chain.maxHeaderSeq)
	s.slots = s.slots[:highWater]

	res := Resolution{HighWater: highWater}
	for _, p := range pending {
		obs := p.obs
		if obs.Sequence > highWater {
			break
		}
		obs.Allocated = true
		// The torn tail is the crash boundary: a record that never landed, with no
		// complete record after it. Damaged bytes that are fully present are not a
		// crash boundary and must not excuse a missing binding.
		obs.InTornTail = p.bytesAbsent && obs.Sequence > maxComplete
		res.Slots = append(res.Slots, ResolveSlot(obs))
	}
	if t := chain.tail; t != nil && !tailClaimed && (t.seq == 0 || t.seq > highWater) {
		res.Discarded = append(res.Discarded, ResolveSlot(SlotObservation{Sequence: t.seq}))
	}

	s.restart = res
	s.nextSeq = highWater + 1
	// Monotonic over every surviving entry. A new commit only ever writes positions
	// above the high-water, so it is never compared against a lost generation.
	s.nextGen = maxGen + 1
	return nil
}

// observeSlot gathers what the evidence copies, the segment, and the binding layers
// say about one slot. hasEvidence reports whether loc came from a valid evidence
// entry; bytesAbsent whether no full-length record exists for the slot.
func (s *Spool) observeSlot(
	seq uint64, views [evidenceCopies]copyView, rec *chainRecord,
) (obs SlotObservation, loc slotLoc, hasEvidence, bytesAbsent bool, err error) {
	state, valid := combineViews(views)
	obs = SlotObservation{Sequence: seq, Evidence: state, CompleteRecord: rec != nil && rec.intact}
	ev := SlotEvidence{Sequence: seq}
	bytesAbsent = rec == nil

	switch {
	case len(valid) > 0:
		loc = slotLoc{offset: int64(valid[0].recordOffset), length: valid[0].recordLen}
		ev.EventID, ev.RecordSHA256 = agreedIdentity(valid)
		bytesState, jerr := s.judgeBytes(&valid[0])
		if jerr != nil {
			return obs, loc, false, false, jerr
		}
		obs.Bytes = bytesState
		obs.CompleteRecord = obs.CompleteRecord || bytesState == BytesIntact
		bytesAbsent = bytesAbsent && bytesState == BytesMissing
	case rec != nil:
		loc = slotLoc{offset: rec.offset}
		if rec.intact {
			identity, ierr := s.chainIdentity(*rec)
			if ierr != nil {
				return obs, loc, false, false, ierr
			}
			ev = identity
		}
	}

	var attribution AttributionVerdict
	var receipt ReceiptVerdict
	if s.bindings != nil {
		attribution = s.bindings.InspectAttribution(ev)
		receipt = s.bindings.InspectReceipt(ev)
	}
	obs.Attribution, obs.AttributionRequired = reconcileAttribution(attribution, valid)
	obs.Receipt, obs.ReceiptRequired = reconcileReceipt(receipt, valid)
	return obs, loc, len(valid) > 0, bytesAbsent, nil
}

// agreedIdentity returns the event id and record hash every valid entry agrees on,
// or nil for a member they disagree on.
func agreedIdentity(valid []evidenceEntry) (eventID, recordSHA []byte) {
	eventID = append([]byte(nil), valid[0].eventID[:]...)
	recordSHA = append([]byte(nil), valid[0].recordSHA256[:]...)
	for i := 1; i < len(valid); i++ {
		if valid[i].eventID != valid[0].eventID {
			eventID = nil
		}
		if valid[i].recordSHA256 != valid[0].recordSHA256 {
			recordSHA = nil
		}
	}
	return eventID, recordSHA
}

// reconcileAttribution holds a verifying binding to the commit evidence: it verifies
// for the slot only if every valid evidence entry declares an attribution binding
// with exactly its digest. An intact binding transplanted from another slot, or one
// the commit never named, is not this slot's binding.
func reconcileAttribution(v AttributionVerdict, valid []evidenceEntry) (AttributionVerdict, bool) {
	required := false
	consistent := true
	for i := range valid {
		declared := valid[i].flags&flagAttributionBinding != 0
		required = required || declared
		if !declared || !bytes.Equal(v.Digest, valid[i].attributionSHA256[:]) {
			consistent = false
		}
	}
	if v.State == AttributionVerifies && !consistent {
		return AttributionVerdict{State: AttributionNotVerifying, Digest: v.Digest}, required
	}
	return v, required
}

// reconcileReceipt holds a valid receipt binding to the commit evidence the same way.
func reconcileReceipt(v ReceiptVerdict, valid []evidenceEntry) (ReceiptState, bool) {
	required := false
	consistent := true
	for i := range valid {
		declared := valid[i].flags&flagReceiptBinding != 0
		required = required || declared
		if !declared || !bytes.Equal(v.Digest, valid[i].receiptSHA256[:]) {
			consistent = false
		}
	}
	if v.State == ReceiptValid && !consistent {
		return ReceiptUnverifiable, required
	}
	return v.State, required
}

func (s *Spool) evidenceReaders() ([evidenceCopies]*bufio.Reader, uint64, error) {
	var readers [evidenceCopies]*bufio.Reader
	var entries int64
	for c, f := range s.evidence {
		if f == nil {
			continue
		}
		info, err := f.Stat()
		if err != nil {
			return readers, 0, fmt.Errorf("spool: stat evidence copy %c: %w", copyTag(c), err)
		}
		readers[c] = bufio.NewReaderSize(io.NewSectionReader(f, 0, info.Size()), resyncWindow)
		entries = max(entries, info.Size()/evidenceEntryLen)
	}
	return readers, uint64((entries + 1) / 2), nil
}

// readSlotEvidence reads one slot's PREPARED and COMMITTED entries from each copy.
// present reports whether any copy holds any entry, readable or not, for the slot.
func readSlotEvidence(
	readers [evidenceCopies]*bufio.Reader, seq uint64, buf []byte,
) (views [evidenceCopies]copyView, present bool, maxGen uint64, err error) {
	for c, r := range readers {
		if r == nil {
			continue
		}
		var entries [2]evidenceEntry
		var status [2]entryStatus
		for i, state := range [2]byte{statePrepared, stateCommitted} {
			n, rerr := io.ReadFull(r, buf)
			if rerr != nil && !errors.Is(rerr, io.EOF) && !errors.Is(rerr, io.ErrUnexpectedEOF) {
				return views, false, 0, fmt.Errorf("spool: read evidence copy %c: %w", copyTag(c), rerr)
			}
			entries[i], status[i] = decodeEvidence(buf[:n], c, seq, state)
			if status[i] != entryAbsent {
				present = true
			}
			if status[i] == entryValid {
				maxGen = max(maxGen, entries[i].generation)
			}
		}
		views[c] = viewOf(entries[0], status[0], entries[1], status[1])
	}
	return views, present, maxGen, nil
}

// judgeBytes reads a slot's record at the location its commit evidence names.
func (s *Spool) judgeBytes(e *evidenceEntry) (BytesState, error) {
	if e.recordLen < minRecordLen || e.recordOffset > uint64(s.segSize) ||
		int64(e.recordOffset)+int64(e.recordLen) > s.segSize {
		return BytesMissing, nil
	}
	buf := make([]byte, e.recordLen)
	if _, err := s.seg.ReadAt(buf, int64(e.recordOffset)); err != nil {
		return 0, fmt.Errorf("spool: read record at %d: %w", e.recordOffset, err)
	}
	h, ok := parseHeader(buf[:headerLen+headerCRC])
	if !ok {
		return BytesCorrupt, nil
	}
	if h.seq != e.sequence || h.eventID != e.eventID || uint64(h.bodyLen)+minRecordLen != uint64(e.recordLen) {
		return BytesContradict, nil
	}
	body := buf[headerLen+headerCRC : len(buf)-bodyCRCLen]
	if binary.LittleEndian.Uint32(buf[len(buf)-bodyCRCLen:]) != crc32.Checksum(body, crcTable) {
		return BytesCorrupt, nil
	}
	if sha256.Sum256(body) != e.recordSHA256 {
		return BytesContradict, nil
	}
	return BytesIntact, nil
}

// chainRecord is a fully present record with a valid header found by walking the
// segment; intact reports whether its body checksum also verifies.
type chainRecord struct {
	seq    uint64
	offset int64
	intact bool
}

// chainScan is what a sequential walk of the segment found, independent of evidence.
type chainScan struct {
	records      []chainRecord // in increasing sequence order, intact or not
	maxHeaderSeq uint64        // highest sequence of a fully present, valid-header record
	tail         *tailFragment
}

// tailFragment is where the walk stopped on bytes that are not a whole record.
type tailFragment struct {
	offset int64
	seq    uint64 // 0 when no readable header survives
}

// scanChain walks the segment. It finds records whose commit evidence was lost -- a
// complete record with no marker -- and the sequences their headers allocate.
func (s *Spool) scanChain() (chainScan, error) {
	var cs chainScan
	var lastSeq uint64
	var lastEnd int64
	header := make([]byte, headerLen+headerCRC)

	for pos := int64(0); pos < s.segSize; {
		if pos+int64(len(header)) > s.segSize {
			cs.tail = &tailFragment{offset: pos}
			break
		}
		if _, err := s.seg.ReadAt(header, pos); err != nil {
			return cs, fmt.Errorf("spool: read segment: %w", err)
		}
		h, ok := parseHeader(header)
		if !ok {
			next, found, err := s.resync(pos+1, lastSeq, lastEnd)
			if err != nil {
				return cs, err
			}
			if !found {
				cs.tail = &tailFragment{offset: pos}
				break
			}
			pos = next
			continue
		}
		end := pos + int64(minRecordLen) + int64(h.bodyLen)
		if end > s.segSize {
			cs.tail = &tailFragment{offset: pos, seq: h.seq}
			break
		}
		if h.seq > lastSeq {
			intact, err := s.bodyIntactAt(pos, h.bodyLen)
			if err != nil {
				return cs, err
			}
			cs.records = append(cs.records, chainRecord{seq: h.seq, offset: pos, intact: intact})
			cs.maxHeaderSeq = h.seq
			lastSeq, lastEnd = h.seq, end
		}
		pos = end
	}
	return cs, nil
}

// resync finds the next plausible record header at or after from. A sequence can
// advance by at most one per minimal record since the last header read, so a
// header-shaped run of bytes cannot move the high-water past what the skipped bytes
// could have held.
func (s *Spool) resync(from int64, lastSeq uint64, lastEnd int64) (int64, bool, error) {
	var magic [4]byte
	binary.LittleEndian.PutUint32(magic[:], recordMagic)
	hdr := headerLen + headerCRC
	buf := make([]byte, resyncWindow+hdr)

	for off := from; off+int64(hdr) <= s.segSize; off += resyncWindow {
		n, err := s.seg.ReadAt(buf, off)
		if err != nil && !errors.Is(err, io.EOF) {
			return 0, false, fmt.Errorf("spool: read segment: %w", err)
		}
		window := buf[:n]
		for i := 0; i+hdr <= len(window); {
			j := bytes.Index(window[i:], magic[:])
			if j < 0 || i+j+hdr > len(window) {
				break
			}
			at := i + j
			candidate := off + int64(at)
			h, ok := parseHeader(window[at : at+hdr])
			if ok && h.seq > lastSeq && h.seq-lastSeq <= uint64((candidate-lastEnd)/minRecordLen)+1 {
				return candidate, true, nil
			}
			i = at + 1
		}
	}
	return 0, false, nil
}

func (s *Spool) bodyIntactAt(pos int64, bodyLen uint32) (bool, error) {
	buf := make([]byte, int64(bodyLen)+bodyCRCLen)
	if _, err := s.seg.ReadAt(buf, pos+headerLen+headerCRC); err != nil {
		return false, fmt.Errorf("spool: read record body: %w", err)
	}
	body := buf[:bodyLen]
	return binary.LittleEndian.Uint32(buf[bodyLen:]) == crc32.Checksum(body, crcTable), nil
}

// chainIdentity returns the evidence a markerless record itself carries.
func (s *Spool) chainIdentity(r chainRecord) (SlotEvidence, error) {
	header := make([]byte, headerLen+headerCRC)
	if _, err := s.seg.ReadAt(header, r.offset); err != nil {
		return SlotEvidence{}, fmt.Errorf("spool: read record header: %w", err)
	}
	h, _ := parseHeader(header) // validated by scanChain
	body := make([]byte, h.bodyLen)
	if _, err := s.seg.ReadAt(body, r.offset+headerLen+headerCRC); err != nil {
		return SlotEvidence{}, fmt.Errorf("spool: read record body: %w", err)
	}
	sum := sha256.Sum256(body)
	return SlotEvidence{Sequence: r.seq, EventID: h.eventID[:], RecordSHA256: sum[:]}, nil
}
