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
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func otlpRelayCapability(t *testing.T, agentID string, notBefore, expires time.Time, maxRows uint32, maxWriteBytes uint64) *edgev1.EdgeSignedCapabilityV1 {
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
			OriginPrincipalId:      []byte(agentID),
			ProducerInstanceId:     []byte(agentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              "serviceradar.agent.otlp_relay",
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   maxRows,
			MaxProjectedWriteBytes: maxWriteBytes,
		}},
	}
	edgerecord.SignCapability(capability, key)
	return capability
}

func spooledOtlpRelayRecords(t *testing.T, sp *spool.Spool) ([]*edgev1.EdgeRecordV1, []*addonpb.OtlpRelayFrame) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	records := make([]*edgev1.EdgeRecordV1, 0, len(stored))
	frames := make([]*addonpb.OtlpRelayFrame, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, edgerecord.ValidateOtlpRelayRecord(record))
		require.Nil(t, record.GetSourceAuthorization())
		frame := &addonpb.OtlpRelayFrame{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), frame))
		records = append(records, record)
		frames = append(frames, frame)
	}
	return records, frames
}

type fakeOtlpRelayGateway struct {
	mu    sync.Mutex
	calls int
}

func (g *fakeOtlpRelayGateway) GetGatewayID() string { return "gateway-test-01" }

func (g *fakeOtlpRelayGateway) StreamStatus(_ context.Context, _ []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
	g.mu.Lock()
	g.calls++
	g.mu.Unlock()
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func TestOtlpRelayPumpWithGrantSpoolsEdgeRecordsAndAcksAfterAppend(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024, 524_288)
	gw := &fakeOtlpRelayGateway{}

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		gateway:         gw,
		agentID:         sysmonEdgeAgentID,
		partition:       "default",
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
	require.Zero(t, gw.calls, "gateway StreamStatus must not be called while the OTLP relay grant is active")
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
	cap := otlpRelayCapability(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 2, 524_288)
	gw := &fakeOtlpRelayGateway{}

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		gateway:         gw,
		agentID:         sysmonEdgeAgentID,
		partition:       "default",
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

type flakyEdgeAppender struct {
	mu       sync.Mutex
	delegate *spool.Spool
	attempts int
	eventIDs [][]byte
}

func (f *flakyEdgeAppender) Append(eventID, body []byte) (uint64, error) {
	f.mu.Lock()
	f.attempts++
	attempt := f.attempts
	f.eventIDs = append(f.eventIDs, append([]byte(nil), eventID...))
	f.mu.Unlock()
	if attempt == 1 {
		return 0, errors.New("simulated transient spool full")
	}
	return f.delegate.Append(eventID, body)
}

func TestOtlpRelayPumpRetryableSpoolRefusalRetainsBuiltEventIDBeforeAck(t *testing.T) {
	sp := openTestEdgeSpool(t)
	flaky := &flakyEdgeAppender{delegate: sp}
	now := time.Now()
	cap := otlpRelayCapability(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024, 524_288)

	pump := &otlpRelayPump{
		addonID:             "otel-collector",
		gateway:             &fakeOtlpRelayGateway{},
		agentID:             sysmonEdgeAgentID,
		partition:           "default",
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

func TestOtlpRelayPumpSkipsOversizedSingleRecordAndAcksFrame(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now()
	cap := otlpRelayCapability(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024, 524_288)
	dropped := 0

	pump := &otlpRelayPump{
		addonID:         "otel-collector",
		gateway:         &fakeOtlpRelayGateway{},
		agentID:         sysmonEdgeAgentID,
		partition:       "default",
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
