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
	"google.golang.org/protobuf/encoding/protowire"
	gproto "google.golang.org/protobuf/proto"

	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

// metricFieldTagBytes is the wire-tag length for field 20 (MetricBatch.metrics
// and Metric.points), the repeated message fields this splitter packs.
const metricFieldTagBytes = 2

// metricBatchSplit is the outcome of splitting one MetricBatch under a byte
// bound: the parts in original metric order, the encoded size of the original
// batch, and the points dropped because a single point could not fit.
type metricBatchSplit struct {
	Parts         []*metricpb.MetricBatch
	OriginalBytes int
	DroppedPoints int
}

// splitMetricBatchByEncodedSize splits batch so every part's encoded size
// stays under maxBytes. The batch envelope (schema version, resource, ingest
// identity, ingress id and timestamps) is preserved on every part. A metric
// whose points alone exceed the bound is split into point shards carrying the
// same header fields; a single point that cannot fit even in an otherwise
// empty part is dropped and counted, because publishing it would only
// recreate the NATS "Maximum Payload Violation" that drops the gateway
// connection.
//
// Sizes come from exact wire arithmetic — each repeated message entry encodes
// independently as tag + varint length + bytes — so packed part sizes match
// the budget checks without re-marshaling the accumulated part per item.
func splitMetricBatchByEncodedSize(batch *metricpb.MetricBatch, maxBytes int) metricBatchSplit {
	envelope := gproto.Clone(batch).(*metricpb.MetricBatch)
	envelope.Metrics = nil

	envelopeSize := gproto.Size(envelope)
	originalBytes := envelopeSize

	for _, metric := range batch.GetMetrics() {
		originalBytes += metricItemCost(metric)
	}

	if originalBytes <= maxBytes {
		return metricBatchSplit{
			Parts:         []*metricpb.MetricBatch{batch},
			OriginalBytes: originalBytes,
		}
	}

	items, dropped := expandOversizedMetrics(batch.GetMetrics(), envelopeSize, maxBytes)

	return metricBatchSplit{
		Parts:         packBatchParts(envelope, envelopeSize, items, maxBytes),
		OriginalBytes: originalBytes,
		DroppedPoints: dropped,
	}
}

// expandOversizedMetrics replaces any metric that cannot fit alongside the
// envelope with point shards that each can.
func expandOversizedMetrics(metrics []*metricpb.Metric, envelopeSize, maxBytes int) ([]*metricpb.Metric, int) {
	items := make([]*metricpb.Metric, 0, len(metrics))
	dropped := 0

	for _, metric := range metrics {
		if envelopeSize+metricItemCost(metric) <= maxBytes {
			items = append(items, metric)
			continue
		}

		shards, shardDropped := splitMetricPoints(metric, envelopeSize, maxBytes)
		items = append(items, shards...)
		dropped += shardDropped
	}

	return items, dropped
}

// splitMetricPoints splits one metric whose own encoded size exceeds the
// bound into shards (same header, subset of points) that each fit alongside
// the envelope.
func splitMetricPoints(metric *metricpb.Metric, envelopeSize, maxBytes int) ([]*metricpb.Metric, int) {
	header := gproto.Clone(metric).(*metricpb.Metric)
	header.Points = nil

	headerSize := gproto.Size(header)

	var shards []*metricpb.Metric
	var current []*metricpb.MetricPoint
	currentSize := headerSize
	dropped := 0

	flush := func() {
		if len(current) == 0 {
			return
		}

		shard := gproto.Clone(header).(*metricpb.Metric)
		shard.Points = current
		shards = append(shards, shard)

		current = nil
		currentSize = headerSize
	}

	for _, point := range metric.GetPoints() {
		cost := pointItemCost(point)

		switch {
		case len(current) > 0 && envelopeSize+wrappedSize(currentSize+cost) > maxBytes:
			flush()
			current = append(current, point)
			currentSize = headerSize + cost

		case len(current) == 0 && envelopeSize+wrappedSize(headerSize+cost) > maxBytes:
			// A lone point that cannot fit under the bound can never be
			// published; drop it rather than emitting a message the broker
			// is guaranteed to reject.
			dropped++

		default:
			current = append(current, point)
			currentSize += cost
		}
	}

	flush()

	return shards, dropped
}

func packBatchParts(envelope *metricpb.MetricBatch, envelopeSize int, items []*metricpb.Metric, maxBytes int) []*metricpb.MetricBatch {
	var parts []*metricpb.MetricBatch
	var current []*metricpb.Metric
	currentSize := envelopeSize

	closePart := func() {
		if len(current) == 0 {
			return
		}

		part := gproto.Clone(envelope).(*metricpb.MetricBatch)
		part.Metrics = current
		parts = append(parts, part)

		current = nil
		currentSize = envelopeSize
	}

	for _, item := range items {
		cost := metricItemCost(item)

		if len(current) > 0 && currentSize+cost > maxBytes {
			closePart()
		}

		current = append(current, item)
		currentSize += cost
	}

	closePart()

	return parts
}

func metricItemCost(metric *metricpb.Metric) int {
	return wrappedSize(gproto.Size(metric))
}

func pointItemCost(point *metricpb.MetricPoint) int {
	return wrappedSize(gproto.Size(point))
}

// wrappedSize returns the bytes a repeated field entry adds to its parent
// message: wire tag plus varint length prefix plus the entry bytes.
func wrappedSize(entrySize int) int {
	return metricFieldTagBytes + varintLen(uint64(entrySize)) + entrySize
}

func varintLen(value uint64) int {
	return protowire.SizeVarint(value)
}
