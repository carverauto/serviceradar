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

// UnresolvedHealth summarizes the records the sender has not yet resolved.
// Bytes is the sum of their bodies. The oldest age comes from UUIDv7 event ids:
// the first 48 bits are a Unix millisecond timestamp and the high nibble of
// byte 6 is version 7. reportAge is true when nothing is unresolved, and when at
// least one unresolved id is a version-7 timestamp. It is false when unresolved
// records exist and none of those ids carry that timestamp, so a caller does not
// publish a fresh age for an unknown clock.
//
// It reads only each record's header, never its body, so a metrics scrape of a
// large backlog costs one small read per record and constant memory. Like
// ScanFrom it takes the spool lock per record, so producer appends interleave.
func (s *Spool) UnresolvedHealth(now time.Time) (bytes uint64, oldest time.Duration, reportAge bool, err error) {
	s.mu.Lock()
	if s.seg == nil {
		s.mu.Unlock()
		return 0, 0, false, fmt.Errorf("spool: health: %w", os.ErrClosed)
	}
	seq := s.resolved
	s.mu.Unlock()

	var unresolved int
	var oldestMs int64
	var found bool
	header := make([]byte, headerLen+headerCRC)
	for {
		seq++
		s.mu.Lock()
		if s.seg == nil {
			s.mu.Unlock()
			return 0, 0, false, fmt.Errorf("spool: health: %w", os.ErrClosed)
		}
		seq = max(seq, s.resolved+1, s.baseSeq+1)
		if seq >= s.nextSeq {
			s.mu.Unlock()
			break
		}
		loc := s.slots[seq-s.baseSeq-1]
		if !loc.committed {
			s.mu.Unlock()
			continue
		}
		_, readErr := s.seg.ReadAt(header, loc.offset)
		s.mu.Unlock()
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				readErr = io.ErrUnexpectedEOF
			}
			return 0, 0, false, fmt.Errorf("spool: health: read header: %w", readErr)
		}
		h, ok := parseHeader(header)
		if !ok || h.seq != seq {
			return 0, 0, false, fmt.Errorf("%w: slot %d", ErrCorruptHeader, seq)
		}

		unresolved++
		bytes += uint64(h.bodyLen)
		if ms, ok := uuidV7UnixMilli(h.eventID[:]); ok && (!found || ms < oldestMs) {
			oldestMs = ms
			found = true
		}
	}

	if unresolved == 0 {
		return 0, 0, true, nil
	}
	if !found {
		return bytes, 0, false, nil
	}
	age := now.Sub(time.UnixMilli(oldestMs))
	if age < 0 {
		age = 0
	}
	return bytes, age, true, nil
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
