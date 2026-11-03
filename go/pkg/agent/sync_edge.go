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
	"encoding/json"
	"errors"
	"fmt"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

// Sync pages ride a standing-grant contract (serviceradar.sync.page.batch)
// through this producer. A page is one sendSyncUpdates call: its records
// keep the run's chunk numbering (baseChunkIndex onward), total_chunks is
// stamped only on the run-final page exactly as buildSyncMeta stamps it,
// and the population report rides only the final record, so the sync
// ingestion pipeline the projector feeds sees the same run shape it sees
// today. A spool refusal stops the page and returns the error, the same
// contract a failed legacy stream has with the run emitter.

var errSyncRecordTooLarge = errors.New("sync update exceeds the durable record body bound")

// SetEdgeSyncSpool connects the sync producer to the sender's one open
// spool and the push loop's output grants. Call before Start; a nil spool
// keeps sync pages on their legacy path.
func (p *PushLoop) SetEdgeSyncSpool(sp *spool.Spool) {
	if p.syncRuntime == nil {
		return
	}
	if sp == nil {
		p.syncRuntime.edgeSpool = nil
		return
	}
	p.syncRuntime.edgeSpool = sp
	p.syncRuntime.edgeGrants = &p.edgeOutputGrants
}

func (r *SyncRuntime) syncCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if r == nil || r.edgeSpool == nil || r.edgeGrants == nil {
		return nil
	}
	return r.edgeGrants.current(edgerecord.SyncPageContractID, now)
}

// spoolSyncUpdates is the durable form of sendSyncUpdates: it converts the
// page's updates and appends one record per packed chunk, returning how
// many chunks were appended. The first refusal stops the page.
func (r *SyncRuntime) spoolSyncUpdates(
	_ context.Context,
	updates []map[string]interface{},
	source models.SourceConfig,
	runID string,
	runTotalDevices int,
	baseChunkIndex int,
	runFinalPage bool,
	population *syncsources.PopulationStats,
	capability *edgev1.EdgeSignedCapabilityV1,
) (int, error) {
	deviceUpdateCount := 0
	for _, update := range updates {
		if update != nil && update[syncControlKey] != syncCollectionFinal {
			deviceUpdateCount++
		}
	}
	if runTotalDevices < deviceUpdateCount {
		runTotalDevices = deviceUpdateCount
	}

	meta := syncChunkMeta{
		syncServiceID:  source.SyncServiceID,
		runID:          runID,
		totalDevices:   runTotalDevices,
		baseChunkIndex: baseChunkIndex,
		runFinalPage:   runFinalPage,
		population:     population,
	}

	records, bodies, dropped, err := buildSyncPageRecords(meta, updates, capability)
	if dropped > 0 {
		r.server.edgeProducerDrops.record(edgeProducerSync, edgeDropInvalidRecord, dropped)
		r.logger.Warn().Int("count", dropped).
			Msg("Dropped sync updates that cannot form an edge record")
	}
	if err != nil {
		return 0, err
	}

	appended := 0
	var appendErr error
	for i, record := range records {
		if _, err := r.edgeSpool.AppendFlow(edgeAdmissionFlow(record), record.GetEventId(), bodies[i]); err != nil {
			appendErr = fmt.Errorf("spool sync page chunk %d: %w", i, err)
			break
		}
		appended++
	}
	if appended > 0 {
		r.edgeRuns.Store(runID, struct{}{})
	}
	return appended, appendErr
}

// buildSyncPageRecords packs a page into records. Group boundaries are
// sized with a worst-case sync meta (final, population attached, the
// largest total the page could stamp), so the records rebuilt with the
// real per-chunk meta never outgrow the bound their group was sized under.
func buildSyncPageRecords(
	meta syncChunkMeta,
	updates []map[string]interface{},
	capability *edgev1.EdgeSignedCapabilityV1,
) (records []*edgev1.EdgeRecordV1, bodies [][]byte, dropped int, err error) {
	var marker *edgev1.SyncControlMarkerV1
	devices := make([]*edgev1.SyncDeviceRecordV1, 0, len(updates))
	for _, update := range updates {
		if update == nil {
			continue
		}
		if update[syncControlKey] == syncCollectionFinal {
			marker = &edgev1.SyncControlMarkerV1{
				ControlType:       syncCollectionFinal,
				TimestampUnixNano: payloadTimeNano(update, "timestamp"),
			}
			continue
		}
		devices = append(devices, syncDeviceRecord(normalizeSyncUpdate(update)))
	}

	maxRows := syncMaxRows(capability)
	sizingMeta := syncMetaRecord(meta, meta.baseChunkIndex, meta.baseChunkIndex+len(updates), true)

	groups, dropped, err := packSyncGroups(sizingMeta, marker, devices, capability, maxRows)
	if err != nil {
		return nil, nil, dropped, err
	}

	totalChunks := syncMetaTotalChunks(meta, len(groups))
	for idx, group := range groups {
		isFinal := meta.runFinalPage && idx == len(groups)-1
		batch := &edgev1.SyncPageBatchV1{
			SyncMeta: syncMetaRecord(meta, meta.baseChunkIndex+idx, totalChunks, isFinal),
			Devices:  group,
		}
		if idx == len(groups)-1 {
			batch.ControlMarker = marker
		}
		record, body, _, buildErr := edgeBatchRecord(
			batch, capability, edgerecord.SyncPageRows(batch), maxRows,
			edgerecord.SyncPageProjectedWriteBytesPerRecord, errSyncRecordTooLarge,
			edgerecord.ValidateSyncPageRecord)
		if buildErr != nil {
			return nil, nil, dropped, buildErr
		}
		records = append(records, record)
		bodies = append(bodies, body)
	}
	return records, bodies, dropped, nil
}

// packSyncGroups splits devices into record-sized groups under the sizing
// meta. A head device that cannot form a valid record alone is dropped and
// counted; a semantic refusal stops the page.
func packSyncGroups(
	sizingMeta *edgev1.SyncMetaV1,
	marker *edgev1.SyncControlMarkerV1,
	devices []*edgev1.SyncDeviceRecordV1,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (groups [][]*edgev1.SyncDeviceRecordV1, dropped int, err error) {
	if len(devices) == 0 {
		if marker != nil {
			return [][]*edgev1.SyncDeviceRecordV1{nil}, 0, nil
		}
		return nil, 0, nil
	}
	remaining := devices
	for len(remaining) > 0 {
		n, packErr := longestSyncPrefix(sizingMeta, remaining, capability, maxRows)
		if packErr != nil {
			return nil, dropped + len(remaining), packErr
		}
		if n == 0 {
			dropped++
			remaining = remaining[1:]
			continue
		}
		groups = append(groups, remaining[:n])
		remaining = remaining[n:]
	}
	return groups, dropped, nil
}

func longestSyncPrefix(
	sizingMeta *edgev1.SyncMetaV1,
	devices []*edgev1.SyncDeviceRecordV1,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (int, error) {
	limit := len(devices)
	if uint64(limit) > maxRows {
		limit = int(maxRows)
	}
	best := 0
	var lastErr error
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		batch := &edgev1.SyncPageBatchV1{SyncMeta: sizingMeta, Devices: devices[:mid]}
		_, _, _, err := edgeBatchRecord(
			batch, capability, mid, maxRows,
			edgerecord.SyncPageProjectedWriteBytesPerRecord, errSyncRecordTooLarge,
			edgerecord.ValidateSyncPageRecord)
		if err == nil {
			best = mid
			lo = mid + 1
			continue
		}
		lastErr = err
		hi = mid - 1
	}
	if best == 0 && lastErr != nil && !syncHeadMiss(lastErr) {
		return 0, lastErr
	}
	return best, nil
}

func syncHeadMiss(err error) bool {
	return errors.Is(err, errSyncRecordTooLarge) ||
		errors.Is(err, edgerecord.ErrRecordTooLarge) ||
		errors.Is(err, edgerecord.ErrPayloadTooLarge)
}

func syncMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.SyncPageProjectedWriteBytesPerRecord)
}

// normalizeSyncUpdate returns the JSON form of a normalized update map, so
// typed values a driver emitted (OCSF structs, ints) convert exactly as
// the legacy chunk marshal would have written them.
func normalizeSyncUpdate(update map[string]interface{}) map[string]interface{} {
	data, err := json.Marshal(update)
	if err != nil {
		return update
	}
	decoded := decodePluginPayloadMap(data)
	// sync_meta is stamped by the page, never carried per device.
	delete(decoded, syncMetaKey)
	return decoded
}
