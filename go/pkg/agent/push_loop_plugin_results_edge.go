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
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// Wasm plugin results ride one standing-grant contract
// (serviceradar.plugin_results.batch) through this producer. Results are
// grouped by their host-stamped provenance into one batch per assignment run
// set; the provenance comes from the host's assignment record and loaded
// module bytes, never from the guest payload, so core can key the result to
// its assignment's own service identity. A result stays queued until the
// spool has admitted every part that formed a valid record, or the legacy
// status path has carried it; built parts keep the event ids they were first
// built with across spool retries.

const (
	// maxEdgePluginQueuedResults bounds the plugin-results retry queue, in
	// results across its queued batches. A batch already admitted (the head,
	// or the only pending item) is kept when it alone exceeds the bound; the
	// bound drops the oldest backlog behind that batch.
	maxEdgePluginQueuedResults = 8192
	// edgePluginResultsMaxPayloadBytes caps one spooled batch part, like a
	// telemetry batch record body.
	edgePluginResultsMaxPayloadBytes = edgeMetricsMaxPayloadBytes
)

var errPluginResultTooLarge = errors.New("plugin result exceeds the durable record body bound")

// SetEdgePluginResultSpool connects the plugin-results producer to the
// sender's one open spool. Call before Start; a nil spool keeps plugin
// results on their legacy path.
func (p *PushLoop) SetEdgePluginResultSpool(sp *spool.Spool) {
	if sp == nil {
		p.edgePluginResultSpool = nil
		return
	}
	p.edgePluginResultSpool = sp
}

// edgePluginResultsCapability is the current standing grant for the plugin
// results batch contract, or nil when plugin results ride their legacy path
// this cycle.
func (p *PushLoop) edgePluginResultsCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgePluginResultSpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.PluginResultsContractID, now)
}

// pluginResultEdgeItem is one provenance group of drained plugin results
// awaiting the spool. It retains the host results it came from so an item the
// spool has admitted no part of can still ride the legacy status path exactly
// as drained.
type pluginResultEdgeItem struct {
	provenance  *edgev1.PluginResultProvenanceV1
	serviceName string
	results     []PluginResult
}

func (item pluginResultEdgeItem) count() int { return len(item.results) }

// pluginResultBuiltItem is one item expanded into its spooled parts.
type pluginResultBuiltItem struct {
	item    pluginResultEdgeItem
	records []*edgev1.EdgeRecordV1
	bodies  [][]byte
	next    int
}

// pluginResultEdgeQueue is the plugin-results bounded retry queue. Only the
// push loop goroutine touches it.
type pluginResultEdgeQueue struct {
	pending []pluginResultEdgeItem
	built   *pluginResultBuiltItem
}

func (q *pluginResultEdgeQueue) queuedResults() int {
	total := 0
	for _, item := range q.pending {
		total += item.count()
	}
	if q.built != nil {
		total += q.built.item.count()
	}
	return total
}

// enqueue adds fresh items behind anything already queued, dropping the
// oldest backlog past the bound. The head item is never dropped for exceeding
// the bound on its own. It returns how many results the bound dropped.
func (q *pluginResultEdgeQueue) enqueue(items []pluginResultEdgeItem) (dropped int) {
	q.pending = append(q.pending, items...)
	for q.queuedResults() > maxEdgePluginQueuedResults && len(q.pending) > 1 {
		dropped += q.pending[0].count()
		q.pending = q.pending[1:]
	}
	return dropped
}

// take returns the queued items the legacy path may carry: the built item
// only when the spool has admitted no part of it, then pending items oldest
// first.
func (q *pluginResultEdgeQueue) take() []pluginResultEdgeItem {
	items := make([]pluginResultEdgeItem, 0, len(q.pending)+1)
	if q.built != nil && q.built.next == 0 {
		items = append(items, q.built.item)
		q.built = nil
	}
	items = append(items, q.pending...)
	q.pending = nil
	return items
}

// spoolPluginResults packs and appends queued plugin results under capability
// until the queue drains or the spool refuses a part. It reports whether the
// spool admitted anything this cycle.
func (p *PushLoop) spoolPluginResults(capability *edgev1.EdgeSignedCapabilityV1, agentID, partition string) bool {
	q := &p.pluginResultsEdge
	sent := false
	for {
		if q.built == nil {
			if len(q.pending) == 0 {
				return sent
			}
			item := q.pending[0]
			built, dropped, err := p.buildPluginResultItem(item, capability, agentID, partition)
			p.dropEdgeTelemetry(edgeProducerPluginResults, edgeDropInvalidRecord, dropped)
			if err != nil {
				p.logger.Warn().Err(err).Str("assignment_id", item.provenance.GetAssignmentId()).
					Msg("Dropping plugin results that cannot form an edge record")
				p.dropEdgeTelemetry(edgeProducerPluginResults, edgeDropInvalidRecord, item.count())
				q.pending = q.pending[1:]
				continue
			}
			q.pending = q.pending[1:]
			q.built = built
		}
		if !p.appendPluginResultBuilt(q.built) {
			return sent
		}
		sent = true
		q.built = nil
	}
}

// appendPluginResultBuilt appends a built item's remaining parts in order,
// stopping at the first refusal so a retry resumes at the same part under its
// original event id.
func (p *PushLoop) appendPluginResultBuilt(built *pluginResultBuiltItem) bool {
	for built.next < len(built.records) {
		record := built.records[built.next]
		if _, err := p.edgePluginResultSpool.AppendFlow(edgeAdmissionFlow(record), record.GetEventId(), built.bodies[built.next]); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to spool plugin result part; will retry")
			return false
		}
		built.next++
	}
	return true
}

// buildPluginResultItem converts one provenance group's host results into
// typed items and packs them into valid records. A result whose payload does
// not normalize becomes the same UNKNOWN error result the legacy path sends.
// A head result that cannot form a valid part is dropped alone (counted in
// dropped); the rest of the group still spools.
func (p *PushLoop) buildPluginResultItem(
	item pluginResultEdgeItem,
	capability *edgev1.EdgeSignedCapabilityV1,
	agentID string,
	partition string,
) (built *pluginResultBuiltItem, dropped int, err error) {
	converted := make([]*edgev1.WasmPluginResultItemV1, 0, len(item.results))
	for _, result := range item.results {
		converted = append(converted, p.convertPluginResult(result, agentID, partition))
	}

	built = &pluginResultBuiltItem{item: item}
	for len(converted) > 0 {
		n, record, body, err := longestPluginResultPrefix(item.provenance, converted, capability)
		if err != nil {
			return nil, dropped, err
		}
		if n == 0 {
			dropped++
			converted = converted[1:]
			continue
		}
		built.records = append(built.records, record)
		built.bodies = append(built.bodies, body)
		converted = converted[n:]
	}
	return built, dropped, nil
}

// longestPluginResultPrefix packs the longest prefix of results that forms
// one valid plugin results record under capability.
func longestPluginResultPrefix(
	provenance *edgev1.PluginResultProvenanceV1,
	results []*edgev1.WasmPluginResultItemV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) (int, *edgev1.EdgeRecordV1, []byte, error) {
	limit := len(results)
	if maxRows := pluginResultMaxRows(capability); uint64(limit) > maxRows {
		limit = int(maxRows)
	}

	bestN := 0
	var bestRecord *edgev1.EdgeRecordV1
	var bestBody []byte
	var lastErr error
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		batch := &edgev1.WasmPluginResultBatchV1{
			Provenance: provenance,
			Results:    results[:mid],
		}
		record, body, err := pluginResultEdgeRecord(batch, capability)
		if err == nil {
			bestN, bestRecord, bestBody = mid, record, body
			lo = mid + 1
			continue
		}
		lastErr = err
		hi = mid - 1
	}
	if bestN == 0 && lastErr != nil && !errors.Is(lastErr, errPluginResultTooLarge) &&
		!errors.Is(lastErr, edgerecord.ErrPluginResultBatch) {
		return 0, nil, nil, lastErr
	}
	return bestN, bestRecord, bestBody, nil
}

func pluginResultMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.PluginResultsProjectedWriteBytesPerRecord)
}

func pluginResultEdgeRecord(
	batch *edgev1.WasmPluginResultBatchV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) (*edgev1.EdgeRecordV1, []byte, error) {
	rows := len(batch.GetResults())
	if rows == 0 || uint64(rows) > pluginResultMaxRows(capability) {
		return nil, nil, errPluginResultTooLarge
	}
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return nil, nil, err
	}
	if len(payload) > edgePluginResultsMaxPayloadBytes {
		return nil, nil, errPluginResultTooLarge
	}
	record, err := newEdgeRecord(capability, nil, payload, uint32(rows),
		uint64(rows)*edgerecord.PluginResultsProjectedWriteBytesPerRecord)
	if err != nil {
		return nil, nil, err
	}
	if err := edgerecord.ValidatePluginResultRecord(record); err != nil {
		return nil, nil, err
	}
	body, err := edgerecord.CanonicalRecordBytes(record)
	if err != nil {
		return nil, nil, err
	}
	return record, body, nil
}

// groupPluginResults groups drained host results by their host-stamped
// provenance, preserving drain order within and across groups.
func groupPluginResults(results []PluginResult) []pluginResultEdgeItem {
	var items []pluginResultEdgeItem
	index := map[string]int{}
	for _, result := range results {
		provenance := &edgev1.PluginResultProvenanceV1{
			AssignmentId:    result.AssignmentID,
			PluginId:        result.PluginID,
			PluginPackageId: result.PackageID,
			PluginVersion:   result.PackageVersion,
			ContentHash:     result.ContentHash,
		}
		key := strings.Join([]string{
			provenance.GetAssignmentId(), provenance.GetPluginId(),
			provenance.GetPluginPackageId(), provenance.GetPluginVersion(),
			provenance.GetContentHash(), pluginServiceName(result),
		}, "\x00")
		if i, ok := index[key]; ok {
			items[i].results = append(items[i].results, result)
			continue
		}
		index[key] = len(items)
		items = append(items, pluginResultEdgeItem{
			provenance:  provenance,
			serviceName: pluginServiceName(result),
			results:     []PluginResult{result},
		})
	}
	return items
}

// convertPluginResult turns one host result into its typed item, starting
// from the same normalized payload the legacy status path sends (host labels
// and acknowledgement list stamped, legacy metrics dropped). A payload that
// does not normalize becomes the legacy UNKNOWN error result.
func (p *PushLoop) convertPluginResult(
	result PluginResult,
	agentID string,
	partition string,
) *edgev1.WasmPluginResultItemV1 {
	payload, _, err := p.normalizePluginPayloadMap(result, agentID, partition)
	if err != nil {
		payload = decodePluginPayloadMap(p.buildPluginErrorPayload(result, err, agentID, partition))
	}
	return pluginResultItemFromPayload(payload, result)
}

func decodePluginPayloadMap(data []byte) map[string]interface{} {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var payload map[string]interface{}
	if err := decoder.Decode(&payload); err != nil {
		return map[string]interface{}{"status": "UNKNOWN", "summary": "plugin result invalid"}
	}
	return payload
}
