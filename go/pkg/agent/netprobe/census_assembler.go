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
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

// Census-specific reassembly. The rules live in chunkAssembler, shared with
// mDNS; only the concatenation differs, because only the caller knows which
// repeated field carries the contents.
//
// Reason constants are kept as aliases so existing callers and tests continue
// to name them by their census names.
const (
	CensusDropInvalidChunkIndex = ChunkDropInvalidChunkIndex
	CensusDropChunkCountChanged = ChunkDropChunkCountChanged
	CensusDropTooManyChunks     = ChunkDropTooManyChunks
	CensusDropPartialEvicted    = ChunkDropPartialEvicted
	CensusDropPartialExpired    = ChunkDropPartialExpired

	// Aliased for the same reason: the bound is shared, the name stays local.
	censusMaxPartialSets = chunkMaxPartialSets
	censusPartialTTL     = chunkPartialTTL
	censusMaxChunks      = chunkMaxChunks
)

type censusAssembler = chunkAssembler[netprobepb.DeviceCensusSnapshot, *netprobepb.DeviceCensusSnapshot]

func newCensusAssembler() *censusAssembler {
	return newChunkAssembler[netprobepb.DeviceCensusSnapshot](mergeCensusChunks)
}

// mergeCensusChunks concatenates a complete set in chunk order.
func mergeCensusChunks(ordered []*netprobepb.DeviceCensusSnapshot) *netprobepb.DeviceCensusSnapshot {
	first := ordered[0]
	observations := make([]*netprobepb.DeviceCensusObservation, 0)
	for _, chunk := range ordered {
		observations = append(observations, chunk.GetObservations()...)
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
		// snapshot, not the chunk. Take it from one -- summing would multiply
		// it by chunk_count.
		DroppedSinceLast: first.GetDroppedSinceLast(),
	}
}
