// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

const recoveryArchiveFile = "terminal.archive"

// destinationArchiveFile is the archive name of the recovery destination generation.
const destinationArchiveFile = "destination.archive"
const recoveryArchiveMagic = "SRRARCH1"

type recoveryArchiveDescriptor struct {
	Size            uint64
	SHA256          []byte
	RetainedThrough uint64
}

type recoveryArchiveEntry struct {
	name, path string
	offset     int64
	size       uint64
}

// ArchiveTerminalEvidence preserves original terminal bytes and rejected raw
// records without the legacy quarantine's eviction policy. Exact preflight and
// prefix verification allow a torn archive to resume without truncating evidence.
func (o *RecoveryOperation) ArchiveTerminalEvidence() error {
	o.mu.Lock()
	defer o.mu.Unlock()
	pending, err := o.pendingPhase("archive")
	if err != nil {
		return err
	}
	if !pending {
		_, err = o.readArchive()
		return err
	}
	if err = o.requireSourceHold(); err != nil {
		return err
	}
	if _, err = o.readCoverage(); err != nil {
		return err
	}
	entries, err := o.archiveEntries()
	if err != nil {
		return err
	}
	descriptor := recoveryArchiveDescriptor{RetainedThrough: o.source.Resolved()}
	header := recoveryArchiveHeader(o.frozen, o.plan.ReclaimThrough, o.plan.HighWater, descriptor.RetainedThrough, len(entries))
	descriptor.Size = uint64(len(header))
	for _, entry := range entries {
		descriptor.Size += uint64(len(archiveEntryHeader(entry))) + entry.size
	}
	// Coverage and archive descriptor pairs retain room independently of raw data.
	remaining := o.grant.Remaining(ArtifactMapping)
	existing, err := fileSizeOrAbsent(filepath.Join(o.dir, recoveryArchiveFile+".tmp"))
	if err != nil {
		return err
	}
	finalSize, err := fileSizeOrAbsent(filepath.Join(o.dir, recoveryArchiveFile))
	if err != nil {
		return err
	}
	if finalSize > 0 {
		existing = finalSize
	}
	if existing < 0 || uint64(existing) > descriptor.Size {
		return ErrRecoveryJournalCorrupt
	}
	missing := descriptor.Size - uint64(existing)
	if missing > remaining {
		return &ReserveExhaustedError{Artifact: ArtifactMapping, Requested: missing, Remaining: remaining}
	}
	hash := sha256.New()
	produce := func(w io.Writer) error { return produceRecoveryArchive(w, header, entries) }
	if err = produce(hash); err != nil {
		return err
	}
	descriptor.SHA256 = hash.Sum(nil)
	writer := recoveryArchiveWriter{o.dir, recoveryArchiveFile, ArtifactMapping, o.frozen, o.grant}
	if err = writer.write(descriptor, produce); err != nil {
		return err
	}
	raw, err := json.Marshal(descriptor)
	if err != nil {
		return err
	}
	if err = writeRecoveryPhase(o.dir, "archive", o.frozen, raw, o.grant); err != nil {
		return err
	}
	_, err = o.readArchive()
	return err
}

func recoveryArchiveHeader(frozen [32]byte, base, high, resolved uint64, count int) []byte {
	raw := append([]byte(recoveryArchiveMagic), frozen[:]...)
	for _, n := range []uint64{base, high, resolved} {
		raw = binary.BigEndian.AppendUint64(raw, n)
	}
	return binary.BigEndian.AppendUint32(raw, uint32(count))
}

func archiveEntryHeader(e recoveryArchiveEntry) []byte {
	raw := binary.BigEndian.AppendUint16(nil, uint16(len(e.name)))
	raw = append(raw, e.name...)
	raw = binary.BigEndian.AppendUint64(raw, uint64(e.offset))
	return binary.BigEndian.AppendUint64(raw, e.size)
}

func produceRecoveryArchive(w io.Writer, header []byte, entries []recoveryArchiveEntry) error {
	if _, err := w.Write(header); err != nil {
		return err
	}
	for _, entry := range entries {
		if _, err := w.Write(archiveEntryHeader(entry)); err != nil {
			return err
		}
		f, err := os.Open(entry.path)
		if err != nil {
			return err
		}
		_, err = io.CopyN(w, io.NewSectionReader(f, entry.offset, int64(entry.size)), int64(entry.size))
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (o *RecoveryOperation) archiveEntries() ([]recoveryArchiveEntry, error) {
	s := o.source.spool
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.baseSeq != o.plan.ReclaimThrough || s.nextSeq-1 != o.plan.HighWater || o.plan.First != s.baseSeq+1 || o.plan.Last != o.plan.HighWater {
		return nil, ErrRecoverySplitRequired
	}
	return collectRecoveryArchive(s, o.grant.alloc.budgets[ArtifactMapping], false)
}

// recordArchiveDispositions marks permanently rejected sequences and reports
// whether any disposition is not a recognized terminal kind, which forces the
// full segment into the archive.
func recordArchiveDispositions(ack *edgev1.EdgeDeliveryAckV1, rejected map[uint64]bool) bool {
	fullSegment := false
	for _, d := range ack.Dispositions {
		switch d.GetKind() {
		case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT:
			rejected[d.GetSequence()] = true
		case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE:
		case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE:
			fullSegment = true
		default:
			fullSegment = true
		}
		if len(d.ProtoReflect().GetUnknown()) != 0 {
			fullSegment = true
		}
	}
	return fullSegment
}

// listRecoveryArchiveDir reads a bounded, name-sorted listing of a generation
// directory, refusing one too large to archive in a single recovery.
func listRecoveryArchiveDir(dir string) ([]os.DirEntry, error) {
	directory, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	files, err := directory.ReadDir(2*edgerecord.MaxRecoverySlots + 65)
	closeErr := directory.Close()
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if len(files) > 2*edgerecord.MaxRecoverySlots+64 {
		return nil, ErrRecoverySplitRequired
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Name() < files[j].Name() })
	return files, nil
}

// collectRecoveryArchive requires s.mu and a sealed or recovery-held generation.
// forceAll preserves ambiguous superseded controls without manufacturing terminal
// dispositions; all their original allocation, record and binding bytes survive.
func collectRecoveryArchive(s *Spool, maxBytes uint64, forceAll bool) ([]recoveryArchiveEntry, error) {
	if s.nextSeq-1-s.baseSeq > edgerecord.MaxRecoverySlots {
		return nil, ErrRecoverySplitRequired
	}
	files, err := listRecoveryArchiveDir(s.dir)
	if err != nil {
		return nil, err
	}
	var entries []recoveryArchiveEntry
	rejected := map[uint64]bool{}
	fullSegment := forceAll
	var terminalBytes uint64
	for _, file := range files {
		if _, ok := terminalSequence(file.Name()); !ok {
			continue
		}
		info, err := file.Info()
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() < 0 {
			return nil, ErrRecoveryJournalCorrupt
		}
		terminalBytes += uint64(info.Size())
		if terminalBytes > maxBytes {
			return nil, ErrReserveExhausted
		}
		path := filepath.Join(s.dir, file.Name())
		entries = append(entries, recoveryArchiveEntry{file.Name(), path, 0, uint64(info.Size())})
		if info.Size() > edgerecord.DefaultMaxDispositionBytes {
			fullSegment = true
			continue
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		ack := new(edgev1.EdgeDeliveryAckV1)
		if proto.Unmarshal(raw, ack) != nil || len(ack.ProtoReflect().GetUnknown()) != 0 {
			fullSegment = true
			continue
		}
		if recordArchiveDispositions(ack, rejected) {
			fullSegment = true
		}
	}
	if len(entries) == 0 && !forceAll {
		return entries, nil
	}
	// Complete original commit/binding evidence accompanies the terminal bytes,
	// even when corruption makes a rejected raw extent impossible to isolate.
	for _, name := range []string{identityFile, evidenceFormatFile, resolvedFile} {
		entries, err = appendArchiveFile(entries, name, filepath.Join(s.dir, name))
		if err != nil {
			return nil, err
		}
	}
	for _, name := range []string{attributionFile, relocationFile, filepath.Join(evidenceDirName(copyA), evidenceFile), filepath.Join(evidenceDirName(copyB), evidenceFile)} {
		entries, err = appendArchiveFile(entries, filepath.Join("data", name), filepath.Join(s.dataDir, name))
		if err != nil {
			return nil, err
		}
	}
	sequences := make([]uint64, 0, len(rejected))
	for seq := range rejected {
		sequences = append(sequences, seq)
	}
	sort.Slice(sequences, func(i, j int) bool { return sequences[i] < sequences[j] })
	var records []recoveryArchiveEntry
	for _, seq := range sequences {
		if seq <= s.baseSeq || seq >= s.nextSeq {
			fullSegment = true
			break
		}
		loc := s.slots[seq-s.baseSeq-1]
		if loc.offset < 0 || loc.length == 0 || loc.offset+int64(loc.length) > s.segSize {
			fullSegment = true
			break
		}
		records = append(records, recoveryArchiveEntry{fmt.Sprintf("record-%020d", seq), s.segmentPath(), loc.offset, uint64(loc.length)})
	}
	if fullSegment {
		return appendArchiveFile(entries, "unclassified-segment", s.segmentPath())
	}
	return append(entries, records...), nil
}

func appendArchiveFile(entries []recoveryArchiveEntry, name, path string) ([]recoveryArchiveEntry, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return entries, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() < 0 {
		return nil, ErrRecoveryJournalCorrupt
	}
	return append(entries, recoveryArchiveEntry{name, path, 0, uint64(info.Size())}), nil
}

// archiveResumeWriter compares every retained byte before appending the missing
// suffix. No partial archive, valid or corrupt, is deleted to gain scratch space.
type archiveResumeWriter struct {
	prior     io.Reader
	remaining uint64
	output    io.Writer
	hash      io.Writer
	count     uint64
}

func (w *archiveResumeWriter) Write(raw []byte) (int, error) {
	total := len(raw)
	if w.remaining > 0 {
		n := min(uint64(len(raw)), w.remaining)
		prior := make([]byte, int(n))
		if _, err := io.ReadFull(w.prior, prior); err != nil {
			return 0, err
		}
		if !bytes.Equal(raw[:n], prior) {
			return 0, ErrRecoveryJournalConflict
		}
		w.remaining -= n
		_, _ = w.hash.Write(raw[:n])
		w.count += n
		raw = raw[n:]
	}
	if len(raw) > 0 {
		n, err := w.output.Write(raw)
		_, _ = w.hash.Write(raw[:n])
		w.count += uint64(n)
		if err != nil {
			return total - len(raw) + n, err
		}
		if n != len(raw) {
			return total - len(raw) + n, io.ErrShortWrite
		}
	}
	return total, nil
}

type recoveryArchiveWriter struct {
	dir, name string
	artifact  Artifact
	frozen    [32]byte
	grant     *RecoveryGrant
}

func (w recoveryArchiveWriter) write(descriptor recoveryArchiveDescriptor, produce func(io.Writer) error) error {
	path := filepath.Join(w.dir, w.name)
	if _, err := os.Lstat(path); err == nil {
		return verifyRecoveryArchive(path, descriptor, w.frozen)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temp := path + ".tmp"
	prior, err := os.Open(temp)
	size := int64(0)
	if err == nil {
		defer func() { _ = prior.Close() }()
		info, e := prior.Stat()
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() {
			return ErrRecoveryJournalCorrupt
		}
		size = info.Size()
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if size < 0 || uint64(size) > descriptor.Size {
		return ErrRecoveryJournalCorrupt
	}
	g := w.grant
	g.step.Lock()
	defer g.step.Unlock()
	missing := descriptor.Size - uint64(size)
	if err = g.charge(w.artifact, missing); err != nil {
		return err
	}
	output, err := g.alloc.fs.OpenFile(temp, os.O_CREATE|os.O_WRONLY|os.O_APPEND, filePerm)
	if err == nil {
		h := sha256.New()
		writer := &archiveResumeWriter{prior: prior, remaining: uint64(size), output: output, hash: h}
		err = produce(writer)
		if err == nil && (writer.count != descriptor.Size || !bytes.Equal(h.Sum(nil), descriptor.SHA256)) {
			err = ErrRecoveryJournalConflict
		}
		if err == nil {
			err = output.Sync()
		}
		closeErr := output.Close()
		if err == nil {
			err = closeErr
		}
	}
	if err == nil {
		err = g.alloc.fs.Rename(temp, path)
	}
	if err == nil {
		err = g.alloc.fs.SyncDir(w.dir)
	}
	g.alloc.mu.Lock()
	g.landLocked(w.artifact, missing)
	g.alloc.mu.Unlock()
	if err != nil {
		return g.FailStop("preserve recovery terminal archive", err)
	}
	return verifyRecoveryArchive(path, descriptor, w.frozen)
}

func verifyRecoveryArchive(path string, d recoveryArchiveDescriptor, frozen [32]byte) error {
	if len(d.SHA256) != 32 || d.Size < 68 {
		return ErrRecoveryJournalCorrupt
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || uint64(info.Size()) != d.Size {
		return ErrRecoveryJournalCorrupt
	}
	header := make([]byte, 40)
	if _, err = io.ReadFull(f, header); err != nil {
		return err
	}
	if string(header[:8]) != recoveryArchiveMagic || !bytes.Equal(header[8:], frozen[:]) {
		return ErrRecoveryJournalConflict
	}
	h := sha256.New()
	_, _ = h.Write(header)
	if _, err = io.Copy(h, f); err != nil {
		return err
	}
	if !bytes.Equal(h.Sum(nil), d.SHA256) {
		return ErrRecoveryJournalCorrupt
	}
	return nil
}

func (o *RecoveryOperation) readArchive() (recoveryArchiveDescriptor, error) {
	var descriptor recoveryArchiveDescriptor
	raw, err := readRecoveryPhase(o.dir, "archive", o.frozen)
	if err != nil {
		return descriptor, err
	}
	if err = decodeRecoveryJSON(raw, &descriptor); err != nil {
		return descriptor, err
	}
	if descriptor.RetainedThrough < o.plan.ReclaimThrough || descriptor.RetainedThrough > o.plan.HighWater {
		return descriptor, ErrRecoveryJournalCorrupt
	}
	return descriptor, verifyRecoveryArchive(filepath.Join(o.dir, recoveryArchiveFile), descriptor, o.frozen)
}
