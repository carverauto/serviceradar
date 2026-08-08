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

package sdk_test

import (
	"testing"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/addon/sdk"
)

func TestServiceRadarMetricRecordWrapsCanonicalMetricBatch(t *testing.T) {
	record, err := sdk.ServiceRadarMetricRecord("evt-1", 123, 456, &metricpb.MetricBatch{
		Resource: &metricpb.MetricResource{
			AgentId:     "agent-1",
			ServiceName: "sample-native-addon",
			ServiceType: "native-addon",
			Attributes: []*metricpb.StringMapEntry{
				{Key: "rack", Value: "rack-7"},
			},
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "native-addon",
			ProducerId:   "sample-native-addon",
			ProducerKind: "native-addon",
		},
		Metrics: []*metricpb.Metric{
			{
				Name:       "cpu.temperature_celsius",
				MetricType: "cpu",
				Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
				Unit:       "Cel",
				Points: []*metricpb.MetricPoint{
					{
						Value:              62.5,
						ObservedAtUnixNano: 456,
						Attributes: []*metricpb.StringMapEntry{
							{Key: "sensor", Value: "cpu0"},
						},
					},
				},
			},
			{
				Name:        "network.bytes_total",
				MetricType:  "interface",
				Kind:        metricpb.MetricKind_METRIC_KIND_SUM,
				Temporality: metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE,
				IsMonotonic: true,
				Points: []*metricpb.MetricPoint{
					{
						Value:              987,
						RawValue:           "987",
						RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64,
						ObservedAtUnixNano: 456,
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("ServiceRadarMetricRecord() error = %v", err)
	}

	if record.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS {
		t.Fatalf("payload kind = %v", record.GetPayloadKind())
	}
	if record.GetEventId() != "evt-1" || record.GetEventTimeUnixNano() != 123 || record.GetObservedTimeUnixNano() != 456 {
		t.Fatalf("record identity/timestamps not preserved: %+v", record)
	}

	var decoded metricpb.MetricBatch
	if err := gproto.Unmarshal(record.GetPayload(), &decoded); err != nil {
		t.Fatalf("unmarshal metric batch: %v", err)
	}
	if decoded.GetSchemaVersion() != sdk.MetricEnvelopeSchemaVersion {
		t.Fatalf("schema_version = %q", decoded.GetSchemaVersion())
	}
	if decoded.GetIngestIdentity().GetPayloadKind() != sdk.MetricEnvelopeSchemaVersion {
		t.Fatalf("ingest payload_kind = %q", decoded.GetIngestIdentity().GetPayloadKind())
	}
	if got := decoded.GetResource().GetAttributes()[0]; got.GetKey() != "rack" || got.GetValue() != "rack-7" {
		t.Fatalf("resource attribute lost: %+v", got)
	}
	if decoded.GetMetrics()[0].GetKind() != metricpb.MetricKind_METRIC_KIND_GAUGE {
		t.Fatalf("gauge kind lost: %v", decoded.GetMetrics()[0].GetKind())
	}
	if got := decoded.GetMetrics()[0].GetPoints()[0].GetAttributes()[0]; got.GetKey() != "sensor" || got.GetValue() != "cpu0" {
		t.Fatalf("point attribute lost: %+v", got)
	}
	counter := decoded.GetMetrics()[1]
	if counter.GetKind() != metricpb.MetricKind_METRIC_KIND_SUM ||
		counter.GetTemporality() != metricpb.MetricTemporality_METRIC_TEMPORALITY_CUMULATIVE ||
		!counter.GetIsMonotonic() ||
		counter.GetPoints()[0].GetRawValueType() != metricpb.MetricValueType_METRIC_VALUE_TYPE_UINT64 {
		t.Fatalf("counter semantics lost: %+v", counter)
	}
}

func TestServiceRadarMetricRecordRejectsNilBatch(t *testing.T) {
	if _, err := sdk.ServiceRadarMetricRecord("evt-1", 0, 0, nil); err == nil {
		t.Fatal("expected nil batch error")
	}
}
