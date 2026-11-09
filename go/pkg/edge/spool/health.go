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
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

// MaxHealthGapSequences bounds diagnostic samples, never the total gap count.
const MaxHealthGapSequences = 32

// Health includes allocated gaps, which ScanFrom cannot deliver. Counts and byte
// totals are live samples; concurrent appends/resolution may interleave. An age
// is unknown when any gap has lost its timestamp. No record bodies are loaded.
type Health struct {
	UnresolvedCount     uint64
	UnresolvedBytes     uint64
	OldestUnresolvedAge time.Duration
	ReportAge           bool
	GapCount            uint64
	GapSequences        []uint64
}

// UnresolvedHealth summarizes the records the sender has not yet resolved.
// Bytes is the sum of their bodies. The oldest age comes from UUIDv7 event ids:
// the first 48 bits are a Unix millisecond timestamp and the high nibble of
// byte 6 is version 7. reportAge is true when nothing is unresolved, and when at
// least one unresolved id is a version-7 timestamp. It is false when unresolved
// records exist and none of those ids carry that timestamp, or a coverage gap
// has no trustworthy timestamp, so a caller does not
// publish a fresh age for an unknown clock.
//
// It reads only each record's header, never its body, so a metrics scrape of a
// large backlog costs one small read per record and constant memory. Like
// ScanFrom it takes the spool lock per record, so producer appends interleave.
func (s *Spool) UnresolvedHealth(now time.Time) (bytes uint64, oldest time.Duration, reportAge bool, err error) {
	h, err := s.Health(now)
	return h.UnresolvedBytes, h.OldestUnresolvedAge, h.ReportAge, err
}

// Health samples unresolved slots, including allocated slots requiring coverage.
func (s *Spool) Health(now time.Time) (Health, error) {
	var health Health
	s.mu.Lock()
	if s.seg == nil {
		s.mu.Unlock()
		return Health{}, fmt.Errorf("spool: health: %w", os.ErrClosed)
	}
	// Like ScanFrom, adopt a layout another handle reclaimed into, and below
	// discover records another handle appended, before trusting the index.
	if err := s.refreshLayout(); err != nil {
		s.mu.Unlock()
		return Health{}, err
	}
	seq := s.resolved
	s.mu.Unlock()

	var oldestMs int64
	var found bool
	header := make([]byte, headerLen+headerCRC)
	refreshed := false
	for {
		seq++
		s.mu.Lock()
		if s.seg == nil {
			s.mu.Unlock()
			return Health{}, fmt.Errorf("spool: health: %w", os.ErrClosed)
		}
		if seq >= s.nextSeq && !refreshed {
			refreshed = true
			if err := s.refreshLocked(); err != nil {
				s.mu.Unlock()
				return Health{}, err
			}
		}
		seq = max(seq, s.resolved+1, s.baseSeq+1)
		if seq >= s.nextSeq {
			s.mu.Unlock()
			break
		}
		loc := s.slots[seq-s.baseSeq-1]
		health.UnresolvedCount++
		if !loc.committed {
			health.GapCount++
			if len(health.GapSequences) < MaxHealthGapSequences {
				health.GapSequences = append(health.GapSequences, seq)
			}
			s.mu.Unlock()
			continue
		}
		_, readErr := s.seg.ReadAt(header, loc.offset)
		s.mu.Unlock()
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				readErr = io.ErrUnexpectedEOF
			}
			return Health{}, fmt.Errorf("spool: health: read header: %w", readErr)
		}
		h, ok := parseHeader(header)
		if !ok || h.seq != seq {
			return Health{}, fmt.Errorf("%w: slot %d", ErrCorruptHeader, seq)
		}

		health.UnresolvedBytes += uint64(h.bodyLen)
		if ms, ok := uuidV7UnixMilli(h.eventID[:]); ok && (!found || ms < oldestMs) {
			oldestMs = ms
			found = true
		}
	}

	if health.UnresolvedCount == 0 {
		health.ReportAge = true
		return health, nil
	}
	health.ReportAge = found && health.GapCount == 0
	if found {
		health.OldestUnresolvedAge = max(now.Sub(time.UnixMilli(oldestMs)), 0)
	}
	return health, nil
}

// CoverageGap returns restart evidence for a sequence without copying the full
// resolution. The sender uses this only after acknowledgement validation fails.
func (s *Spool) CoverageGap(sequence uint64) (SlotResolution, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.restart.Slot(sequence)
	return r, ok && sequence > s.resolved && r.EntersCoverage()
}

func uuidV7UnixMilli(id []byte) (int64, bool) {
	if len(id) != 16 || id[6]>>4 != 0x7 {
		return 0, false
	}
	ms := int64(id[0])<<40 |
		int64(id[1])<<32 |
		int64(id[2])<<24 |
		int64(id[3])<<16 |
		int64(id[4])<<8 |
		int64(id[5])
	return ms, true
}
