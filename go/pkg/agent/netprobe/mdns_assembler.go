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

// mDNS-specific reassembly. Every rule that decides whether a set is complete,
// poisoned, expired or over-budget lives in chunkAssembler, shared with the
// census; only the concatenation is here, because only this file knows that
// mDNS carries its contents in `devices`.
type mdnsAssembler = chunkAssembler[netprobepb.MdnsSnapshot, *netprobepb.MdnsSnapshot]

func newMdnsAssembler() *mdnsAssembler {
	return newChunkAssembler[netprobepb.MdnsSnapshot](mergeMdnsChunks)
}

func mergeMdnsChunks(ordered []*netprobepb.MdnsSnapshot) *netprobepb.MdnsSnapshot {
	first := ordered[0]
	devices := make([]*netprobepb.MdnsDevice, 0)
	for _, chunk := range ordered {
		devices = append(devices, chunk.GetDevices()...)
	}

	return &netprobepb.MdnsSnapshot{
		Devices:             devices,
		SnapshotId:          first.GetSnapshotId(),
		InterfaceName:       first.GetInterfaceName(),
		GeneratedAtUnixNano: first.GetGeneratedAtUnixNano(),
		Complete:            true,
		ChunkIndex:          0,
		ChunkCount:          1,
		// Per-snapshot, replicated onto every chunk by the emitter. Taken from
		// one chunk; summing would multiply it by chunk_count.
		DroppedSinceLast: first.GetDroppedSinceLast(),
	}
}
