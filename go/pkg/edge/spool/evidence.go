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
)

// Commit evidence is stored in two copies, each in its own file and directory,
// independent of the record segment. Every slot owns two FIXED positions in each
// copy -- a PREPARED entry and a COMMITTED entry -- so an unreadable entry still
// names its slot and transition, and no position has to be inferred from its
// neighbours.
//
// Entry layout, little-endian, evidenceEntryLen bytes:
//
//	magic(4) version(1) copy(1) state(1) flags(1) sequence(8) generation(8)
//	record_offset(8) record_len(4) event_id(16) record_sha256(32)
//	receipt_binding_sha256(32) attribution_binding_sha256(32)
//	digest(32) = SHA-256(evidenceDomain || all preceding bytes)
//
// An all-zero entry is ABSENT: it is either a hole below a later write or a
// zero-filled torn write, and in both cases the transition never landed on that copy.
const (
	evidenceFile     = "lane.seg.evidence"
	evidenceMagic    = 0x53524556 // "SREV"
	evidenceVersion  = 1
	evidenceBodyLen  = 148
	evidenceEntryLen = evidenceBodyLen + sha256.Size
	evidenceDomain   = "serviceradar.edge.spool.commit_evidence.v1"

	statePrepared  byte = 1
	stateCommitted byte = 2

	flagReceiptBinding     byte = 1 << 0
	flagAttributionBinding byte = 1 << 1

	copyA          = 0
	copyB          = 1
	evidenceCopies = 2
)

func evidenceDirName(c int) string { return "evidence-" + string(rune('a'+c)) }

func copyTag(c int) byte { return 'A' + byte(c) }

// evidencePosition is the fixed byte offset of a slot's entry for one transition.
func evidencePosition(seq uint64, state byte) int64 {
	return int64(2*(seq-1)+uint64(state-1)) * evidenceEntryLen
}

type evidenceEntry struct {
	copyTag           byte
	state             byte
	flags             byte
	sequence          uint64
	generation        uint64
	recordOffset      uint64
	recordLen         uint32
	eventID           [16]byte
	recordSHA256      [32]byte
	receiptSHA256     [32]byte
	attributionSHA256 [32]byte
}

func (e *evidenceEntry) encode() []byte {
	buf := make([]byte, evidenceEntryLen)
	binary.LittleEndian.PutUint32(buf[0:], evidenceMagic)
	buf[4] = evidenceVersion
	buf[5] = e.copyTag
	buf[6] = e.state
	buf[7] = e.flags
	binary.LittleEndian.PutUint64(buf[8:], e.sequence)
	binary.LittleEndian.PutUint64(buf[16:], e.generation)
	binary.LittleEndian.PutUint64(buf[24:], e.recordOffset)
	binary.LittleEndian.PutUint32(buf[32:], e.recordLen)
	copy(buf[36:52], e.eventID[:])
	copy(buf[52:84], e.recordSHA256[:])
	copy(buf[84:116], e.receiptSHA256[:])
	copy(buf[116:148], e.attributionSHA256[:])
	digest := evidenceDigest(buf[:evidenceBodyLen])
	copy(buf[evidenceBodyLen:], digest[:])
	return buf
}

func evidenceDigest(body []byte) [sha256.Size]byte {
	h := sha256.New()
	h.Write([]byte(evidenceDomain))
	h.Write(body)
	var out [sha256.Size]byte
	h.Sum(out[:0])
	return out
}

type entryStatus uint8

const (
	entryAbsent entryStatus = iota
	entryCorrupt
	entryValid
)

// decodeEvidence decodes the entry read from copy c at the position of (seq, state).
// An entry whose own digest verifies but that names a different copy, slot, or
// transition was written somewhere else and is treated as corrupt, not trusted.
func decodeEvidence(buf []byte, c int, seq uint64, state byte) (evidenceEntry, entryStatus) {
	if len(buf) < evidenceEntryLen || allZero(buf) {
		return evidenceEntry{}, entryAbsent
	}
	if binary.LittleEndian.Uint32(buf[0:]) != evidenceMagic || buf[4] != evidenceVersion {
		return evidenceEntry{}, entryCorrupt
	}
	digest := evidenceDigest(buf[:evidenceBodyLen])
	if !bytes.Equal(digest[:], buf[evidenceBodyLen:evidenceEntryLen]) {
		return evidenceEntry{}, entryCorrupt
	}
	e := evidenceEntry{
		copyTag:      buf[5],
		state:        buf[6],
		flags:        buf[7],
		sequence:     binary.LittleEndian.Uint64(buf[8:]),
		generation:   binary.LittleEndian.Uint64(buf[16:]),
		recordOffset: binary.LittleEndian.Uint64(buf[24:]),
		recordLen:    binary.LittleEndian.Uint32(buf[32:]),
	}
	copy(e.eventID[:], buf[36:52])
	copy(e.recordSHA256[:], buf[52:84])
	copy(e.receiptSHA256[:], buf[84:116])
	copy(e.attributionSHA256[:], buf[116:148])
	if e.copyTag != copyTag(c) || e.sequence != seq || e.state != state {
		return evidenceEntry{}, entryCorrupt
	}
	return e, entryValid
}

func allZero(b []byte) bool {
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}

// samePayload compares what a slot's commit binds: everything except the copy tag,
// the transition, and the generation.
func samePayload(a, b *evidenceEntry) bool {
	return a.flags == b.flags &&
		a.sequence == b.sequence &&
		a.recordOffset == b.recordOffset &&
		a.recordLen == b.recordLen &&
		a.eventID == b.eventID &&
		a.recordSHA256 == b.recordSHA256 &&
		a.receiptSHA256 == b.receiptSHA256 &&
		a.attributionSHA256 == b.attributionSHA256
}

type viewKind uint8

const (
	viewNone viewKind = iota
	viewPrepared
	viewCommitted
	viewUnreadable
)

// copyView is what ONE copy says about a slot.
type copyView struct {
	kind  viewKind
	entry evidenceEntry
}

func viewOf(p evidenceEntry, ps entryStatus, c evidenceEntry, cs entryStatus) copyView {
	switch cs {
	case entryValid:
		// A copy whose own two transitions do not describe one append, or whose
		// commit does not follow its preparation, cannot be trusted for either.
		if ps == entryValid && (!samePayload(&p, &c) || c.generation <= p.generation) {
			return copyView{kind: viewUnreadable}
		}
		return copyView{kind: viewCommitted, entry: c}
	case entryCorrupt:
		return copyView{kind: viewUnreadable}
	case entryAbsent:
	}
	switch ps {
	case entryValid:
		return copyView{kind: viewPrepared, entry: p}
	case entryCorrupt:
		return copyView{kind: viewUnreadable}
	case entryAbsent:
	}
	return copyView{kind: viewNone}
}

// combineViews COMPARES the copies. Valid copies that agree give the agreed state; any
// disagreement between valid copies is EvidenceDisagree whichever holds the higher
// generation, because a higher generation proves only that one write landed. An
// unreadable or absent copy decides nothing: the other copy is used.
func combineViews(views [evidenceCopies]copyView) (EvidenceState, []evidenceEntry) {
	var valid []evidenceEntry
	var validKinds []viewKind
	unreadable := false
	for _, v := range views {
		switch v.kind {
		case viewPrepared, viewCommitted:
			valid = append(valid, v.entry)
			validKinds = append(validKinds, v.kind)
		case viewUnreadable:
			unreadable = true
		case viewNone:
		}
	}
	for i := 1; i < len(valid); i++ {
		if validKinds[i] != validKinds[0] ||
			valid[i].generation != valid[0].generation ||
			!samePayload(&valid[i], &valid[0]) {
			return EvidenceDisagree, valid
		}
	}
	switch {
	case len(valid) > 0 && validKinds[0] == viewCommitted:
		return EvidenceCommitted, valid
	case len(valid) > 0:
		return EvidencePrepared, valid
	case unreadable:
		return EvidenceUnreadable, nil
	default:
		return EvidenceNone, nil
	}
}
