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

// The census is pushed as its OWN stream rather than folded into
// pushNetprobeResults, which labels its whole batch `passive-netprobe`.
//
// Core routes on the stream's service name and applies identity policy on each
// update's `source`. Mixing the two in one batch would have the router see
// `passive-netprobe` while the updates inside claim `netprobe-census` -- the
// kind of split that works until something downstream reads the wrong one.
//
// The separation also keeps snapshot semantics intact: this stream is a
// complete segment view that supersedes its predecessor, while the netprobe
// results stream is an accumulation of independent events.
func (p *PushLoop) pushNetprobeCensusResults(ctx context.Context) bool {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	collectorIP := p.server.config.HostIP
	p.server.mu.RUnlock()

	if netprobeSidecar == nil {
		return false
	}

	snapshots := netprobeSidecar.DrainCensusSnapshots(0)
	if len(snapshots) == 0 {
		return false
	}

	opts := agentnetprobe.TranslationOptions{
		AgentID:     agentID,
		GatewayID:   p.gateway.GetGatewayID(),
		CollectorIP: collectorIP,
	}

	source := string(models.DiscoverySourceNetprobeCensus)
	updates := make([]map[string]any, 0)
	var stats agentnetprobe.CensusTranslationStats

	for _, snapshot := range snapshots {
		devices, snapshotStats := agentnetprobe.CensusSnapshotToDiscoveredDevices(snapshot, opts)
		stats.Observations += snapshotStats.Observations
		stats.Devices += snapshotStats.Devices
		stats.SkippedNoMAC += snapshotStats.SkippedNoMAC
		stats.SkippedOffSegment += snapshotStats.SkippedOffSegment
		stats.RandomizedMAC += snapshotStats.RandomizedMAC
		stats.Addressless += snapshotStats.Addressless

		for _, device := range devices {
			update := map[string]any{
				"ip":         device.GetIp(),
				"mac":        device.GetMac(),
				"agent_id":   agentID,
				"gateway_id": opts.GatewayID,
				"partition":  partition,
				"source":     source,
				"metadata":   device.GetMetadata(),
				"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
			}
			updates = append(updates, update)
		}
	}

	if len(updates) == 0 {
		// A snapshot that translated to nothing is still worth saying out loud:
		// an empty segment and a segment whose every sighting was rejected look
		// identical from outside, and only one of them is fine.
		p.logger.Debug().
			Int("snapshot_count", len(snapshots)).
			Int("observation_count", stats.Observations).
			Int("skipped_off_segment", stats.SkippedOffSegment).
			Int("skipped_no_mac", stats.SkippedNoMAC).
			Msg("Netprobe census produced no device updates")

		return false
	}

	payloads, skippedUpdates, err := buildNetprobeResultsPayloads(
		updates,
		netprobeResultsPayloadMaxBytes,
		netprobeResultsStreamPayloadMaxBytes,
	)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal netprobe census results")
		return false
	}
	if len(payloads) == 0 {
		if skippedUpdates > 0 {
			p.logger.Warn().
				Int("skipped_update_count", skippedUpdates).
				Msg("Skipped oversized netprobe census updates")
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
		p.logger.Error().Err(err).Msg("Failed to stream netprobe census results to gateway")
		return false
	}

	event := p.logger.Info()
	if skippedUpdates > 0 {
		event = p.logger.Warn().Int("skipped_update_count", skippedUpdates)
	}
	event.
		Int("snapshot_count", len(snapshots)).
		Int("observation_count", stats.Observations).
		Int("device_count", stats.Devices).
		Int("randomized_mac_count", stats.RandomizedMAC).
		Int("addressless_count", stats.Addressless).
		Int("skipped_off_segment", stats.SkippedOffSegment).
		Int("skipped_no_mac", stats.SkippedNoMAC).
		Int("status_chunk_count", len(statusChunks)).
		Msg("Streamed netprobe device census to gateway")

	return true
}
