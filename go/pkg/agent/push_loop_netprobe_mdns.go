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

package agent

import (
	"context"
	"fmt"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// mDNS is pushed as its OWN stream, separate from both the census and
// passive-netprobe.
//
// Core routes on the stream's service name and applies identity policy on each
// update's `source`, so a stream whose name disagrees with the updates inside
// works right up until something reads the wrong one. It also has to be
// separable at the routing layer for a different reason: mDNS is
// enrichment-only and must never create a device, while the census exists
// precisely to create them. Those cannot share a route.
func (p *PushLoop) pushNetprobeMdnsResults(ctx context.Context) bool {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	collectorIP := p.server.config.HostIP
	p.server.mu.RUnlock()

	if netprobeSidecar == nil {
		return false
	}

	snapshots := netprobeSidecar.DrainMdnsSnapshots(0)
	if len(snapshots) == 0 {
		return false
	}

	opts := agentnetprobe.TranslationOptions{
		AgentID:     agentID,
		GatewayID:   p.gateway.GetGatewayID(),
		CollectorIP: collectorIP,
	}

	source := string(models.DiscoverySourceNetprobeMdns)
	updates := make([]map[string]any, 0)
	var stats agentnetprobe.MdnsTranslationStats

	for _, snapshot := range snapshots {
		devices, snapshotStats := agentnetprobe.MdnsSnapshotToDiscoveredDevices(snapshot, opts)
		stats.Devices += snapshotStats.Devices
		stats.Emitted += snapshotStats.Emitted
		stats.SkippedNoMAC += snapshotStats.SkippedNoMAC
		stats.SkippedNoEvidence += snapshotStats.SkippedNoEvidence
		stats.Ambiguous += snapshotStats.Ambiguous
		stats.Truncated += snapshotStats.Truncated

		for _, device := range devices {
			// No "ip" key at all. mDNS identifies, it does not locate, and an
			// empty string here would read as a claim rather than an absence.
			updates = append(updates, map[string]any{
				"mac":        device.GetMac(),
				"agent_id":   agentID,
				"gateway_id": opts.GatewayID,
				"partition":  partition,
				"source":     source,
				"metadata":   device.GetMetadata(),
				"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
			})
		}
	}

	if len(updates) == 0 {
		p.logger.Debug().
			Int("snapshot_count", len(snapshots)).
			Int("device_count", stats.Devices).
			Int("skipped_no_evidence", stats.SkippedNoEvidence).
			Int("skipped_no_mac", stats.SkippedNoMAC).
			Msg("Netprobe mDNS produced no enrichment updates")

		return false
	}

	payloads, skippedUpdates, err := buildNetprobeResultsPayloads(
		updates,
		netprobeResultsPayloadMaxBytes,
		netprobeResultsStreamPayloadMaxBytes,
	)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal netprobe mDNS results")
		return false
	}
	if len(payloads) == 0 {
		if skippedUpdates > 0 {
			p.logger.Warn().
				Int("skipped_update_count", skippedUpdates).
				Msg("Skipped oversized netprobe mDNS updates")
		}

		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())
	chunks := make([]*proto.ResultsChunk, 0, len(payloads))
	for idx, payload := range payloads {
		response := mapperResultsResponse(payload, seq, source, source)
		chunks = append(chunks, &proto.ResultsChunk{
			Data:            response.Data,
			IsFinal:         idx == len(payloads)-1,
			ChunkIndex:      int32(idx),
			TotalChunks:     int32(len(payloads)),
			CurrentSequence: response.CurrentSequence,
			Timestamp:       response.Timestamp,
		})
	}

	statusChunks := p.buildResultsStatusChunks(chunks, source, source)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := p.gateway.StreamStatus(pushCtx, statusChunks); err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream netprobe mDNS results to gateway")
		return false
	}

	event := p.logger.Info()
	if skippedUpdates > 0 {
		event = p.logger.Warn().Int("skipped_update_count", skippedUpdates)
	}
	event.
		Int("snapshot_count", len(snapshots)).
		Int("device_count", stats.Devices).
		Int("emitted_count", stats.Emitted).
		Int("ambiguous_count", stats.Ambiguous).
		Int("truncated_count", stats.Truncated).
		Int("skipped_no_evidence", stats.SkippedNoEvidence).
		Int("status_chunk_count", len(statusChunks)).
		Msg("Streamed netprobe mDNS identification to gateway")

	return true
}
