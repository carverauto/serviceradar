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

package netprobe

import (
	"sort"
	"sync"
	"time"
)

// Chunk reassembly, shared by every chunked netprobe snapshot.
//
// Generic rather than copied per payload type. The rules below are small but
// unobvious -- a set completes only on count AND flag, a changed chunk_count
// poisons the set, the partial map is bounded three ways -- and each was
// written in response to a specific way reassembly can go wrong. Duplicating
// them per payload would mean fixing the next bug in one place and not the
// other.
//
// Reassembly happens in the agent rather than core because core's device
// ingestor writes nothing for a payload that does not declare itself complete,
// so forwarding chunks would cost a round trip to land zero rows.
const (
	// Partial sets older than this are abandoned. A netprobe that dies
	// mid-snapshot leaves chunks nothing will ever complete.
	chunkPartialTTL = 5 * time.Minute

	// Upper bound on concurrent partial sets, so a malformed or hostile stream
	// cannot grow the map without limit.
	chunkMaxPartialSets = 8

	// Refuse a set claiming more chunks than any real snapshot needs, so one
	// corrupt header cannot reserve a huge map.
	chunkMaxChunks = 4096
)

// Reasons a chunk did not produce a snapshot, reported for metrics/logging.
const (
	ChunkDropInvalidChunkIndex = "invalid_chunk_index"
	ChunkDropChunkCountChanged = "chunk_count_changed"
	ChunkDropTooManyChunks     = "too_many_chunks"
	ChunkDropPartialEvicted    = "partial_evicted"
	ChunkDropPartialExpired    = "partial_expired"
)

// chunkedSnapshot is the shape every chunked netprobe payload already has,
// courtesy of the generated proto getters.
type chunkedSnapshot[T any] interface {
	*T
	GetSnapshotId() string
	GetChunkIndex() uint32
	GetChunkCount() uint32
	GetComplete() bool
}

type chunkPartial[P any] struct {
	chunks      map[uint32]P
	chunkCount  uint32
	sawComplete bool
	firstSeen   time.Time
}

// chunkAssembler reassembles chunked frames into whole snapshots.
//
// Chunks are keyed by snapshot_id. netprobe seeds that id with its process
// start time precisely so this map cannot merge chunks from two different
// snapshots after a restart.
type chunkAssembler[T any, P chunkedSnapshot[T]] struct {
	mu       sync.Mutex
	partials map[string]*chunkPartial[P]

	// Concatenates a complete set, in chunk order, into one snapshot. Supplied
	// per payload because only the caller knows which repeated field carries
	// the contents.
	merge func(ordered []P) P

	// Injected so tests can drive expiry deterministically instead of sleeping.
	now func() time.Time

	dropped map[string]uint64
}

func newChunkAssembler[T any, P chunkedSnapshot[T]](merge func(ordered []P) P) *chunkAssembler[T, P] {
	return &chunkAssembler[T, P]{
		partials: make(map[string]*chunkPartial[P]),
		merge:    merge,
		now:      time.Now,
		dropped:  make(map[string]uint64),
	}
}

// Offer feeds one chunk in. It returns the assembled snapshot once the set is
// complete, and nil while the set is still incomplete or the chunk was
// rejected. The reason is empty unless something was dropped.
func (a *chunkAssembler[T, P]) Offer(chunk P) (snapshot P, reason string) {
	var zero P
	if chunk == nil {
		return zero, ""
	}

	// Fast path: an unchunked snapshot needs no buffering at all. This is the
	// overwhelmingly common case -- a segment has to be large before one
	// snapshot exceeds the frame limit.
	if chunk.GetChunkCount() <= 1 && chunk.GetComplete() {
		return chunk, ""
	}

	if chunk.GetChunkCount() > chunkMaxChunks {
		return zero, ChunkDropTooManyChunks
	}
	if chunk.GetChunkIndex() >= chunk.GetChunkCount() {
		// Includes chunk_count == 0: a chunk not marked complete that claims no
		// set it belongs to cannot be placed.
		return zero, ChunkDropInvalidChunkIndex
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now()
	a.expireLocked(now)

	id := chunk.GetSnapshotId()
	partial, ok := a.partials[id]
	if !ok {
		if evicted := a.evictIfFullLocked(); evicted != "" {
			reason = evicted
		}
		partial = &chunkPartial[P]{
			chunks:     make(map[uint32]P),
			chunkCount: chunk.GetChunkCount(),
			firstSeen:  now,
		}
		a.partials[id] = partial
	}

	if partial.chunkCount != chunk.GetChunkCount() {
		// Two different snapshots claiming one id, or a corrupted header.
		// Either way the set can no longer be trusted: a merged snapshot would
		// report devices present or absent from fragments of two different
		// observations, which is worse than reporting nothing.
		delete(a.partials, id)
		a.dropped[ChunkDropChunkCountChanged]++

		return zero, ChunkDropChunkCountChanged
	}

	// A repeated index overwrites: redelivery is idempotent, not an error.
	partial.chunks[chunk.GetChunkIndex()] = chunk
	if chunk.GetComplete() {
		partial.sawComplete = true
	}

	// Both conditions required. Counting chunks alone accepts a set whose final
	// chunk never arrived but which received a duplicate instead; the complete
	// flag alone accepts a set missing a middle chunk.
	if uint32(len(partial.chunks)) != partial.chunkCount || !partial.sawComplete {
		return zero, reason
	}

	delete(a.partials, id)

	indices := make([]uint32, 0, len(partial.chunks))
	for index := range partial.chunks {
		indices = append(indices, index)
	}
	sort.Slice(indices, func(i, j int) bool { return indices[i] < indices[j] })

	ordered := make([]P, 0, len(indices))
	for _, index := range indices {
		ordered = append(ordered, partial.chunks[index])
	}

	return a.merge(ordered), reason
}

func (a *chunkAssembler[T, P]) expireLocked(now time.Time) {
	for id, partial := range a.partials {
		if now.Sub(partial.firstSeen) >= chunkPartialTTL {
			delete(a.partials, id)
			a.dropped[ChunkDropPartialExpired]++
		}
	}
}

// evictIfFullLocked drops the oldest partial set to make room.
func (a *chunkAssembler[T, P]) evictIfFullLocked() string {
	if len(a.partials) < chunkMaxPartialSets {
		return ""
	}

	var (
		oldestID string
		oldest   time.Time
	)
	for id, partial := range a.partials {
		if oldestID == "" || partial.firstSeen.Before(oldest) {
			oldestID, oldest = id, partial.firstSeen
		}
	}
	delete(a.partials, oldestID)
	a.dropped[ChunkDropPartialEvicted]++

	return ChunkDropPartialEvicted
}

// DroppedChunks reports how many chunk sets were abandoned, by reason.
func (a *chunkAssembler[T, P]) DroppedChunks() map[string]uint64 {
	a.mu.Lock()
	defer a.mu.Unlock()

	out := make(map[string]uint64, len(a.dropped))
	for reason, count := range a.dropped {
		out[reason] = count
	}

	return out
}

// pendingSets reports how many partial sets are buffered. Test-facing.
func (a *chunkAssembler[T, P]) pendingSets() int {
	a.mu.Lock()
	defer a.mu.Unlock()

	return len(a.partials)
}
