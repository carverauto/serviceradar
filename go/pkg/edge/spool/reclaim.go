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
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

var errReclaimState = errors.New("spool: invalid reclaim state")

const dataPrefix = ".spool-data-"
const checkpointSuffix = ".checkpoint"
const checkpointSize = 88

func dataName(base uint64) string { return fmt.Sprintf("%s%020d", dataPrefix, base) }

func dataBase(name string) (uint64, bool) {
	if !strings.HasPrefix(name, dataPrefix) || len(name) != len(dataPrefix)+20 {
		return 0, false
	}
	base, err := strconv.ParseUint(strings.TrimPrefix(name, dataPrefix), 10, 64)
	return base, err == nil && base > 0 && base < math.MaxUint64 && name == dataName(base)
}

func (s *Spool) segmentPath() string { return filepath.Join(s.dataDir, segmentFile) }
func (s *Spool) evidencePosition(seq uint64, state byte) int64 {
	return evidencePosition(seq-s.baseSeq, state)
}

// lane.seg is either the legacy regular file or a symlink to a data directory.
// The latter deliberately fails when opened by an older binary: it must not
// mistake a reclaimed segment for a new sequence space starting at one.
func (s *Spool) layoutName() (string, error) {
	path := filepath.Join(s.dir, segmentFile)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if info.Mode().IsRegular() {
		return "", nil
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return "", fmt.Errorf("%w: invalid segment pointer", errReclaimState)
	}
	name, err := os.Readlink(path)
	if err != nil {
		return "", err
	}
	if _, ok := dataBase(name); !ok {
		return "", fmt.Errorf("%w: invalid segment directory", errReclaimState)
	}
	return name, nil
}

func (s *Spool) loadLayout() error {
	name, err := s.layoutName()
	if err != nil {
		return err
	}
	s.dataDir, s.baseSeq = s.dir, 0
	if name == "" {
		return nil
	}
	base, _ := dataBase(name)
	b, err := os.ReadFile(filepath.Join(s.dir, name+checkpointSuffix))
	if err != nil {
		return fmt.Errorf("spool: read reclaim checkpoint: %w", err)
	}
	if len(b) != checkpointSize || string(b[:8]) != "SRRECL01" {
		return fmt.Errorf("%w: invalid reclaim checkpoint", errReclaimState)
	}
	sum := sha256.Sum256(b[:56])
	if !bytes.Equal(sum[:], b[56:]) || binary.LittleEndian.Uint64(b[8:]) != base || binary.LittleEndian.Uint64(b[16:]) == 0 {
		return fmt.Errorf("%w: corrupt reclaim checkpoint", errReclaimState)
	}
	dataDir := filepath.Join(s.dir, name)
	info, err := os.Lstat(dataDir)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("%w: missing data directory %s", errReclaimState, name)
	}
	info, err = os.Lstat(filepath.Join(dataDir, segmentFile))
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("%w: missing reclaimed segment", errReclaimState)
	}
	s.dataDir, s.baseSeq, s.nextGen = dataDir, base, binary.LittleEndian.Uint64(b[16:])
	return nil
}

func (s *Spool) requireCurrentLayout() error {
	name, err := s.layoutName()
	if err != nil {
		return err
	}
	current := s.dir
	if name != "" {
		current = filepath.Join(s.dir, name)
	}
	if current != s.dataDir {
		return fmt.Errorf("%w: segment was reclaimed by another handle; reopen before writing", errReclaimState)
	}
	return nil
}

func (s *Spool) refreshLayout() error {
	if err := s.requireCurrentLayout(); err == nil {
		return nil
	}
	if err := s.closeFiles(); err != nil {
		return err
	}
	if err := s.loadLayout(); err != nil {
		return err
	}
	f, err := os.OpenFile(s.segmentPath(), os.O_RDWR, filePerm)
	if err != nil {
		return err
	}
	s.seg = f
	s.evidenceDurable = [evidenceCopies]bool{}
	s.segBounds = segmentBounds{limits: s.segBounds.limits}
	return s.open()
}

// ReclaimResolved retries reclamation after a restart or a busy recovery reserve.
// Only a fully drained segment whose every record has durable accepted evidence
// is eligible. Permanent rejections stay on disk until local quarantine exists.
func (s *Spool) ReclaimResolved() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reclaimLocked()
}

func (s *Spool) reclaimLocked() error {
	if s.failErr != nil {
		return s.failErr
	}
	if s.seg == nil {
		return os.ErrClosed
	}
	if err := s.requireCurrentLayout(); err != nil {
		return err
	}
	if s.alloc != nil && s.alloc.Err() != nil {
		return s.alloc.Err()
	}
	// A previous publication may have completed before its cleanup did.
	if err := s.cleanupReclaimed(); err != nil {
		return s.stopReclaim(nil, err)
	}
	if s.alloc != nil {
		if err := s.chargeLane(); err != nil {
			return err
		}
	}
	if s.resolved <= s.baseSeq || s.resolved != s.nextSeq-1 {
		return nil
	}
	proof, eligible, err := s.acceptedProof()
	if err != nil || !eligible {
		return err
	}
	before, err := s.laneBytes()
	if err != nil {
		return err
	}
	var grant *RecoveryGrant
	if s.alloc != nil {
		grant, err = s.alloc.AcquireRecovery(s.dir)
		if errors.Is(err, ErrRecoveryConcurrencyExhausted) || errors.Is(err, ErrReserveUnbacked) {
			return nil // retain everything; the sender retries on its next pass
		}
		if err != nil {
			return err
		}
	}
	base := s.resolved
	name := dataName(base)
	checkpoint := make([]byte, checkpointSize)
	copy(checkpoint, "SRRECL01")
	binary.LittleEndian.PutUint64(checkpoint[8:], base)
	binary.LittleEndian.PutUint64(checkpoint[16:], s.nextGen)
	copy(checkpoint[24:], proof[:])
	sum := sha256.Sum256(checkpoint[:56])
	copy(checkpoint[56:], sum[:])
	path := filepath.Join(s.dir, name+checkpointSuffix)
	if grant == nil {
		err = durablefs.WriteFile(path, checkpoint, filePerm)
	} else {
		err = grant.WriteBarrier(ArtifactDestinationSegment, path, checkpoint)
	}
	if err != nil {
		return s.stopReclaim(grant, err)
	}
	publish := func() error { return s.publishReclaimed(name) }
	if grant == nil {
		err = publish()
	} else {
		err = grant.RunDestructive("publish reclaimed segment", publish)
	}
	if err != nil {
		return s.stopReclaim(grant, err)
	}
	if err := s.cross(barrierReclaimCleaned); err != nil {
		return s.stopReclaim(grant, err)
	}
	if grant != nil {
		return s.settleReclaim(grant, before)
	}
	return nil
}

func (s *Spool) publishReclaimed(name string) error {
	newDir := filepath.Join(s.dir, name)
	if err := durablefs.MkdirAll(newDir, dirPerm); err != nil {
		return err
	}
	// An interrupted prepare can leave this empty file behind. Never
	// truncate a nonempty file or follow a substituted symlink.
	newPath := filepath.Join(newDir, segmentFile)
	if info, err := os.Lstat(newPath); err == nil {
		if !info.Mode().IsRegular() || info.Size() != 0 {
			return fmt.Errorf("%w: nonempty reclaim destination", errReclaimState)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := durablefs.WriteFile(newPath, nil, filePerm); err != nil {
		return err
	}
	if err := s.cross(barrierReclaimPrepared); err != nil {
		return err
	}
	tmp := filepath.Join(s.dir, ".reclaim-pointer")
	if err := os.Remove(tmp); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Symlink(name, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, segmentFile)); err != nil {
		return err
	}
	if err := fsyncDir(s.dir); err != nil {
		return err
	}
	if err := s.cross(barrierReclaimPublished); err != nil {
		return err
	}
	if err := s.refreshLayout(); err != nil {
		return err
	}
	return s.cleanupReclaimed()
}

func (s *Spool) settleReclaim(grant *RecoveryGrant, before uint64) error {
	after, err := s.laneBytes()
	if err != nil {
		return s.stopReclaim(grant, err)
	}
	if err := grant.Finish(); err != nil {
		return s.stopReclaim(grant, err)
	}
	// The new checkpoint is charged to the grant, not to the old lane.
	removed := before - (after - checkpointSize)
	if err := grant.ReleaseSource(s.dir, removed); err != nil {
		return s.stopReclaim(grant, err)
	}
	if err := grant.ReleaseArtifacts(); err != nil {
		return s.stopReclaim(grant, err)
	}
	return s.chargeLane()
}

func (s *Spool) stopReclaim(grant *RecoveryGrant, err error) error {
	if grant != nil {
		err = grant.FailStop("reclaim", err)
	} else if s.alloc != nil {
		s.alloc.settle(0, err)
	}
	s.failErr = asFailStop(err)
	return s.failErr
}

func (s *Spool) acceptedProof() ([32]byte, bool, error) {
	var proof [32]byte
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return proof, false, err
	}
	next := s.baseSeq + 1
	hash := sha256.New()
	for _, entry := range entries { // ReadDir sorts the zero-padded watermarks.
		through, ok := terminalSequence(entry.Name())
		if !ok || through < next || through > s.resolved {
			continue
		}
		b, err := os.ReadFile(filepath.Join(s.dir, entry.Name()))
		if err != nil {
			return proof, false, err
		}
		var ack edgev1.EdgeDeliveryAckV1
		if proto.Unmarshal(b, &ack) != nil || ack.GetResolvedThroughSequence() != through {
			return proof, false, nil
		}
		for _, d := range ack.GetDispositions() {
			seq := d.GetSequence()
			if seq < next {
				continue
			}
			if seq != next || seq > through {
				return proof, false, nil
			}
			switch d.GetKind() {
			case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
				edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY,
				edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE:
			case edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED,
				edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT,
				edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE:
				return proof, false, nil
			default:
				return proof, false, nil
			}
			loc := s.slots[seq-s.baseSeq-1]
			if !loc.committed {
				return proof, false, nil
			}
			rec, err := readRecordAt(s.seg, loc)
			if err != nil {
				return proof, false, err
			}
			if rec.Sequence != seq || !bytes.Equal(rec.EventID, d.GetEventId()) {
				return proof, false, nil
			}
			next++
		}
		if next != through+1 {
			return proof, false, nil
		}
		_, _ = hash.Write(b)
	}
	copy(proof[:], hash.Sum(nil))
	return proof, next == s.nextSeq, nil
}

func terminalSequence(name string) (uint64, bool) {
	if len(name) != len("terminal-")+20+len(".pb") || !strings.HasPrefix(name, "terminal-") || !strings.HasSuffix(name, ".pb") {
		return 0, false
	}
	v, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimPrefix(name, "terminal-"), ".pb"), 10, 64)
	return v, err == nil && name == fmt.Sprintf("terminal-%020d.pb", v)
}

// Only directories older than the durable pointer are obsolete. A newer directory
// may belong to an in-progress preparation and is never removed by a reader.
func (s *Spool) cleanupReclaimed() error {
	if s.baseSeq == 0 {
		return nil
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		base, data := dataBase(e.Name())
		cpBase, cp := dataBase(strings.TrimSuffix(e.Name(), checkpointSuffix))
		seq, terminal := terminalSequence(e.Name())
		remove := (data && base < s.baseSeq) || (cp && strings.HasSuffix(e.Name(), checkpointSuffix) && cpBase < s.baseSeq) ||
			(terminal && seq <= s.baseSeq) || e.Name() == evidenceDirName(copyA) || e.Name() == evidenceDirName(copyB)
		if remove {
			if err := os.RemoveAll(filepath.Join(s.dir, e.Name())); err != nil {
				return err
			}
		}
	}
	if err := fsyncDir(s.dir); err != nil {
		return err
	}
	return nil
}

func (s *Spool) laneBytes() (uint64, error) {
	total, err := regularFileBytes(s.dir)
	if err != nil {
		return 0, err
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, err
	}
	for _, entry := range entries {
		_, data := dataBase(entry.Name())
		if !entry.IsDir() || (!data && entry.Name() != evidenceDirName(copyA) && entry.Name() != evidenceDirName(copyB)) {
			continue
		}
		dir := filepath.Join(s.dir, entry.Name())
		n, err := regularFileBytes(dir)
		if err != nil {
			return 0, err
		}
		total += n
		if data {
			for c := range evidenceCopies {
				n, err := regularFileBytes(filepath.Join(dir, evidenceDirName(c)))
				if err != nil && !errors.Is(err, os.ErrNotExist) {
					return 0, err
				}
				total += n
			}
		}
	}
	return total, nil
}
