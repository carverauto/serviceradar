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
	"math"
	"os"
	"path/filepath"
)

// openEvidence opens the evidence copies that exist and are not open yet. A missing
// copy is created, and made discoverable, by the next commit. Nothing here rewrites a
// copy: an incomplete trailing entry reads as absent, and the fixed position it
// occupies is simply written again by the commit that owns it.
func (s *Spool) openEvidence() error {
	for c := range evidenceCopies {
		if s.evidence[c] != nil {
			continue
		}
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
	readers, evidenceSlots, err := s.evidenceReaders(1)
	if err != nil {
		return err
	}
	chain, err := s.scanChain(evidenceSlots)
	if err != nil {
		return err
	}

	var (
		pending      []SlotObservation // slots that did not resolve COMMITTED
		lastEvidence uint64
		maxGen       uint64
		minEnd       int64
		tailClaimed  bool
		cursor       int
	)
	buf := make([]byte, evidenceEntryLen)
	top := max(evidenceSlots, chain.maxHeaderSeq)
	s.slots = make([]slotLoc, 0, top)
	extents := make([]slotExtent, 0, top)

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

		obs, loc, hasEvidence, err := s.observeSlot(seq, views, rec)
		if err != nil {
			return err
		}
		if hasEvidence && chain.tail != nil && loc.offset == chain.tail.offset {
			tailClaimed = true
		}
		// A slot nothing places still occupies at least a minimal record after the
		// slot before it.
		ext := slotExtent{start: math.MaxInt64, end: minEnd + minRecordLen}
		if hasEvidence || rec != nil {
			ext = slotExtent{start: loc.offset, end: loc.offset + int64(loc.length)}
		}
		for _, v := range views {
			ext.committed = ext.committed || v.kind == viewCommitted
		}
		minEnd = ext.end
		extents = append(extents, ext)
		if ResolveSlot(obs).Outcome == OutcomeCommitted {
			loc.committed = true
		} else {
			pending = append(pending, obs)
		}
		s.slots = append(s.slots, loc)
	}

	// Every sequence up to the highest one any evidence or record names is allocated:
	// sequences are assigned contiguously, so a gap below it is a slot whose evidence
	// was lost, not a slot that never existed.
	highWater := max(lastEvidence, chain.maxHeaderSeq)
	s.slots = s.slots[:highWater]

	// The torn tail is the crash boundary: a slot whose own record never fully landed.
	// Every slot is placed at the segment end, and a record that landed was durable
	// before anything was placed after it, so a record never landed when its extent
	// runs past the segment end or past where any later slot was placed. Commits made
	// after a restart are placed at or above the segment end they found, so they
	// cannot change the answer for a slot that already exists. The bytes such an
	// extent now covers are not the slot's, so they are missing, not corrupt. A copy is
	// marked committed only once the record is durable, so a slot any valid copy shows
	// committed did land and lost its bytes afterwards: that is not a torn tail.
	limit := s.segSize
	above := highWater
	for i := len(pending) - 1; i >= 0; i-- {
		obs := &pending[i]
		if obs.Sequence > highWater {
			continue
		}
		for ; above > obs.Sequence; above-- {
			limit = min(limit, extents[above-1].start)
		}
		if ext := extents[obs.Sequence-1]; ext.end > limit {
			obs.InTornTail = !ext.committed
			obs.Bytes = BytesMissing
		}
	}

	res := Resolution{HighWater: highWater}
	for _, obs := range pending {
		if obs.Sequence > highWater {
			break
		}
		obs.Allocated = true
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

// slotExtent is where a slot's record was placed and where its declared length ends.
// start is math.MaxInt64 when neither evidence nor a record header places the slot;
// committed is set when a valid evidence copy records the commit.
type slotExtent struct {
	start     int64
	end       int64
	committed bool
}

// refreshLocked adopts slots that another handle on the same directory allocated
// above this handle's high-water. A writer prepares a sequence only after the one
// before it committed or a restart resolved it, so every slot below the highest one
// any copy held entries for when the scan began is settled, and is adopted as it
// resolves -- committed or not, and never reused. The highest slot may still be in
// flight in its writer: unless it is already COMMITTED, a later scan looks at it again.
//
// The evidence sizes that fix that bound are captured before anything else, and the
// segment size after them, so every write a settled slot made -- its record and each
// copy's entries -- landed before any size this scan judges it by.
func (s *Spool) refreshLocked() error {
	if err := s.openEvidence(); err != nil {
		return err
	}
	readers, slots, err := s.evidenceReaders(s.nextSeq)
	if err != nil {
		return err
	}
	info, err := s.seg.Stat()
	if err != nil {
		return fmt.Errorf("spool: stat segment: %w", err)
	}
	s.segSize = max(s.segSize, info.Size())
	s.crossStat(segmentFile)
	buf := make([]byte, evidenceEntryLen)
	for seq := s.nextSeq; seq <= slots; seq++ {
		views, _, gen, err := readSlotEvidence(readers, seq, buf)
		if err != nil {
			return err
		}
		obs, loc, _, err := s.observeSlot(seq, views, nil)
		if err != nil {
			return err
		}
		committed := ResolveSlot(obs).Outcome == OutcomeCommitted
		if !committed && seq == slots {
			break
		}
		loc.committed = committed
		s.slots = append(s.slots, loc)
		s.nextSeq = seq + 1
		s.nextGen = max(s.nextGen, gen+1)
	}
	return nil
}

// observeSlot gathers what the evidence copies, the segment, and the binding layers
// say about one slot. hasEvidence reports whether loc came from a valid evidence
// entry.
func (s *Spool) observeSlot(
	seq uint64, views [evidenceCopies]copyView, rec *chainRecord,
) (obs SlotObservation, loc slotLoc, hasEvidence bool, err error) {
	state, valid := combineViews(views)
	obs = SlotObservation{Sequence: seq, Evidence: state, CompleteRecord: rec != nil && rec.intact}
	ev := SlotEvidence{Sequence: seq}

	switch {
	case len(valid) > 0:
		loc = slotLoc{offset: int64(valid[0].recordOffset), length: valid[0].recordLen}
		ev.EventID, ev.RecordSHA256 = agreedIdentity(valid)
		bytesState, jerr := s.judgeBytes(&valid[0])
		if jerr != nil {
			return obs, loc, false, jerr
		}
		obs.Bytes = bytesState
		obs.CompleteRecord = obs.CompleteRecord || bytesState == BytesIntact
	case rec != nil:
		loc = slotLoc{offset: rec.offset, length: uint32(rec.end - rec.offset)}
		if rec.intact {
			identity, ierr := s.chainIdentity(*rec)
			if ierr != nil {
				return obs, loc, false, ierr
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
	return obs, loc, len(valid) > 0, nil
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

// evidenceReaders positions a reader on each open copy at sequence from's entries, and
// returns how many slots the longest copy holds entries for. Every copy's size is
// captured before any reader is made, and each reader reads up to the largest of them,
// so an entry any copy wrote before the last capture is visible in every copy.
func (s *Spool) evidenceReaders(from uint64) ([evidenceCopies]*bufio.Reader, uint64, error) {
	var readers [evidenceCopies]*bufio.Reader
	var size int64
	for c, f := range s.evidence {
		if f == nil {
			continue
		}
		info, err := f.Stat()
		if err != nil {
			return readers, 0, fmt.Errorf("spool: stat evidence copy %c: %w", copyTag(c), err)
		}
		size = max(size, info.Size())
		s.crossStat(evidenceDirName(c))
	}
	start := evidencePosition(from, statePrepared)
	for c, f := range s.evidence {
		if f != nil {
			section := io.NewSectionReader(f, start, max(size-start, 0))
			readers[c] = bufio.NewReaderSize(section, resyncWindow)
		}
	}
	return readers, uint64((size/evidenceEntryLen + 1) / 2), nil
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

// chainRecord is a record with a valid header found by walking the segment. end is
// where its header says it ends, which may lie past the segment end; intact reports
// whether it is fully present and its body checksum verifies.
type chainRecord struct {
	seq    uint64
	offset int64
	end    int64
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
//
// A header in the clean prefix -- reached from the start of the segment by stepping
// over intact records -- was placed there by the spool, so its sequence counts however
// far it jumps: an append that fails after its preparation consumes a sequence while
// writing no bytes. Past the first damage a header can lie in producer-written body
// bytes, so the walk trusts it only when its sequence advances by at most one per byte
// skipped since the last trusted position -- the least a torn record leaves -- or when
// its record is intact and its sequence is within what the files account for: the
// higher of evidenceSlots and the clean prefix's high-water, plus one for each record
// and torn fragment the walk has found, itself included. A header beyond that is not
// trusted, so it neither raises the high-water nor hides the records after it, and
// open materializes the slots the files hold rather than a sequence a header names.
//
// KNOWN ACCEPTED RISK: a genuine record found past damage whose sequence lies beyond
// that bound is not counted, so its sequence can be reused.
func (s *Spool) scanChain(evidenceSlots uint64) (chainScan, error) {
	var (
		cs        chainScan
		lastSeq   uint64
		lastEnd   int64
		cleanHigh uint64
		fragments uint64
		clean     = true
	)
	hdr := int64(headerLen + headerCRC)
	header := make([]byte, hdr)
	trusts := func(h recordHeader, at int64) (bool, error) {
		switch {
		case h.seq <= lastSeq:
			return false, nil
		case clean || h.seq-lastSeq <= uint64(at-lastEnd)+1:
			return true, nil
		case h.seq > max(evidenceSlots, cleanHigh)+uint64(len(cs.records))+fragments+1,
			at+minRecordLen+int64(h.bodyLen) > s.segSize:
			return false, nil
		default:
			return s.bodyIntactAt(at, h.bodyLen)
		}
	}

	for pos := int64(0); pos < s.segSize; {
		if pos+hdr > s.segSize {
			cs.tail = &tailFragment{offset: pos}
			break
		}
		if _, err := s.seg.ReadAt(header, pos); err != nil {
			return cs, fmt.Errorf("spool: read segment: %w", err)
		}
		h, ok := parseHeader(header)
		if ok && h.seq > lastSeq {
			var err error
			if ok, err = trusts(h, pos); err != nil {
				return cs, err
			}
		}
		if !ok {
			clean = false
			fragments++
			next, found, err := s.resync(pos+1, trusts)
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
		whole := end <= s.segSize
		intact := false
		if whole {
			var err error
			if intact, err = s.bodyIntactAt(pos, h.bodyLen); err != nil {
				return cs, err
			}
		}
		if h.seq > lastSeq {
			cs.records = append(cs.records, chainRecord{seq: h.seq, offset: pos, end: end, intact: intact})
			if whole {
				cs.maxHeaderSeq = h.seq
			}
			if clean {
				cleanHigh = h.seq
			}
			lastSeq, lastEnd = h.seq, pos+hdr
			if intact {
				lastEnd = end
			}
		}
		if intact {
			pos = end
			continue
		}
		// Only an intact record proves its length. A record that never fully landed
		// declares an extent later records were placed inside, so the walk continues
		// at the next readable header rather than at the declared end.
		clean = false
		next, found, err := s.resync(pos+hdr, trusts)
		if err != nil {
			return cs, err
		}
		if !found && !whole {
			cs.tail = &tailFragment{offset: pos, seq: h.seq}
			break
		}
		pos = end
		if found {
			pos = next
		}
	}
	return cs, nil
}

// resync finds the first record header at or after from that trusts accepts.
func (s *Spool) resync(from int64, trusts func(recordHeader, int64) (bool, error)) (int64, bool, error) {
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
			if h, ok := parseHeader(window[at : at+hdr]); ok {
				trusted, err := trusts(h, candidate)
				if err != nil {
					return 0, false, err
				}
				if trusted {
					return candidate, true, nil
				}
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
