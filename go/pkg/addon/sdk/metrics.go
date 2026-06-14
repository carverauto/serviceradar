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

package sdk

import (
	"errors"
	"fmt"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	gproto "google.golang.org/protobuf/proto"
)

const MetricEnvelopeSchemaVersion = "serviceradar.metric.v1"

var (
	// errMetricBatchNil is returned when a nil metric batch is wrapped.
	errMetricBatchNil = errors.New("metric batch is nil")
	// errMetricBatchClone is returned when cloning the metric batch fails to
	// yield the expected type.
	errMetricBatchClone = errors.New("clone metric batch")
)

type MetricBatch = metricpb.MetricBatch
type Metric = metricpb.Metric
type MetricPoint = metricpb.MetricPoint
type MetricResource = metricpb.MetricResource
type IngestIdentity = metricpb.IngestIdentity
type StringMapEntry = metricpb.StringMapEntry
type MetricKind = metricpb.MetricKind
type MetricTemporality = metricpb.MetricTemporality
type MetricValueType = metricpb.MetricValueType

const (
	MetricKindGauge     = metricpb.MetricKind_METRIC_KIND_GAUGE
	MetricKindSum       = metricpb.MetricKind_METRIC_KIND_SUM
	MetricKindHistogram = metricpb.MetricKind_METRIC_KIND_HISTOGRAM

	MetricTemporalityDelta      = metricpb.MetricTemporality_METRIC_TEMPORALITY_DELTA
	MetricTemporalityCumulative = metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE

	MetricValueTypeDouble = metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE
	MetricValueTypeInt64  = metricpb.MetricValueType_METRIC_VALUE_TYPE_INT64
	MetricValueTypeUint64 = metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64
	MetricValueTypeBool   = metricpb.MetricValueType_METRIC_VALUE_TYPE_BOOL
	MetricValueTypeString = metricpb.MetricValueType_METRIC_VALUE_TYPE_STRING
)

// ServiceRadarMetricRecord wraps one canonical ServiceRadar metric batch as a
// native add-on telemetry record. The payload is protobuf bytes, not JSON; the
// gateway republishes it unchanged to metrics.*.
func ServiceRadarMetricRecord(
	eventID string,
	eventTimeUnixNano int64,
	observedTimeUnixNano int64,
	batch *metricpb.MetricBatch,
) (*addonpb.TelemetryRecord, error) {
	if batch == nil {
		return nil, errMetricBatchNil
	}

	normalized, ok := gproto.Clone(batch).(*metricpb.MetricBatch)
	if !ok {
		return nil, errMetricBatchClone
	}
	if normalized.SchemaVersion == "" {
		normalized.SchemaVersion = MetricEnvelopeSchemaVersion
	}
	if normalized.IngestIdentity == nil {
		normalized.IngestIdentity = &metricpb.IngestIdentity{}
	}
	if normalized.IngestIdentity.PayloadKind == "" {
		normalized.IngestIdentity.PayloadKind = MetricEnvelopeSchemaVersion
	}

	payload, err := gproto.Marshal(normalized)
	if err != nil {
		return nil, fmt.Errorf("marshal metric batch: %w", err)
	}

	return &addonpb.TelemetryRecord{
		EventId:              eventID,
		EventTimeUnixNano:    eventTimeUnixNano,
		ObservedTimeUnixNano: observedTimeUnixNano,
		PayloadKind:          addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
		Payload:              payload,
	}, nil
}
