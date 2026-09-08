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
	"testing"

	addonsdk "github.com/carverauto/serviceradar/go/pkg/addon/sdk"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	gproto "google.golang.org/protobuf/proto"
)

const addonPowerDNSSource = "addon:powerdns"

func TestBuildAddonTelemetryGatewayStatus_WrapsBatchWithAddonSource(t *testing.T) {
	batch := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			SourceType:     "powerdns",
			SourceInstance: "ns03",
		},
		Records: []*addonpb.TelemetryRecord{
			{
				EventId:     "event-1",
				PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
				Payload:     []byte(`{"class_uid":4003}`),
			},
		},
	}

	status, messageBytes, err := buildAddonTelemetryGatewayStatus(
		addonTelemetryEnvelope{addonID: "powerdns", batch: batch},
		"agent-a",
		"gateway-a",
		"prod-east",
		"kv-a",
	)
	if err != nil {
		t.Fatalf("buildAddonTelemetryGatewayStatus: %v", err)
	}

	if status.GetServiceName() != addonTelemetryServiceName {
		t.Fatalf("ServiceName = %q, want %q", status.GetServiceName(), addonTelemetryServiceName)
	}
	if status.GetServiceType() != addonTelemetryServiceType {
		t.Fatalf("ServiceType = %q, want %q", status.GetServiceType(), addonTelemetryServiceType)
	}
	if status.GetSource() != addonPowerDNSSource {
		t.Fatalf("Source = %q, want addon:powerdns", status.GetSource())
	}
	if messageBytes <= 0 || len(status.GetMessage()) != messageBytes {
		t.Fatalf("message byte count = %d len(message) = %d", messageBytes, len(status.GetMessage()))
	}

	var decoded addonpb.TelemetryBatch
	if err := gproto.Unmarshal(status.GetMessage(), &decoded); err != nil {
		t.Fatalf("Unmarshal(TelemetryBatch): %v", err)
	}

	if decoded.GetSource().GetSourceInstance() != "ns03" {
		t.Fatalf("decoded source instance = %q, want ns03", decoded.GetSource().GetSourceInstance())
	}
	if got := decoded.GetRecords()[0].GetPayloadKind(); got != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT {
		t.Fatalf("decoded payload kind = %v, want OCSF_EVENT", got)
	}
}

func TestBuildAddonTelemetryGatewayStatus_PreservesServiceRadarMetricPayload(t *testing.T) {
	metricBatch := &metricpb.MetricBatch{
		SchemaVersion: "serviceradar.metric.v1",
		Resource: &metricpb.MetricResource{
			AgentId:     "agent-a",
			ServiceName: "powerdns",
			ServiceType: "native-addon",
		},
		IngestIdentity: &metricpb.IngestIdentity{
			Source:       "native-addon",
			ProducerId:   "powerdns",
			ProducerKind: "native-addon",
			PayloadKind:  "serviceradar.metric.v1",
		},
		Metrics: []*metricpb.Metric{
			{
				Name:       "dns.rpz_hits_total",
				MetricType: "dns",
				Kind:       metricpb.MetricKind_METRIC_KIND_SUM,
				Points: []*metricpb.MetricPoint{
					{
						Value:              42,
						ObservedAtUnixNano: 123,
					},
				},
			},
		},
	}
	record, err := addonsdk.ServiceRadarMetricRecord("metric-event-1", 123, 123, metricBatch)
	if err != nil {
		t.Fatalf("ServiceRadarMetricRecord: %v", err)
	}

	batch := &addonpb.TelemetryBatch{
		Records: []*addonpb.TelemetryRecord{record},
	}

	status, _, err := buildAddonTelemetryGatewayStatus(
		addonTelemetryEnvelope{addonID: "powerdns", batch: batch},
		"agent-a",
		"gateway-a",
		"prod-east",
		"kv-a",
	)
	if err != nil {
		t.Fatalf("buildAddonTelemetryGatewayStatus: %v", err)
	}
	if status.GetServiceType() != addonTelemetryServiceType {
		t.Fatalf("ServiceType = %q, want %q", status.GetServiceType(), addonTelemetryServiceType)
	}
	if status.GetSource() != addonPowerDNSSource {
		t.Fatalf("Source = %q, want addon:powerdns", status.GetSource())
	}

	var decodedBatch addonpb.TelemetryBatch
	if err := gproto.Unmarshal(status.GetMessage(), &decodedBatch); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	decodedRecord := decodedBatch.GetRecords()[0]
	if got := decodedRecord.GetPayloadKind(); got != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS {
		t.Fatalf("decoded payload kind = %v, want SERVICERADAR_METRICS", got)
	}

	var decodedMetric metricpb.MetricBatch
	if err := gproto.Unmarshal(decodedRecord.GetPayload(), &decodedMetric); err != nil {
		t.Fatalf("unmarshal metric batch: %v", err)
	}
	if decodedMetric.GetSchemaVersion() != "serviceradar.metric.v1" {
		t.Fatalf("schema version = %q", decodedMetric.GetSchemaVersion())
	}
	if got := decodedMetric.GetMetrics()[0].GetName(); got != "dns.rpz_hits_total" {
		t.Fatalf("metric name = %q, want dns.rpz_hits_total", got)
	}
}

func TestAddonTelemetrySourceFallsBackToUnknown(t *testing.T) {
	if got := addonTelemetrySource("  "); got != "addon:unknown" {
		t.Fatalf("addonTelemetrySource(blank) = %q, want addon:unknown", got)
	}
}

func TestAddonTelemetryBufferReportsDeltaAndTotalDrops(t *testing.T) {
	buffer := newAddonTelemetryBuffer(1)
	batch := &addonpb.TelemetryBatch{}

	buffer.enqueue("powerdns", batch)
	buffer.enqueue("powerdns", batch)
	buffer.enqueue("powerdns", batch)

	envelopes, droppedDelta, droppedTotal := buffer.drain(10)
	if len(envelopes) != 1 {
		t.Fatalf("drained envelopes = %d, want 1", len(envelopes))
	}
	if droppedDelta != 2 {
		t.Fatalf("dropped delta = %d, want 2", droppedDelta)
	}
	if droppedTotal != 2 {
		t.Fatalf("dropped total = %d, want 2", droppedTotal)
	}

	_, droppedDelta, droppedTotal = buffer.drain(10)
	if droppedDelta != 0 {
		t.Fatalf("second dropped delta = %d, want 0", droppedDelta)
	}
	if droppedTotal != 2 {
		t.Fatalf("second dropped total = %d, want 2", droppedTotal)
	}
}

func TestAddonTelemetryQueueDrainsIntoGatewayStatus(t *testing.T) {
	buffer := newAddonTelemetryBuffer(2)
	batch := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			SourceType:     "powerdns",
			SourceInstance: "ns03",
		},
		Records: []*addonpb.TelemetryRecord{
			{
				EventId:     "rpz-event-1",
				PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
				Payload:     []byte(`{"class_uid":4003,"type_uid":400302}`),
			},
		},
		Counters: &addonpb.TelemetryCounters{
			Received:   10,
			Filtered:   7,
			Emitted:    3,
			Dropped:    1,
			QueueDepth: 1,
		},
	}

	buffer.enqueue("powerdns", batch)
	envelopes, droppedDelta, droppedTotal := buffer.drain(1)
	if droppedDelta != 0 || droppedTotal != 0 {
		t.Fatalf("dropped delta/total = %d/%d, want 0/0", droppedDelta, droppedTotal)
	}
	if len(envelopes) != 1 {
		t.Fatalf("drained envelopes = %d, want 1", len(envelopes))
	}

	status, _, err := buildAddonTelemetryGatewayStatus(
		envelopes[0],
		"agent-ns03",
		"gateway-demo",
		"default",
		"kv-demo",
	)
	if err != nil {
		t.Fatalf("buildAddonTelemetryGatewayStatus: %v", err)
	}
	if status.GetSource() != addonPowerDNSSource {
		t.Fatalf("source = %q, want addon:powerdns", status.GetSource())
	}

	var decoded addonpb.TelemetryBatch
	if err := gproto.Unmarshal(status.GetMessage(), &decoded); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	if decoded.GetCounters().GetDropped() != 1 {
		t.Fatalf("decoded dropped counter = %d, want 1", decoded.GetCounters().GetDropped())
	}
	if decoded.GetRecords()[0].GetEventId() != "rpz-event-1" {
		t.Fatalf("decoded event id = %q, want rpz-event-1", decoded.GetRecords()[0].GetEventId())
	}
}
