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
// length-prefixed, CRC-checked record before the caller is told it is durable, so
// a restart never loses or reuses an unacknowledged sequence. On open the spool
// recovers by scanning its segment, validating record checksums, and truncating a
// torn trailing record.
//
// The Spool is the single-segment core (append + fsync + recovery +
// ack watermark). Multi-segment rotation/physical reclaim, corrupt-segment
// quarantine, and the loss-manifest/recovery-generation rollover are follow-on
// slices within task 2.4.
//
// Capacity (task 2.26) lives in reserve.go: an Allocator shared by every lane
// keeps the aggregate recovery reserve and a minimum-free floor out of producer
// admission, and a failed storage barrier fail-stops durable work (barrier.go).
package spool

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
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
	headerLen  = 34
	headerCRC  = 4
	bodyCRCLen = 4

	dirPerm  = 0o700
	filePerm = 0o600
)

// A precomputed CRC table. crc32.MakeTable returns an immutable value derived
// only from the polynomial, and the record format names Castagnoli, so there is
// exactly one correct table for the life of the process.
//
//nolint:gochecknoglobals // immutable, derived from a format constant
var crcTable = crc32.MakeTable(crc32.Castagnoli)

// ErrCorruptHeader is returned when a record header is present but its checksum
// or magic is invalid (as opposed to a cleanly torn tail, which is recovered
// silently).
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

// CorruptBodyError reports a record whose header is valid and whose body and
// CRC were fully present but did not match: genuine committed-record corruption,
// distinct from a cleanly torn (short) trailing record. Recovery must route this
// through the loss-manifest/rollover path (task 2.4) rather than silently
// truncating, because later readable records would otherwise be dropped
// unaudited.
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

// Spool is a single-lane append-only spool. It is safe for concurrent use.
type Spool struct {
	dir   string
	alloc *Allocator

	mu       sync.Mutex
	seg      durableFile
	nextSeq  uint64
	resolved uint64
	// failErr is set by the first failed record write or fsync. From then on
	// Append refuses: the segment tail is in an unknown state, and appending past
	// it would bury a torn record mid-segment. Reopening truncates the torn tail.
	failErr error
}

// Option configures Open.
type Option func(*Spool)

// WithAllocator makes every Append pass through a's ordinary producer admission,
// charged to the lane directory. Open charges the segment bytes it recovers to
// that directory with Allocator.ChargeMeasured, replacing any earlier charge, so
// reopening a lane never counts it twice. Close keeps the charge, because the
// segment is still on disk; release it with Allocator.ReleaseOrdinary once the
// segment is physically deleted. Share one allocator across every lane on the
// same filesystem.
func WithAllocator(a *Allocator) Option {
	return func(s *Spool) { s.alloc = a }
}

// Open opens (creating if needed) the spool at dir and recovers durable state.
func Open(dir string, opts ...Option) (*Spool, error) {
	if err := os.MkdirAll(dir, dirPerm); err != nil {
		return nil, fmt.Errorf("spool: mkdir: %w", err)
	}
	if err := fsyncDir(dir); err != nil {
		return nil, err
	}

	s := &Spool{dir: dir}
	for _, opt := range opts {
		opt(s)
	}

	maxSeq, validLen, err := s.scanSegment()
	if err != nil {
		return nil, err
	}

	f, err := os.OpenFile(filepath.Join(dir, segmentFile), os.O_RDWR|os.O_CREATE, filePerm)
	if err != nil {
		return nil, fmt.Errorf("spool: open segment: %w", err)
	}
	// Truncate any torn trailing bytes past the last fully-valid record.
	if err := f.Truncate(validLen); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("spool: truncate torn tail: %w", err)
	}
	if _, err := f.Seek(validLen, io.SeekStart); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("spool: seek: %w", err)
	}
	s.seg = f
	s.nextSeq = maxSeq + 1

	resolved, err := s.readResolved()
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	s.resolved = resolved

	if s.alloc != nil {
		s.alloc.ChargeMeasured(dir, uint64(validLen))
	}
	return s, nil
}

// Append persists one frame durably and returns its assigned sequence. The
// sequence space starts at 1 and is never reused. eventID must be 16 bytes.
//
// With an allocator, a refused admission returns an error matching
// ErrAdmissionRefused and writes nothing. A failed write or fsync returns a
// *FailStopError, and every later Append is refused with it without touching
// the segment. It also stops ordinary admission on a shared allocator for every
// lane, but leaves recovery running: recovery is how a failed lane is repaired.
func (s *Spool) Append(eventID, body []byte) (uint64, error) {
	if len(eventID) != 16 {
		return 0, fmt.Errorf("%w: got %d", ErrEventIDLength, len(eventID))
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.failErr != nil {
		return 0, s.failErr
	}
	if s.seg == nil {
		return 0, fmt.Errorf("spool: append: %w", os.ErrClosed)
	}

	seq := s.nextSeq
	rec := encodeRecord(seq, eventID, body)
	if s.alloc != nil {
		// Admitted bytes stay charged even if the write below fails: a failed
		// write may still have put some of them on disk.
		if err := s.alloc.admit(s.dir, uint64(len(rec))); err != nil {
			return 0, err
		}
	}
	err := writeAndSync(s.seg, filepath.Join(s.dir, segmentFile), rec)
	if s.alloc != nil {
		s.alloc.settle(uint64(len(rec)), err)
	}
	if err != nil {
		s.failErr = err
		return 0, err
	}

	s.nextSeq++
	return seq, nil
}

// Unresolved returns, in sequence order, every record with sequence greater than
// the resolved watermark.
func (s *Spool) Unresolved() ([]Record, error) {
	s.mu.Lock()
	watermark := s.resolved
	s.mu.Unlock()

	f, err := os.Open(filepath.Join(s.dir, segmentFile))
	if err != nil {
		return nil, fmt.Errorf("spool: open for read: %w", err)
	}
	defer func() { _ = f.Close() }()

	var out []Record
	r := bufio.NewReader(f)
	for {
		rec, _, err := readRecord(r)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				break // torn/absent tail
			}
			return nil, err
		}
		if rec.Sequence > watermark {
			out = append(out, rec)
		}
	}
	return out, nil
}

// Resolve advances the durable resolved watermark to through (inclusive),
// persisting it. Records at or below the watermark are considered handled and
// are excluded from Unresolved. The watermark only advances, and never past the
// highest durably appended sequence: a watermark beyond the append high-water
// would hide frames that were never spooled (permanent loss), so it is rejected.
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

// ScanFrom streams unresolved records whose sequence is greater than both the
// resolved watermark and after, in sequence order, invoking visit for each until
// visit returns false (e.g. the sender's credit window is exhausted) or the
// durable prefix ends. Only the records visit chooses to retain are held, so a
// multi-gigabyte backlog is never materialized to apply a small credit window.
func (s *Spool) ScanFrom(after uint64, visit func(Record) bool) error {
	s.mu.Lock()
	start := s.resolved
	s.mu.Unlock()
	if after > start {
		start = after
	}

	f, err := os.Open(filepath.Join(s.dir, segmentFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("spool: open for scan: %w", err)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	for {
		rec, _, err := readRecord(r)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return nil // clean/absent tail
			}
			return err // ErrCorruptHeader / *CorruptBodyError propagate
		}
		if rec.Sequence <= start {
			continue
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

// Close closes the underlying segment file.
func (s *Spool) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seg == nil {
		return nil
	}
	err := s.seg.Close()
	s.seg = nil
	return err
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

// readRecord reads one record. A cleanly-torn or absent tail returns io.EOF /
// io.ErrUnexpectedEOF; a present-but-invalid header returns ErrCorruptHeader.
func readRecord(r *bufio.Reader) (Record, int, error) {
	header := make([]byte, headerLen+headerCRC)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return Record{}, 0, err
	}

	if binary.LittleEndian.Uint32(header[0:]) != recordMagic {
		return Record{}, 0, ErrCorruptHeader
	}
	if binary.LittleEndian.Uint32(header[headerLen:]) != crc32.Checksum(header[:headerLen], crcTable) {
		return Record{}, 0, ErrCorruptHeader
	}

	seq := binary.LittleEndian.Uint64(header[6:])
	eventID := append([]byte(nil), header[14:30]...)
	bodyLen := binary.LittleEndian.Uint32(header[30:])

	body := make([]byte, bodyLen)
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
		// this is committed-record corruption, not a torn (short) tail. Surface it
		// distinctly so recovery routes it through the loss-manifest/rollover path
		// instead of silently truncating and dropping every later record.
		return Record{}, 0, &CorruptBodyError{Sequence: seq}
	}

	recLen := headerLen + headerCRC + int(bodyLen) + bodyCRCLen
	return Record{Sequence: seq, EventID: eventID, Body: body}, recLen, nil
}

// scanSegment walks the segment and returns the highest valid sequence and the
// byte length of the fully-valid prefix (where a torn tail is truncated).
func (s *Spool) scanSegment() (maxSeq uint64, validLen int64, err error) {
	f, err := os.Open(filepath.Join(s.dir, segmentFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, 0, nil
		}
		return 0, 0, fmt.Errorf("spool: open for scan: %w", err)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	for {
		rec, recLen, rerr := readRecord(r)
		if rerr != nil {
			if errors.Is(rerr, io.EOF) || errors.Is(rerr, io.ErrUnexpectedEOF) {
				return maxSeq, validLen, nil
			}
			return 0, 0, rerr
		}
		if rec.Sequence > maxSeq {
			maxSeq = rec.Sequence
		}
		validLen += int64(recLen)
	}
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
