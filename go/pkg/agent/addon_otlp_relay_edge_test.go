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
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func otlpRelayCapability(t *testing.T, notBefore, expires time.Time, maxRows uint32) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-otlp-relay-contract"))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: notBefore.UnixNano(),
		ExpiresAtUnixNano: expires.UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             edgerecord.OtlpRelayContractID,
			ContractVersion:        edgerecord.OtlpRelayContractVersion,
			ContractBundleSha256:   digest[:],
			RegistryEpoch:          1,
			RegistrySnapshotSha256: digest[:],
			EffectiveGrantSha256:   digest[:],
			NetworkScopeId:         testNetworkScopeID[:],
			ProducerAssignmentId:   testAssignmentID[:],
			RunId:                  testAssignmentID[:],
			AuthorityEpoch:         1,
			ScopeId:                testAssignmentID[:],
			ScopeSha256:            digest[:],
			OriginKind:             edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:      []byte(sysmonEdgeAgentID),
			ProducerInstanceId:     []byte(sysmonEdgeAgentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              "serviceradar.agent.otlp_relay",
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   maxRows,
			MaxProjectedWriteBytes: uint64(edgerecord.MaxRecordBytes),
		}},
	}
	edgerecord.SignCapability(capability, key)
	return capability
}

func spooledOtlpRelayRecords(t *testing.T, sp *RecordSpool) ([]*edgev1.EdgeRecordV1, []*addonpb.OtlpRelayFrame) {
	t.Helper()
	return spooledEdgeRecordsWithBody(t, sp, edgerecord.ValidateOtlpRelayRecord, func() *addonpb.OtlpRelayFrame {
		return &addonpb.OtlpRelayFrame{}
	})
}

func TestOtlpRelayPumpWithGrantSpoolsEdgeRecordsAndAcksAfterAppend(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024)
	installTestCapability(t, sp, cap)

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		windowMaxFrames: 1,
		flushInterval:   5 * time.Millisecond,
		edgeTarget: func(_ time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return sp, cap
		},
		logger: logger.NewTestLogger(),
	}

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 1)
	frames <- &addonpb.OtlpRelayFrame{
		RelayId: 42,
		Batch: &addonpb.TelemetryBatch{
			Counters: &addonpb.TelemetryCounters{Received: 10, Emitted: 2},
			Records: []*addonpb.TelemetryRecord{
				{
					EventId:     "01950000-0000-7000-8000-000000000001",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
					Payload:     []byte{0x0a, 0x04, 's', 'p', 'a', 'n'},
				},
				{
					EventId:     "01950000-0000-7000-8000-000000000002",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
					Payload:     []byte{0x0a, 0x06, 'm', 'e', 't', 'r', 'i', 'c'},
				},
			},
		},
	}
	close(frames)

	pump.run(context.Background(), frames, acks)

	require.Equal(t, uint64(42), <-acks)
	records, decodedFrames := spooledOtlpRelayRecords(t, sp)
	require.Len(t, records, 1)
	require.Equal(t, uint32(2), records[0].GetProjectedRowCount())
	require.Equal(t, uint64(records[0].GetUncompressedSize()), records[0].GetProjectedWriteBytes())
	require.Equal(t, uint64(42), decodedFrames[0].GetRelayId())
	require.Len(t, decodedFrames[0].GetBatch().GetRecords(), 2)
	require.Equal(t, uint64(10), decodedFrames[0].GetBatch().GetCounters().GetReceived())
}

func TestOtlpRelayPumpSplitsMultiRecordFrameAndPreservesCountersOnFirstPart(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 2)
	installTestCapability(t, sp, cap)

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		windowMaxFrames: 1,
		flushInterval:   5 * time.Millisecond,
		edgeTarget: func(_ time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return sp, cap
		},
		logger: logger.NewTestLogger(),
	}

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 1)
	frames <- &addonpb.OtlpRelayFrame{
		RelayId: 99,
		Batch: &addonpb.TelemetryBatch{
			Source:   &addonpb.TelemetrySource{SourceType: "otel", SourceInstance: "edge-1"},
			Counters: &addonpb.TelemetryCounters{Received: 30, Emitted: 3},
			Records: []*addonpb.TelemetryRecord{
				{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, Payload: []byte("trace-1")},
				{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, Payload: []byte("log-2")},
				{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC, Payload: []byte("derived-3")},
			},
		},
	}
	close(frames)

	pump.run(context.Background(), frames, acks)

	require.Equal(t, uint64(99), <-acks)
	records, decodedFrames := spooledOtlpRelayRecords(t, sp)
	require.Len(t, records, 2)
	require.Equal(t, uint64(99), decodedFrames[0].GetRelayId())
	require.Equal(t, uint64(99), decodedFrames[1].GetRelayId())
	require.Len(t, decodedFrames[0].GetBatch().GetRecords(), 2)
	require.Len(t, decodedFrames[1].GetBatch().GetRecords(), 1)
	require.NotNil(t, decodedFrames[0].GetBatch().GetCounters(), "first split part carries counters")
	require.Nil(t, decodedFrames[1].GetBatch().GetCounters(), "subsequent split part omits counters to avoid double counting")
}

func TestOtlpRelayPumpRetryableSpoolRefusalRetainsBuiltEventIDBeforeAck(t *testing.T) {
	sp := openTestEdgeSpool(t)
	flaky := &refusingRelayAppender{delegate: sp, refuseFirst: 1}
	now := time.Now()
	cap := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024)
	installTestCapability(t, sp, cap)

	pump := &otlpRelayPump{
		addonID:             "otel-collector",
		windowMaxFrames:     1,
		flushInterval:       5 * time.Millisecond,
		retryBackoffInitial: time.Millisecond,
		retryBackoffMax:     2 * time.Millisecond,
		edgeTarget: func(_ time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return flaky, cap
		},
		logger: logger.NewTestLogger(),
	}

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 1)
	frames <- &addonpb.OtlpRelayFrame{
		RelayId: 7,
		Batch: &addonpb.TelemetryBatch{
			Records: []*addonpb.TelemetryRecord{
				{PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, Payload: []byte("trace-payload")},
			},
		},
	}
	close(frames)

	pump.run(context.Background(), frames, acks)

	require.Equal(t, uint64(7), <-acks)
	require.Equal(t, uint64(1), pump.stats.retried.Load())
	require.Equal(t, uint64(1), pump.stats.acked.Load())
	flaky.mu.Lock()
	require.Len(t, flaky.eventIDs, 2)
	require.True(t, bytes.Equal(flaky.eventIDs[0], flaky.eventIDs[1]), "retried append must preserve the built event_id")
	flaky.mu.Unlock()
}

// A relay record no edge record can hold is counted and acked with its frame:
// it can never become deliverable, and no other path carries it.
func TestOtlpRelayPumpCountsAndAcksRecordNoEdgeRecordHolds(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024)
	installTestCapability(t, sp, cap)
	dropped := 0

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		windowMaxFrames: 1,
		flushInterval:   5 * time.Millisecond,
		edgeTarget: func(_ time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return sp, cap
		},
		recordDrop: func(reason edgeDropReason, count int, _ error) {
			if reason == edgeDropInvalidRecord {
				dropped += count
			}
		},
		logger: logger.NewTestLogger(),
	}

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 1)
	frames <- &addonpb.OtlpRelayFrame{
		RelayId: 12,
		Batch: &addonpb.TelemetryBatch{
			Counters: &addonpb.TelemetryCounters{Received: 4, Dropped: 1},
			Records: []*addonpb.TelemetryRecord{
				{
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
					Payload:     bytes.Repeat([]byte("x"), edgerecord.MaxRecordBytes+1024),
				},
			},
		},
	}
	close(frames)

	pump.run(context.Background(), frames, acks)

	require.Equal(t, uint64(12), <-acks)
	require.Equal(t, uint64(1), pump.stats.skippedOversize.Load())
	require.Equal(t, 1, dropped)
	records, _ := spooledOtlpRelayRecords(t, sp)
	require.Empty(t, records)
}

func TestOtlpRelayPumpSpoolsFittingRecordAndCountsOversizedSibling(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024)
	installTestCapability(t, sp, cap)
	dropped := 0

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		windowMaxFrames: 1,
		flushInterval:   5 * time.Millisecond,
		edgeTarget: func(_ time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return sp, cap
		},
		recordDrop: func(reason edgeDropReason, count int, _ error) {
			if reason == edgeDropInvalidRecord {
				dropped += count
			}
		},
		logger: logger.NewTestLogger(),
	}

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 1)
	frames <- &addonpb.OtlpRelayFrame{
		RelayId: 18,
		Batch: &addonpb.TelemetryBatch{
			Counters: &addonpb.TelemetryCounters{Received: 9, Emitted: 2},
			Records: []*addonpb.TelemetryRecord{
				{
					EventId:     "fit-1",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
					Payload:     []byte("log-fits"),
				},
				{
					EventId:     "over-2",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
					Payload:     bytes.Repeat([]byte("y"), edgerecord.MaxRecordBytes+2048),
				},
			},
		},
	}
	close(frames)

	pump.run(context.Background(), frames, acks)

	require.Equal(t, uint64(18), <-acks)
	require.Equal(t, uint64(1), pump.stats.skippedOversize.Load())
	require.Equal(t, 1, dropped)
	_, decodedFrames := spooledOtlpRelayRecords(t, sp)
	require.Len(t, decodedFrames, 1)
	require.Len(t, decodedFrames[0].GetBatch().GetRecords(), 1)
	require.Equal(t, "fit-1", decodedFrames[0].GetBatch().GetRecords()[0].GetEventId())
	require.Equal(t, uint64(9), decodedFrames[0].GetBatch().GetCounters().GetReceived())
}
