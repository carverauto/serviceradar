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

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

// Reassembly happens HERE, in the agent, rather than in core.
//
// Core's device-observation ingestor writes nothing unless a payload declares
// itself a complete snapshot, so forwarding individual chunks upstream would
// land zero rows. The agent also re-chunks by size for gRPC on its own terms,
// so it repackages the payload regardless -- reassembling first means it
// repackages a coherent snapshot instead of a fragment.
const (
	// Partial sets older than this are abandoned. A netprobe that dies
	// mid-snapshot leaves chunks nothing will ever complete; without a TTL they
	// would sit in the map until the process restarts.
	censusPartialTTL = 5 * time.Minute

	// Upper bound on concurrent partial sets. netprobe publishes one snapshot
	// per interface at a time, so anything beyond a handful means chunks are
	// arriving for sets that will never complete. Bounded so a malformed or
	// hostile stream cannot grow the map without limit.
	censusMaxPartialSets = 8

	// Refuse a set claiming more chunks than any real snapshot needs. At the
	// 4 MiB frame limit this is far more than a segment can produce, and it
	// stops a single corrupt header from reserving a huge map.
	censusMaxChunks = 4096
)

// Reasons a chunk did not produce a snapshot, reported for metrics/logging.
const (
	CensusDropInvalidChunkIndex = "invalid_chunk_index"
	CensusDropChunkCountChanged = "chunk_count_changed"
	CensusDropTooManyChunks     = "too_many_chunks"
	CensusDropPartialEvicted    = "partial_evicted"
	CensusDropPartialExpired    = "partial_expired"
)

// censusPartial is one in-flight chunk set.
type censusPartial struct {
	chunks      map[uint32]*netprobepb.DeviceCensusSnapshot
	chunkCount  uint32
	sawComplete bool
	firstSeen   time.Time
}

// censusAssembler reassembles chunked DeviceCensusSnapshot frames into whole
// snapshots.
//
// Chunks are keyed by snapshot_id. netprobe seeds that id with its process
// start time precisely so this map cannot merge chunks from two different
// snapshots after a restart.
type censusAssembler struct {
	mu       sync.Mutex
	partials map[string]*censusPartial

	// Injected so tests can drive expiry deterministically instead of sleeping.
	now func() time.Time

	dropped map[string]uint64
}

func newCensusAssembler() *censusAssembler {
	return &censusAssembler{
		partials: make(map[string]*censusPartial),
		now:      time.Now,
		dropped:  make(map[string]uint64),
	}
}

// Offer feeds one chunk in. It returns the assembled snapshot once the set is
// complete, and nil while the set is still incomplete or the chunk was
// rejected. The reason is empty unless something was dropped.
func (a *censusAssembler) Offer(chunk *netprobepb.DeviceCensusSnapshot) (snapshot *netprobepb.DeviceCensusSnapshot, reason string) {
	if chunk == nil {
		return nil, ""
	}

	// Fast path: an unchunked snapshot needs no buffering at all. This is the
	// overwhelmingly common case -- a segment has to be very large before one
	// snapshot exceeds the frame limit.
	if chunk.GetChunkCount() <= 1 && chunk.GetComplete() {
		return chunk, ""
	}

	if chunk.GetChunkCount() > censusMaxChunks {
		return nil, CensusDropTooManyChunks
	}
	if chunk.GetChunkIndex() >= chunk.GetChunkCount() {
		// Includes the chunk_count==0 case: a chunk that is not marked complete
		// and claims no set it belongs to cannot be placed.
		return nil, CensusDropInvalidChunkIndex
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
		partial = &censusPartial{
			chunks:     make(map[uint32]*netprobepb.DeviceCensusSnapshot),
			chunkCount: chunk.GetChunkCount(),
			firstSeen:  now,
		}
		a.partials[id] = partial
	}

	if partial.chunkCount != chunk.GetChunkCount() {
		// Two different snapshots are claiming the same id, or a chunk was
		// corrupted. Either way the set can no longer be trusted: applying a
		// merged snapshot would report devices as present or absent based on
		// fragments of two different observations.
		delete(a.partials, id)
		a.dropped[CensusDropChunkCountChanged]++

		return nil, CensusDropChunkCountChanged
	}

	// A repeated chunk_index overwrites: redelivery is idempotent, not an error.
	partial.chunks[chunk.GetChunkIndex()] = chunk
	if chunk.GetComplete() {
		partial.sawComplete = true
	}

	// Both conditions are required. Counting chunks alone would accept a set
	// whose final chunk never arrived but which received a duplicate instead;
	// the complete flag alone would accept a set missing a middle chunk.
	if uint32(len(partial.chunks)) != partial.chunkCount || !partial.sawComplete {
		return nil, reason
	}

	delete(a.partials, id)

	return assemble(partial), reason
}

// assemble concatenates a complete set in chunk order.
func assemble(partial *censusPartial) *netprobepb.DeviceCensusSnapshot {
	indices := make([]uint32, 0, len(partial.chunks))
	for index := range partial.chunks {
		indices = append(indices, index)
	}
	sort.Slice(indices, func(i, j int) bool { return indices[i] < indices[j] })

	first := partial.chunks[indices[0]]
	observations := make([]*netprobepb.DeviceCensusObservation, 0)
	for _, index := range indices {
		observations = append(observations, partial.chunks[index].GetObservations()...)
	}

	return &netprobepb.DeviceCensusSnapshot{
		Observations:        observations,
		SnapshotId:          first.GetSnapshotId(),
		InterfaceName:       first.GetInterfaceName(),
		GeneratedAtUnixNano: first.GetGeneratedAtUnixNano(),
		Complete:            true,
		ChunkIndex:          0,
		ChunkCount:          1,
		// Replicated onto every chunk by the emitter because it describes the
		// snapshot, not the chunk. Take it from one chunk -- summing would
		// multiply it by chunk_count.
		DroppedSinceLast: first.GetDroppedSinceLast(),
	}
}

func (a *censusAssembler) expireLocked(now time.Time) {
	for id, partial := range a.partials {
		if now.Sub(partial.firstSeen) >= censusPartialTTL {
			delete(a.partials, id)
			a.dropped[CensusDropPartialExpired]++
		}
	}
}

// evictIfFullLocked drops the oldest partial set to make room. Returns the drop
// reason when something was evicted.
func (a *censusAssembler) evictIfFullLocked() string {
	if len(a.partials) < censusMaxPartialSets {
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
	a.dropped[CensusDropPartialEvicted]++

	return CensusDropPartialEvicted
}

// DroppedCensusChunks reports how many chunk sets were abandoned, by reason.
func (a *censusAssembler) DroppedCensusChunks() map[string]uint64 {
	a.mu.Lock()
	defer a.mu.Unlock()

	out := make(map[string]uint64, len(a.dropped))
	for reason, count := range a.dropped {
		out[reason] = count
	}

	return out
}

// pendingSets reports how many partial sets are buffered. Test-facing.
func (a *censusAssembler) pendingSets() int {
	a.mu.Lock()
	defer a.mu.Unlock()

	return len(a.partials)
}
