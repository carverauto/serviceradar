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

// Local quarantine of permanently rejected records.
//
// A record the gateway rejects permanently is inside the resolved prefix: no retry
// can deliver it. Reclaim is all-or-nothing on the lane's segment, so keeping that
// record in the segment kept the whole segment forever, and a spool shared by every
// producer stopped reclaiming, filled, and refused them all. Reclaim therefore
// copies each permanently rejected record into a bounded local quarantine, makes
// the copy durable, and only then checkpoints past the segment.
//
// Entries live directly in the lane directory, named
// quarantine-<sequence:020d>-<event id hex>.pb, so name order is sequence order and
// an entry is found again by name after a crash. Each holds:
//
//	"SRQR0001" | u32 LE disposition length | the gateway's disposition (protobuf)
//	| the record exactly as the segment stored it | SHA-256 of everything before
//
// The bound is quarantineMaxRecords entries and quarantineMaxBytes bytes. Newer
// rejections displace older ones: the oldest entries are evicted, and a rejection
// that cannot fit is dropped without a copy. Both are counted (QuarantineHealth),
// never silent.
//
// Accounting. Entries are written during reclaim, under the reclaim's recovery
// grant, as destination-segment artifacts like the reclaim checkpoint. They are
// never admitted as ordinary producer data, so a spool at its ordinary ceiling can
// still quarantine and reclaim. A reclaim writes no more than the grant's remaining
// destination-segment budget (less the checkpoint it still has to write), so
// quarantine can never exhaust the reserve and fail-stop the allocator; what does
// not fit is dropped and counted. Once the reclaim releases its source, the entries
// move into the lane's ordinary charge, which every later chargeLane measures, so
// quarantined bytes occupy at most quarantineMaxBytes of the ordinary budget.

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
)

const (
	quarantinePrefix = "quarantine-"
	quarantineSuffix = ".pb"
	quarantineMagic  = "SRQR0001"

	// quarantineMaxRecords and quarantineMaxBytes bound the entries a lane keeps.
	quarantineMaxRecords = 1024
	quarantineMaxBytes   = 4 << 20

	quarantineNameLen = len(quarantinePrefix) + 20 + 1 + 32 + len(quarantineSuffix)
)

// QuarantineHealth reports the lane's quarantine. Records and Bytes are what is on
// disk now. The counters cover what this handle has done since it was opened:
// Quarantined permanently rejected records it copied into quarantine, Evicted
// entries it removed to admit newer ones, and Dropped permanently rejected records
// it reclaimed without a copy because the quarantine bound or the reclaim's reserve
// could not hold them.
type QuarantineHealth struct {
	Records     int
	Bytes       uint64
	Quarantined uint64
	Evicted     uint64
	Dropped     uint64
}

// permanentSlot is a permanently rejected record reclaim must quarantine.
type permanentSlot struct {
	seq         uint64
	eventID     []byte
	loc         slotLoc
	disposition []byte
}

type quarantineEntry struct {
	name string
	seq  uint64
	size uint64
}

func quarantineName(seq uint64, eventID []byte) string {
	return fmt.Sprintf("%s%020d-%s%s", quarantinePrefix, seq, hex.EncodeToString(eventID), quarantineSuffix)
}

func quarantineSequence(name string) (uint64, bool) {
	if len(name) != quarantineNameLen || !strings.HasPrefix(name, quarantinePrefix) || !strings.HasSuffix(name, quarantineSuffix) {
		return 0, false
	}
	digits := name[len(quarantinePrefix) : len(quarantinePrefix)+20]
	seq, err := strconv.ParseUint(digits, 10, 64)
	if err != nil {
		return 0, false
	}
	id, err := hex.DecodeString(name[len(quarantinePrefix)+21 : len(name)-len(quarantineSuffix)])
	if err != nil || name != quarantineName(seq, id) {
		return 0, false
	}
	return seq, true
}

// quarantineEntries lists the lane's entries, oldest first.
func (s *Spool) quarantineEntries() ([]quarantineEntry, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	var out []quarantineEntry
	for _, e := range entries {
		seq, ok := quarantineSequence(e.Name())
		if !ok || !e.Type().IsRegular() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			return nil, err
		}
		out = append(out, quarantineEntry{name: e.Name(), seq: seq, size: uint64(info.Size())})
	}
	return out, nil
}

// removeQuarantineTemps deletes the temporary file an interrupted entry write left.
func (s *Spool) removeQuarantineTemps() error {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	removed := false
	for _, e := range entries {
		name := e.Name()
		for _, tmp := range []string{".tmp", ".new"} {
			if _, ok := quarantineSequence(strings.TrimSuffix(name, tmp)); ok && strings.HasSuffix(name, tmp) {
				if err := os.Remove(filepath.Join(s.dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
					return err
				}
				removed = true
			}
		}
	}
	if removed {
		return fsyncDir(s.dir)
	}
	return nil
}

func quarantineSize(p permanentSlot) uint64 {
	return uint64(len(quarantineMagic)+4+len(p.disposition)) + uint64(p.loc.length) + sha256.Size
}

// quarantine makes every permanently rejected record of a reclaim durable in the
// lane's quarantine, within its bound and the grant's remaining reserve, evicting
// the oldest entries for newer ones. It returns the bytes it wrote, which the grant
// holds until the reclaim releases its source.
func (s *Spool) quarantine(grant *RecoveryGrant, permanent []permanentSlot) (uint64, error) {
	if len(permanent) == 0 {
		return 0, nil
	}
	existing, err := s.quarantineEntries()
	if err != nil {
		return 0, err
	}
	budget := uint64(math.MaxUint64)
	if grant != nil {
		budget = 0
		if left := grant.Remaining(ArtifactDestinationSegment); left > checkpointSize {
			budget = left - checkpointSize
		}
	}

	type item struct {
		seq      uint64
		size     uint64
		existing string
		slot     *permanentSlot
	}
	have := make(map[string]bool, len(existing))
	items := make([]item, 0, len(existing)+len(permanent))
	for _, e := range existing {
		have[e.name] = true
		items = append(items, item{seq: e.seq, size: e.size, existing: e.name})
	}
	for i := range permanent {
		// An entry an interrupted reclaim already made durable is not written twice.
		if !have[quarantineName(permanent[i].seq, permanent[i].eventID)] {
			items = append(items, item{seq: permanent[i].seq, size: quarantineSize(permanent[i]), slot: &permanent[i]})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].seq > items[j].seq })

	var kept int
	var keptBytes, written uint64
	var evict []string
	var write []*permanentSlot
	var dropped uint64
	for _, it := range items {
		fits := kept < quarantineMaxRecords && keptBytes+it.size <= quarantineMaxBytes
		if it.slot != nil && written+it.size > budget {
			fits = false
		}
		switch {
		case fits:
			kept++
			keptBytes += it.size
			if it.slot != nil {
				written += it.size
				write = append(write, it.slot)
			}
		case it.slot == nil:
			evict = append(evict, it.existing)
		default:
			dropped++
		}
	}

	if len(evict) > 0 {
		remove := func() error {
			for _, name := range evict {
				if err := os.Remove(filepath.Join(s.dir, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
					return err
				}
			}
			return fsyncDir(s.dir)
		}
		if grant == nil {
			err = remove()
		} else {
			err = grant.RunDestructive("evict quarantined records", remove)
		}
		if err != nil {
			return 0, err
		}
	}
	for _, p := range write {
		data, err := s.quarantineBytes(*p)
		if err != nil {
			return 0, err
		}
		path := filepath.Join(s.dir, quarantineName(p.seq, p.eventID))
		if grant == nil {
			err = durablefs.WriteFile(path, data, filePerm)
		} else {
			err = grant.WriteBarrier(ArtifactDestinationSegment, path, data)
		}
		if err != nil {
			return 0, err
		}
	}
	s.quarantined += uint64(len(write))
	s.quarantineEvicted += uint64(len(evict))
	s.quarantineDropped += dropped
	return written, nil
}

func (s *Spool) quarantineBytes(p permanentSlot) ([]byte, error) {
	frame := make([]byte, p.loc.length)
	if _, err := s.seg.ReadAt(frame, p.loc.offset); err != nil {
		return nil, fmt.Errorf("spool: read rejected record %d: %w", p.seq, err)
	}
	data := make([]byte, 0, quarantineSize(p))
	data = append(data, quarantineMagic...)
	data = binary.LittleEndian.AppendUint32(data, uint32(len(p.disposition)))
	data = append(data, p.disposition...)
	data = append(data, frame...)
	sum := sha256.Sum256(data)
	return append(data, sum[:]...), nil
}

// QuarantineHealth reports the lane's quarantine. It lists entry names and sizes
// only; it never reads an entry.
func (s *Spool) QuarantineHealth() (QuarantineHealth, error) {
	s.mu.Lock()
	h := QuarantineHealth{Quarantined: s.quarantined, Evicted: s.quarantineEvicted, Dropped: s.quarantineDropped}
	s.mu.Unlock()
	entries, err := s.quarantineEntries()
	if err != nil {
		return QuarantineHealth{}, fmt.Errorf("spool: quarantine health: %w", err)
	}
	h.Records = len(entries)
	for _, e := range entries {
		h.Bytes += e.size
	}
	return h, nil
}
