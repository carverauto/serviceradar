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

// Package spool is the crash-safe, fsynced agent result spool. A Spool holds one
// lane's records; LaneSet (lanes.go) binds each generation, one Spool, to a lane
// and freezes that generation's identity. Each appended frame is persisted as a
// length-prefixed, CRC-checked record, and its commit is recorded in REDUNDANT
// COMMIT EVIDENCE stored independently of the record segment (see evidence.go). A
// producer receipt is returned only after the record, BOTH evidence copies, and
// the directory metadata that makes those copies discoverable are durable.
//
// On open the spool resolves every allocated slot to exactly one outcome over the
// evidence copies, the sequence high-water, the receipt and attribution bindings,
// and the record bytes (see resolve.go). Only COMMITTED slots are exposed to the
// sender; every other allocated sequence is reported for rollover coverage and is
// never reused.
//
// This slice implements a single segment. Multi-segment rotation/physical reclaim,
// corrupt-segment quarantine, and the loss-manifest/recovery-generation rollover
// are follow-on slices within task 2.4.
//
// Capacity (task 2.26) lives in reserve.go: an Allocator shared by every lane
// keeps the aggregate recovery reserve and a minimum-free floor out of producer
// admission, and a failed storage barrier fail-stops durable work (barrier.go).
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
	"sync"
	"syscall"
)

const (
	segmentFile  = "lane.seg"
	resolvedFile = "resolved"

	recordMagic   = 0x53525350 // "SRSP"
	recordVersion = 1

	// headerLen is magic(4)+version(1)+flags(1)+seq(8)+eventID(16)+bodyLen(4).
	headerLen    = 34
	headerCRC    = 4
	bodyCRCLen   = 4
	minRecordLen = headerLen + headerCRC + bodyCRCLen
	maxBodyLen   = math.MaxUint32 - minRecordLen

	// resyncWindow is how much of the segment is searched per read when looking for
	// the next record header after an unreadable one.
	resyncWindow = 64 << 10

	dirPerm  = 0o700
	filePerm = 0o600
)

// A precomputed CRC table. crc32.MakeTable returns an immutable value derived
// only from the polynomial, and the record format names Castagnoli, so there is
// exactly one correct table for the life of the process.
//
//nolint:gochecknoglobals // immutable, derived from a format constant
var crcTable = crc32.MakeTable(crc32.Castagnoli)

// ErrCorruptHeader is returned when a committed slot's record is read back and its
// header checksum or magic is invalid, or it names a sequence other than the slot's.
// Open does not return it: restart resolution classifies damaged and torn bytes
// instead (see RestartResolution).
var ErrCorruptHeader = errors.New("spool: corrupt record header")

// ErrResolveBeyondHighWater is returned when Resolve is asked to advance the
// watermark past the highest durably appended sequence. A stale/forged gateway
// ACK that did this would permanently hide never-appended frames, so it is
// rejected rather than persisted.
var ErrResolveBeyondHighWater = errors.New("spool: resolve beyond durable high-water")

// ErrEventIDLength is returned when Append is given an event id that is not the
// fixed 16 bytes the record header reserves for it. The header is fixed-width,
// so a short or long id would silently shift every field after it.
var ErrEventIDLength = errors.New("spool: event id must be 16 bytes")

// ErrBindingDigestLength is returned when a commit names a binding digest that is
// not a 32-byte SHA-256.
var ErrBindingDigestLength = errors.New("spool: binding digest must be 32 bytes")

// ErrBodyTooLarge is returned when a frame cannot be length-prefixed by the record
// header.
var ErrBodyTooLarge = errors.New("spool: record body too large")

// CorruptBodyError reports a record whose header is valid and whose body and
// CRC were fully present but did not match: genuine committed-record corruption,
// distinct from a cleanly torn (short) trailing record.
type CorruptBodyError struct{ Sequence uint64 }

func (e *CorruptBodyError) Error() string {
	return fmt.Sprintf("spool: corrupt record body at sequence %d", e.Sequence)
}

// Record is one persisted frame in the spool.
type Record struct {
	Sequence uint64
	EventID  []byte // 16-byte UUID
	Body     []byte // opaque encoded EdgeRecordV1 bytes
}

// Bindings names the digests of the producer idempotency/receipt binding and the
// attribution binding that a commit carries. A nil digest declares that the append
// carries no such binding. A declared binding is part of the commit: on restart it
// must verify, and match the digest named here, or the slot is not COMMITTED.
type Bindings struct {
	ReceiptSHA256     []byte
	AttributionSHA256 []byte
}

// CommitReceipt is the producer receipt. It exists only once the record, both commit
// evidence copies, and their directory metadata are durable.
type CommitReceipt struct {
	Sequence           uint64
	EventID            []byte
	RecordSHA256       []byte
	EvidenceGeneration uint64
}

// barrier names one durability barrier of a commit, in protocol order.
type barrier uint8

const (
	barrierEvidenceDirA barrier = iota
	barrierEvidenceDirB
	barrierPrepareA
	barrierPrepareB
	barrierRecord
	barrierCommitA
	barrierCommitB
)

func dirBarrier(c int) barrier     { return barrierEvidenceDirA + barrier(c) }
func prepareBarrier(c int) barrier { return barrierPrepareA + barrier(c) }
func commitBarrier(c int) barrier  { return barrierCommitA + barrier(c) }

// slotLoc locates one allocated slot's record. committed is set only for a slot the
// sender may expose.
type slotLoc struct {
	offset    int64
	length    uint32
	committed bool
}

// segmentHandle is the part of *os.File a lane's segment needs. Tests wrap it to
// inject storage failures into record writes.
type segmentHandle interface {
	io.ReaderAt
	io.WriterAt
	Sync() error
	Close() error
	Stat() (os.FileInfo, error)
}

// Spool is a single-lane append-only spool. It is safe for concurrent use.
type Spool struct {
	dir      string
	bindings BindingInspector
	alloc    *Allocator

	mu              sync.Mutex
	seg             segmentHandle
	segSize         int64
	evidence        [evidenceCopies]*os.File
	evidenceDurable [evidenceCopies]bool
	nextSeq         uint64
	nextGen         uint64
	resolved        uint64
	slots           []slotLoc // index seq-1, for every allocated sequence
	restart         Resolution
	// failErr is set by the first failed barrier, and every later commit is refused
	// with it: the interrupted slot's durable state is unknown until restart
	// resolution classifies it, so the spool does not append past it.
	failErr error

	// copyOrder is the order evidence copies are written in, and beforeBarrier is
	// crossed immediately before each durability barrier. Both exist so tests can
	// inject a crash at every barrier position in both copy orderings. afterStat is
	// crossed right after a file size is captured, so tests can move another handle's
	// writer on between the captures a scan is bounded by.
	copyOrder     [evidenceCopies]int
	beforeBarrier func(barrier) error
	afterStat     func(file string)
}

// Option configures Open.
type Option func(*Spool)

// WithBindings supplies the receipt and attribution binding verdicts restart
// resolution uses. Without it no binding exists for any slot.
func WithBindings(b BindingInspector) Option {
	return func(s *Spool) { s.bindings = b }
}

// WithAllocator makes every commit pass through a's ordinary producer admission,
// charged to the lane directory: dir itself, which for a LaneSet is a generation
// directory, the one Allocator.AcquireRecovery names for a recovery writing into
// it, not the route profile/traffic class directory above. Open charges every
// file in that directory and in its commit evidence directories to it with
// Allocator.ChargeMeasured, replacing any earlier charge, so reopening a lane
// never counts it twice; a lane Open then fails on stays charged at its size on
// disk. Close keeps the charge, because the files are still on disk; release it
// with Allocator.ReleaseOrdinary once they are physically deleted. Share one
// allocator across every lane on the same filesystem.
func WithAllocator(a *Allocator) Option {
	return func(s *Spool) { s.alloc = a }
}

// Open opens (creating if needed) the spool at dir and resolves durable state.
// Resolution reads the segment twice -- once walking record headers and body
// checksums, once judging each slot's bytes against its commit evidence -- and keeps an
// in-memory index entry for every allocated sequence for the life of the handle. Both
// the time to open and the memory held grow with every record the segment has ever
// held; reclaim and segment rotation (tasks 2.4, 2.24, and 2.28) are what bound them.
func Open(dir string, opts ...Option) (*Spool, error) {
	if err := os.MkdirAll(dir, dirPerm); err != nil {
		return nil, fmt.Errorf("spool: mkdir: %w", err)
	}
	s := &Spool{dir: dir, copyOrder: [evidenceCopies]int{copyA, copyB}}
	for _, opt := range opts {
		opt(s)
	}
	if s.alloc != nil {
		if err := s.chargeLane(); err != nil {
			return nil, err
		}
	}
	f, err := os.OpenFile(filepath.Join(dir, segmentFile), os.O_RDWR|os.O_CREATE, filePerm)
	if err != nil {
		return nil, fmt.Errorf("spool: open segment: %w", err)
	}
	s.seg = f
	if err := s.open(); err != nil {
		_ = s.closeFiles()
		return nil, err
	}
	return s, nil
}

func (s *Spool) open() error {
	if err := fsyncDir(s.dir); err != nil {
		return err
	}
	info, err := s.seg.Stat()
	if err != nil {
		return fmt.Errorf("spool: stat segment: %w", err)
	}
	s.segSize = info.Size()
	if err := s.openEvidence(); err != nil {
		return err
	}
	if err := s.recover(); err != nil {
		return err
	}
	resolved, err := s.readResolved()
	if err != nil {
		return err
	}
	s.resolved = resolved
	return nil
}

// chargeLane charges every regular file in the lane directory to the allocator,
// not only the segment: whatever the lane keeps beside it occupies its disk too,
// including both commit evidence copies in their own directories.
func (s *Spool) chargeLane() error {
	total, err := regularFileBytes(s.dir)
	if err != nil {
		return err
	}
	for c := range evidenceCopies {
		n, err := regularFileBytes(filepath.Join(s.dir, evidenceDirName(c)))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		total += n
	}
	s.alloc.ChargeMeasured(s.dir, total)
	return nil
}

// regularFileBytes sums the sizes of the regular files directly in dir.
func regularFileBytes(dir string) (uint64, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, fmt.Errorf("spool: measure lane: %w", err)
	}
	var total uint64
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return 0, fmt.Errorf("spool: measure lane: %w", err)
		}
		total += uint64(info.Size())
	}
	return total, nil
}

// Append persists one frame with no receipt or attribution binding and returns its
// sequence once it is committed. The sequence space starts at 1 and is never reused.
// Admission and fail-stop are as for Commit.
func (s *Spool) Append(eventID, body []byte) (uint64, error) {
	r, err := s.Commit(eventID, body, Bindings{})
	if err != nil {
		return 0, err
	}
	return r.Sequence, nil
}

// Commit persists one frame under redundant commit evidence and returns the producer
// receipt. The receipt is withheld until every barrier below has passed:
//
//  1. each evidence copy's file and directory entry are durable (first commit only);
//  2. a PREPARED entry is durable in each copy -- the sequence is now allocated;
//  3. the record is durable in the segment;
//  4. a COMMITTED entry is durable in each copy.
//
// If any barrier fails, no receipt is returned and the spool fail-stops; restart
// resolution decides what the interrupted slot is. The failure is a *FailStopError,
// and every later commit is refused with it without touching the segment. On a
// shared allocator it also stops ordinary admission for every lane, but leaves
// recovery running: recovery is how a failed lane is repaired.
//
// With an allocator, a commit is first admitted for every byte it adds on disk: its
// record and the growth of both evidence copies. A refused admission returns an
// error matching ErrAdmissionRefused, writes nothing, and allocates no sequence.
func (s *Spool) Commit(eventID, body []byte, b Bindings) (CommitReceipt, error) {
	if len(eventID) != 16 {
		return CommitReceipt{}, fmt.Errorf("%w: got %d", ErrEventIDLength, len(eventID))
	}
	if len(body) > maxBodyLen {
		return CommitReceipt{}, fmt.Errorf("%w: %d bytes", ErrBodyTooLarge, len(body))
	}
	for _, d := range [][]byte{b.ReceiptSHA256, b.AttributionSHA256} {
		if d != nil && len(d) != sha256.Size {
			return CommitReceipt{}, fmt.Errorf("%w: got %d", ErrBindingDigestLength, len(d))
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seg == nil {
		return CommitReceipt{}, fmt.Errorf("spool: commit: %w", os.ErrClosed)
	}
	if s.failErr != nil {
		return CommitReceipt{}, s.failErr
	}
	var charged uint64
	if s.alloc != nil {
		n, err := s.commitBytes(len(body))
		if err != nil {
			return CommitReceipt{}, err
		}
		if err := s.alloc.admit(s.dir, n); err != nil {
			return CommitReceipt{}, err
		}
		charged = n
	}
	r, err := s.commitLocked(eventID, body, b)
	if s.alloc != nil {
		// Admitted bytes stay charged even if the commit fails: a failed write may
		// still have put some of them on disk.
		s.alloc.settle(charged, err)
	}
	if err != nil {
		s.failErr = asFailStop(err)
		return CommitReceipt{}, s.failErr
	}
	return r, nil
}

// commitBytes is what committing the next sequence with a body of bodyLen adds on
// disk: its record, plus however far each evidence copy must grow to hold the
// slot's fixed-position entries.
func (s *Spool) commitBytes(bodyLen int) (uint64, error) {
	n := uint64(minRecordLen + bodyLen)
	end := evidencePosition(s.nextSeq, stateCommitted) + evidenceEntryLen
	for c := range evidenceCopies {
		var size int64
		info, err := os.Stat(s.evidencePath(c))
		switch {
		case err == nil:
			size = info.Size()
		case !errors.Is(err, os.ErrNotExist):
			return 0, fmt.Errorf("spool: measure evidence copy %c: %w", copyTag(c), err)
		}
		if size < end {
			n += uint64(end - size)
		}
	}
	return n, nil
}

func (s *Spool) commitLocked(eventID, body []byte, b Bindings) (CommitReceipt, error) {
	if err := s.ensureEvidence(); err != nil {
		return CommitReceipt{}, err
	}

	seq := s.nextSeq
	rec := encodeRecord(seq, eventID, body)
	offset := s.segSize
	entry := evidenceEntry{
		state:        statePrepared,
		sequence:     seq,
		generation:   s.nextGen,
		recordOffset: uint64(offset),
		recordLen:    uint32(len(rec)),
		recordSHA256: sha256.Sum256(body),
	}
	copy(entry.eventID[:], eventID)
	if b.ReceiptSHA256 != nil {
		entry.flags |= flagReceiptBinding
		copy(entry.receiptSHA256[:], b.ReceiptSHA256)
	}
	if b.AttributionSHA256 != nil {
		entry.flags |= flagAttributionBinding
		copy(entry.attributionSHA256[:], b.AttributionSHA256)
	}

	// Consume the sequence before any durable write. Once one PREPARED copy lands the
	// sequence is allocated and must never be reused, and a failure below fail-stops
	// the spool with the slot still uncommitted.
	s.nextSeq++
	s.nextGen++
	s.slots = append(s.slots, slotLoc{offset: offset, length: entry.recordLen})

	for _, c := range s.copyOrder {
		if err := s.crossAndWriteEvidence(prepareBarrier(c), c, entry); err != nil {
			return CommitReceipt{}, err
		}
	}

	if err := s.cross(barrierRecord); err != nil {
		return CommitReceipt{}, err
	}
	segPath := filepath.Join(s.dir, segmentFile)
	if _, err := s.seg.WriteAt(rec, offset); err != nil {
		return CommitReceipt{}, &FailStopError{Op: "write", Path: segPath, Err: err}
	}
	s.segSize += int64(len(rec))
	if err := s.seg.Sync(); err != nil {
		return CommitReceipt{}, &FailStopError{Op: "fsync", Path: segPath, Err: err}
	}

	entry.state = stateCommitted
	entry.generation = s.nextGen
	s.nextGen++
	for _, c := range s.copyOrder {
		if err := s.crossAndWriteEvidence(commitBarrier(c), c, entry); err != nil {
			return CommitReceipt{}, err
		}
	}

	s.slots[seq-1].committed = true
	return CommitReceipt{
		Sequence:           seq,
		EventID:            append([]byte(nil), eventID...),
		RecordSHA256:       append([]byte(nil), entry.recordSHA256[:]...),
		EvidenceGeneration: entry.generation,
	}, nil
}

func (s *Spool) cross(b barrier) error {
	if s.beforeBarrier == nil {
		return nil
	}
	return s.beforeBarrier(b)
}

func (s *Spool) crossStat(file string) {
	if s.afterStat != nil {
		s.afterStat(file)
	}
}

func (s *Spool) evidencePath(c int) string {
	return filepath.Join(s.dir, evidenceDirName(c), evidenceFile)
}

// ensureEvidence makes each evidence copy's file AND the directory entries that make
// it discoverable durable. A copy that restart cannot find is not redundancy, so no
// receipt is issued until this has succeeded for both copies.
func (s *Spool) ensureEvidence() error {
	for _, c := range s.copyOrder {
		if s.evidenceDurable[c] {
			continue
		}
		path := s.evidencePath(c)
		if s.evidence[c] == nil {
			if err := os.MkdirAll(filepath.Dir(path), dirPerm); err != nil {
				return fmt.Errorf("spool: mkdir evidence copy %c: %w", copyTag(c), err)
			}
			f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, filePerm)
			if err != nil {
				return fmt.Errorf("spool: create evidence copy %c: %w", copyTag(c), err)
			}
			s.evidence[c] = f
			if err := f.Sync(); err != nil {
				return fmt.Errorf("spool: fsync evidence copy %c: %w", copyTag(c), err)
			}
		}
		if err := s.cross(dirBarrier(c)); err != nil {
			return err
		}
		if err := fsyncDir(s.dir); err != nil {
			return err
		}
		if err := fsyncDir(filepath.Dir(path)); err != nil {
			return err
		}
		s.evidenceDurable[c] = true
	}
	return nil
}

func (s *Spool) crossAndWriteEvidence(b barrier, c int, e evidenceEntry) error {
	if err := s.cross(b); err != nil {
		return err
	}
	e.copyTag = copyTag(c)
	path := s.evidencePath(c)
	if _, err := s.evidence[c].WriteAt(e.encode(), evidencePosition(e.sequence, e.state)); err != nil {
		return &FailStopError{Op: "write", Path: path, Err: err}
	}
	if err := s.evidence[c].Sync(); err != nil {
		return &FailStopError{Op: "fsync", Path: path, Err: err}
	}
	return nil
}

// Unresolved returns, in sequence order, every committed record with sequence
// greater than the resolved watermark.
func (s *Spool) Unresolved() ([]Record, error) {
	var out []Record
	err := s.ScanFrom(0, func(rec Record) bool {
		out = append(out, rec)
		return true
	})
	return out, err
}

// Resolve advances the durable resolved watermark to through (inclusive),
// persisting it. Records at or below the watermark are considered handled and
// are excluded from Unresolved. The watermark only advances, and never past the
// highest allocated sequence: a watermark beyond the high-water would hide frames
// that were never spooled (permanent loss), so it is rejected.
func (s *Spool) Resolve(through uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if through <= s.resolved {
		return nil
	}
	highWater := s.nextSeq - 1 // nextSeq starts at 1, so 0 means nothing appended
	if through > highWater {
		return fmt.Errorf("%w: through=%d high-water=%d", ErrResolveBeyondHighWater, through, highWater)
	}
	if err := s.writeResolved(through); err != nil {
		return err
	}
	s.resolved = through
	return nil
}

// ScanFrom streams COMMITTED records whose sequence is greater than both the
// resolved watermark and after, in sequence order, invoking visit for each until
// visit returns false (e.g. the sender's credit window is exhausted) or the
// allocated sequences end. Ambiguous, lost, and in-flight slots are never visited, so
// the visited sequences can have gaps. The sender's lane cannot cross such a gap yet:
// it wedges there until the wire-level rollover/coverage handling of task 2.27 lands
// (see package sender). Reaching the end adopts slots another handle on the same
// directory has allocated since, so a sender sees a producer that appends through its
// own handle. Record bodies are read one at a time, but they are located through an
// index that holds an entry for every allocated sequence (see Open). A closed spool
// stays readable over the slots it has indexed: its scan opens its own segment handle
// for the scan's duration.
func (s *Spool) ScanFrom(after uint64, visit func(Record) bool) error {
	s.mu.Lock()
	seq := max(s.resolved, after)
	s.mu.Unlock()

	var own *os.File
	defer func() {
		if own != nil {
			_ = own.Close()
		}
	}()
	refreshed := false
	for {
		seq++
		s.mu.Lock()
		if seq >= s.nextSeq && !refreshed && s.seg != nil {
			refreshed = true
			if err := s.refreshLocked(); err != nil {
				s.mu.Unlock()
				return err
			}
		}
		if seq >= s.nextSeq {
			s.mu.Unlock()
			return nil
		}
		loc := s.slots[seq-1]
		seg := s.seg
		s.mu.Unlock()

		if !loc.committed {
			continue
		}
		if seg == nil {
			if own == nil {
				f, err := os.Open(filepath.Join(s.dir, segmentFile))
				if err != nil {
					return fmt.Errorf("spool: open for scan: %w", err)
				}
				own = f
			}
			seg = own
		}
		rec, err := readRecordAt(seg, loc)
		if err != nil {
			return err
		}
		if rec.Sequence != seq {
			return fmt.Errorf("%w: slot %d holds sequence %d", ErrCorruptHeader, seq, rec.Sequence)
		}
		if !visit(rec) {
			return nil
		}
	}
}

// NextSequence returns the sequence the next Append will assign.
func (s *Spool) NextSequence() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.nextSeq
}

// Resolved returns the durable resolved watermark: every sequence at or below
// it is excluded from Unresolved/ScanFrom. A sender opening a new lane session
// reports Resolved()+1 as its first unresolved sequence.
func (s *Spool) Resolved() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.resolved
}

// RestartResolution returns how every allocated slot resolved when the spool was
// opened. Slots that did not resolve COMMITTED are what rollover coverage must
// account for.
func (s *Spool) RestartResolution() Resolution {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.restart
	r.Slots = append([]SlotResolution(nil), r.Slots...)
	r.Discarded = append([]SlotResolution(nil), r.Discarded...)
	return r
}

// Close closes the segment and evidence files.
func (s *Spool) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closeFiles()
}

func (s *Spool) closeFiles() error {
	var errs []error
	if s.seg != nil {
		errs = append(errs, s.seg.Close())
		s.seg = nil
	}
	for c, f := range s.evidence {
		if f != nil {
			errs = append(errs, f.Close())
			s.evidence[c] = nil
		}
	}
	return errors.Join(errs...)
}

// --- record framing ---

func encodeRecord(seq uint64, eventID, body []byte) []byte {
	total := headerLen + headerCRC + len(body) + bodyCRCLen
	buf := make([]byte, total)

	binary.LittleEndian.PutUint32(buf[0:], recordMagic)
	buf[4] = recordVersion
	buf[5] = 0 // flags
	binary.LittleEndian.PutUint64(buf[6:], seq)
	copy(buf[14:30], eventID)
	binary.LittleEndian.PutUint32(buf[30:], uint32(len(body)))
	binary.LittleEndian.PutUint32(buf[headerLen:], crc32.Checksum(buf[:headerLen], crcTable))

	off := headerLen + headerCRC
	copy(buf[off:], body)
	binary.LittleEndian.PutUint32(buf[off+len(body):], crc32.Checksum(body, crcTable))
	return buf
}

type recordHeader struct {
	seq     uint64
	eventID [16]byte
	bodyLen uint32
}

// parseHeader validates a headerLen+headerCRC byte header.
func parseHeader(header []byte) (recordHeader, bool) {
	if binary.LittleEndian.Uint32(header[0:]) != recordMagic ||
		binary.LittleEndian.Uint32(header[headerLen:]) != crc32.Checksum(header[:headerLen], crcTable) {
		return recordHeader{}, false
	}
	h := recordHeader{
		seq:     binary.LittleEndian.Uint64(header[6:]),
		bodyLen: binary.LittleEndian.Uint32(header[30:]),
	}
	copy(h.eventID[:], header[14:30])
	return h, true
}

// readRecord reads one record. A cleanly-torn or absent tail returns io.EOF /
// io.ErrUnexpectedEOF; a present-but-invalid header returns ErrCorruptHeader.
func readRecord(r *bufio.Reader) (Record, int, error) {
	header := make([]byte, headerLen+headerCRC)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return Record{}, 0, err
	}
	h, ok := parseHeader(header)
	if !ok {
		return Record{}, 0, ErrCorruptHeader
	}

	body := make([]byte, h.bodyLen)
	if _, err := io.ReadFull(r, body); err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return Record{}, 0, err
	}
	crcBuf := make([]byte, bodyCRCLen)
	if _, err := io.ReadFull(r, crcBuf); err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return Record{}, 0, err
	}
	if binary.LittleEndian.Uint32(crcBuf) != crc32.Checksum(body, crcTable) {
		// Header, body, and CRC were all fully present but the CRC does not match:
		// this is committed-record corruption, not a torn (short) tail.
		return Record{}, 0, &CorruptBodyError{Sequence: h.seq}
	}

	recLen := headerLen + headerCRC + int(h.bodyLen) + bodyCRCLen
	return Record{Sequence: h.seq, EventID: h.eventID[:], Body: body}, recLen, nil
}

func readRecordAt(f io.ReaderAt, loc slotLoc) (Record, error) {
	buf := make([]byte, loc.length)
	if _, err := f.ReadAt(buf, loc.offset); err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return Record{}, fmt.Errorf("spool: read record: %w", err)
	}
	rec, _, err := readRecord(bufio.NewReader(bytes.NewReader(buf)))
	return rec, err
}

// --- resolved watermark ---

func (s *Spool) writeResolved(v uint64) error {
	path := filepath.Join(s.dir, resolvedFile)
	tmp := path + ".tmp"
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	if err := os.WriteFile(tmp, b[:], filePerm); err != nil {
		return fmt.Errorf("spool: write resolved: %w", err)
	}
	if err := fsyncFile(tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("spool: rename resolved: %w", err)
	}
	return fsyncDir(s.dir)
}

func (s *Spool) readResolved() (uint64, error) {
	b, err := os.ReadFile(filepath.Join(s.dir, resolvedFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil
		}
		return 0, fmt.Errorf("spool: read resolved: %w", err)
	}
	if len(b) != 8 {
		return 0, nil
	}
	return binary.LittleEndian.Uint64(b), nil
}

// --- fsync helpers ---

func fsyncFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	return f.Sync()
}

func fsyncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	if err := f.Sync(); err != nil {
		// Directory fsync is genuinely unsupported on some filesystems, which
		// report EINVAL/ENOTSUP; those are safe to ignore. Every other failure
		// (e.g. EIO) means the metadata may not be durable and MUST propagate,
		// so the watermark rename or new spool directory is not reported durable.
		if errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) {
			return nil
		}
		return fmt.Errorf("spool: fsync dir %q: %w", dir, err)
	}
	return nil
}
