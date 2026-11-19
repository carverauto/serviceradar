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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	gproto "google.golang.org/protobuf/proto"
	"gopkg.in/yaml.v3"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgesender "github.com/carverauto/serviceradar/go/pkg/edge/sender"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

type journeyPipelineIngestServer struct {
	edgev1.UnimplementedEdgeRecordIngestServiceServer
	mu      sync.Mutex
	records []*edgev1.EdgeRecordV1
}

func (s *journeyPipelineIngestServer) Stream(
	stream grpc.BidiStreamingServer[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	open := first.GetLaneOpen()
	if open == nil {
		return status.Error(codes.InvalidArgument, "expected lane_open")
	}

	ack := &edgev1.EdgeRecordLaneOpenAck{
		SpoolId:             open.GetSpoolId(),
		SessionNonce:        open.GetSessionNonce(),
		GrantedByteCredits:  open.GetRequestedByteCredits(),
		GrantedFrameCredits: open.GetRequestedFrameCredits(),
		RouteProfile:        open.GetRouteProfile(),
		TrafficClass:        open.GetTrafficClass(),
	}
	if err := stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_LaneOpenAck{LaneOpenAck: ack},
	}); err != nil {
		return err
	}

	resolvedThrough := open.GetFirstUnresolvedSequence() - 1
	var disps []*edgev1.EdgeRecordDisposition

	for {
		msg, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		frame := msg.GetDeliveryFrame()
		if frame == nil {
			return status.Error(codes.InvalidArgument, "expected delivery_frame")
		}
		record, err := edgerecord.DecodeRecord(frame.GetRecordBytes())
		if err != nil {
			return status.Error(codes.InvalidArgument, "invalid EdgeRecordV1 frame")
		}

		s.mu.Lock()
		s.records = append(s.records, record)
		s.mu.Unlock()

		disps = append(disps, &edgev1.EdgeRecordDisposition{
			Sequence: frame.GetSequence(),
			EventId:  record.GetEventId(),
			Kind:     edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE,
		})
		resolvedThrough = frame.GetSequence()
	}

	return stream.Send(&edgev1.EdgeRecordServerMessage{
		Payload: &edgev1.EdgeRecordServerMessage_Ack{
			Ack: &edgev1.EdgeDeliveryAckV1{
				SpoolId:                 open.GetSpoolId(),
				SessionNonce:            open.GetSessionNonce(),
				ResolvedThroughSequence: resolvedThrough,
				Dispositions:            disps,
			},
		},
	})
}

func (s *journeyPipelineIngestServer) drainRecords() []*edgev1.EdgeRecordV1 {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.records
	s.records = nil
	return out
}

func dialJourneyIngestBufconn(t *testing.T, srv edgev1.EdgeRecordIngestServiceServer) edgev1.EdgeRecordIngestServiceClient {
	t.Helper()
	listener := bufconn.Listen(1 << 20)
	grpcServer := grpc.NewServer()
	edgev1.RegisterEdgeRecordIngestServiceServer(grpcServer, srv)
	go func() { _ = grpcServer.Serve(listener) }()
	t.Cleanup(grpcServer.Stop)

	conn, err := grpc.NewClient(
		"passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return listener.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })
	return edgev1.NewEdgeRecordIngestServiceClient(conn)
}

func locateJourneyRunfile(t *testing.T, suffix string) string {
	t.Helper()
	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		data, err := os.ReadFile(manifest)
		require.NoError(t, err)
		for _, line := range strings.Split(string(data), "\n") {
			runfile, target, ok := strings.Cut(line, " ")
			if !ok || !strings.HasSuffix(runfile, suffix) {
				continue
			}
			if _, err := os.Stat(target); err == nil {
				return target
			}
		}
	}
	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
			if workspace == "" {
				continue
			}
			candidate := filepath.Join(testSrcDir, workspace, suffix)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}
	t.Fatalf("runfile %s not found; run via Bazel //go/pkg/agent:http_synthetic_journey_pipeline_test", suffix)
	return ""
}

func loadJourneyManifestCapabilities(t *testing.T) (string, map[string]bool) {
	t.Helper()
	raw, err := os.ReadFile(locateJourneyRunfile(t, "go/cmd/wasm-plugins/http-synthetic-journey/plugin.yaml"))
	require.NoError(t, err)
	var doc struct {
		ID           string   `yaml:"id"`
		Entrypoint   string   `yaml:"entrypoint"`
		Capabilities []string `yaml:"capabilities"`
	}
	require.NoError(t, yaml.Unmarshal(raw, &doc))
	require.Equal(t, "http-synthetic-journey", doc.ID)
	require.Equal(t, "run_check", doc.Entrypoint)
	caps := make(map[string]bool, len(doc.Capabilities))
	for _, c := range doc.Capabilities {
		caps[c] = true
	}
	require.True(t, caps["emit_telemetry"])
	require.True(t, caps["http_request"])
	require.True(t, caps["submit_result"])
	return doc.Entrypoint, caps
}

func mintJourneyStandingGrant(
	t *testing.T,
	key ed25519.PrivateKey,
	agentID string,
	networkScope uuid.UUID,
	assignment uuid.UUID,
	contractID string,
	contractVersion uint32,
	packageID string,
	writeBytesPerRow uint64,
) *proto.EdgeOutputGrant {
	t.Helper()
	digest := sha256.Sum256([]byte("synthetic-" + contractID))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("synthetic-issuer"),
		IssuerKeyId:       []byte("synthetic-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             contractID,
			ContractVersion:        contractVersion,
			ContractBundleSha256:   digest[:],
			RegistryEpoch:          1,
			RegistrySnapshotSha256: digest[:],
			EffectiveGrantSha256:   digest[:],
			NetworkScopeId:         networkScope[:],
			ProducerAssignmentId:   assignment[:],
			RunId:                  assignment[:],
			AuthorityEpoch:         1,
			ScopeId:                assignment[:],
			ScopeSha256:            digest[:],
			OriginKind:             edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:      []byte(agentID),
			ProducerInstanceId:     []byte(agentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              packageID,
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   10_000,
			MaxProjectedWriteBytes: 10_000 * writeBytesPerRow,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           contractID,
		ContractVersion:      contractVersion,
		ProductionCapability: encoded,
	}
}

func installJourneyGrantsAndTrust(t *testing.T, loop *PushLoop, sp *RecordSpool, agentID string) {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)

	networkScope := uuid.MustParse("11111111-2222-4333-8444-555555555555")
	assignment := uuid.MustParse("66666666-7777-4888-8999-000000000001")

	grants := []*proto.EdgeOutputGrant{
		mintJourneyStandingGrant(
			t, key, agentID, networkScope, assignment,
			edgerecord.PluginResultsContractID, edgerecord.PluginResultsContractVersion,
			"serviceradar.agent.plugin_results", edgerecord.PluginResultsProjectedWriteBytesPerRecord,
		),
		mintJourneyStandingGrant(
			t, key, agentID, networkScope, assignment,
			edgerecord.TelemetryBatchContractID, edgerecord.TelemetryBatchContractVersion,
			"serviceradar.agent.telemetry", edgerecord.TelemetryProjectedWriteBytesPerRecord,
		),
	}

	var firstCap edgev1.EdgeSignedCapabilityV1
	require.NoError(t, gproto.Unmarshal(grants[0].GetProductionCapability(), &firstCap))
	claims := firstCap.GetProduction()

	trustDoc, err := json.Marshal(map[string]any{
		"keys": []map[string]any{{
			"issuer_id":     firstCap.IssuerId,
			"issuer_key_id": firstCap.IssuerKeyId,
			"public_key":    []byte(key.Public().(ed25519.PublicKey)),
			"purposes":      []string{"production", "source", "delivery"},
			"status":        "valid",
		}},
		"fences": []map[string]any{{
			"network_scope_id":       claims.NetworkScopeId,
			"producer_assignment_id": claims.ProducerAssignmentId,
			"run_shard":              claims.RunShard,
			"authority_epoch":        claims.AuthorityEpoch,
		}},
		"scopes": []any{map[string]any{
			"agent_id":          agentID,
			"network_scope_ids": [][]byte{claims.NetworkScopeId},
		}},
	})
	require.NoError(t, err)

	snapshot, err := edgerecord.ParseTrustDocument(trustDoc, []byte(agentID), 1)
	require.NoError(t, err)
	loop.edgeRecordTrust.Store(snapshot)
	sp.SetTrustProvider(loop.EdgeRecordTrustSnapshot)
	require.Empty(t, loop.edgeOutputGrants.replace(agentID, grants, time.Now()))
}

func decodeJourneyRecordBody(t *testing.T, record *edgev1.EdgeRecordV1) []byte {
	t.Helper()
	if record.GetCompression() == edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD {
		body, err := edgerecord.DecompressZstdPayload(record.GetPayload(), record.GetUncompressedSize())
		require.NoError(t, err)
		return body
	}
	require.Equal(t, edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE, record.GetCompression())
	return record.GetPayload()
}

func flushJourneySpoolToIngest(
	t *testing.T,
	sp *RecordSpool,
	client edgev1.EdgeRecordIngestServiceClient,
) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var cursor RecordSpoolCursor
	for {
		src, ok := sp.NextSource(&cursor)
		if !ok {
			break
		}
		sender, err := edgesender.New(src.Source, client, edgesender.Config{
			SpoolID:                 src.Identity.SpoolID,
			RouteProfile:            src.Identity.Lane.RouteProfile,
			TrafficClass:            src.Identity.Lane.TrafficClass,
			RequestedByteCredits:    4 << 20,
			RequestedFrameCredits:   64,
			PersistAcknowledgements: true,
		})
		require.NoError(t, err)

		runRes, err := sender.RunOnce(ctx)
		if errors.Is(err, edgesender.ErrNoUnresolvedRecords) {
			continue
		}
		require.NoError(t, err)
		require.NotEmpty(t, runRes.Dispositions)
		for _, disp := range runRes.Dispositions {
			require.Equal(t, edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, disp.GetKind())
		}
		require.NoError(t, src.Source.ReclaimResolved())

		var remaining int
		require.NoError(t, src.Source.ScanFrom(src.Source.Resolved()+1, func(spool.Record) bool {
			remaining++
			return true
		}))
		require.Zero(t, remaining, "all spooled records should be reclaimed after ACCEPTED_AUTHORITATIVE ack")
	}
}

// newJourneyPipelineTestMux serves the synthetic SSO login, redirect, callback,
// failure and numbered step endpoints the durable pipeline journeys exercise.
func newJourneyPipelineTestMux(apiToken, password, csrfSecret, sidSecret, querySecret string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+apiToken {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), password) {
			http.Error(w, "missing password", http.StatusBadRequest)
			return
		}
		w.Header().Add("Set-Cookie", "sid="+sidSecret+"; Expires=Thu, 21 Oct 2027 07:28:00 GMT; Path=/; Secure")
		w.Header().Add("Set-Cookie", "prefs=compact; Path=/")
		w.Header().Set("Location", "/callback?code="+querySecret+"&state=xyz#frag")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusFound)
		_, _ = w.Write([]byte(`{"ok":true,"csrf":"` + csrfSecret + `"}`))
	})
	mux.HandleFunc("/redirect", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/callback?code="+querySecret+"&state=xyz#frag", http.StatusFound)
	})
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-CSRF") != csrfSecret {
			http.Error(w, "missing csrf", http.StatusForbidden)
			return
		}
		cookieHdr := r.Header.Get("Cookie")
		if !strings.Contains(cookieHdr, "sid="+sidSecret) || !strings.Contains(cookieHdr, "prefs=compact") {
			http.Error(w, "missing session cookies", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"authenticated":true,"role":"operator"}`))
	})
	mux.HandleFunc("/fail", func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "upstream unavailable", http.StatusServiceUnavailable)
	})
	mux.HandleFunc("/step", func(w http.ResponseWriter, r *http.Request) {
		stepIdx := r.URL.Query().Get("n")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, `{"ok":true,"step":%s}`, stepIdx)
	})

	return mux
}

func TestHTTPSyntheticJourneyDurableEdgePipelineE2E(t *testing.T) {
	wasmPath := locateJourneyRunfile(t, "build/wasm_plugins/http_synthetic_journey.wasm")
	wasm, err := os.ReadFile(wasmPath)
	require.NoError(t, err)
	entrypoint, caps := loadJourneyManifestCapabilities(t)

	const (
		agentID       = "agent-synthetic-e2e"
		assignmentID  = "assign-http-journey-e2e"
		webPropertyID = "00000000-0000-4000-8000-000000000772"
		apiToken      = "tok-pipeline-secret-9012"
		password      = "pw-pipeline-secret-3456"
		csrfSecret    = "csrf-pipeline-secret-7890"
		sidSecret     = "sid-pipeline-secret-1234"
		querySecret   = "auth-code-secret-6543"
	)

	mux := newJourneyPipelineTestMux(apiToken, password, csrfSecret, sidSecret, querySecret)

	tlsSrv := httptest.NewTLSServer(mux)
	defer tlsSrv.Close()

	host, portText, err := net.SplitHostPort(tlsSrv.Listener.Addr().String())
	require.NoError(t, err)
	port, err := strconv.Atoi(portText)
	require.NoError(t, err)

	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger:     logger.NewTestLogger(),
		HTTPClient: tlsSrv.Client(),
	})
	defer manager.Stop()

	allocator, err := spool.NewAllocator(spool.AllocatorConfig{
		Capacity:                1 << 30,
		MinFree:                 1 << 20,
		MaxConcurrentRecoveries: 1,
		Recovery:                spool.DefaultRecoveryFootprint(),
	})
	require.NoError(t, err)
	sp, err := OpenRecordSpool(t.TempDir(), allocator)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })

	loop := &PushLoop{
		server: &Server{
			config:        &ServerConfig{AgentID: agentID, Partition: "default"},
			pluginManager: manager,
		},
		logger: logger.NewTestLogger(),
	}
	loop.SetEdgePluginResultSpool(sp)
	loop.SetEdgeTelemetrySpool(sp)
	installJourneyGrantsAndTrust(t, loop, sp, agentID)

	ingestSrv := &journeyPipelineIngestServer{}
	ingestClient := dialJourneyIngestBufconn(t, ingestSrv)

	perms := pluginPermissions{
		AllowedDomains:  []string{host},
		AllowedNetworks: []string{host + "/32"},
		AllowedPorts:    []int{port},
	}
	perms.normalize()

	runJourney := func(name string, configJSON []byte) {
		assignment := &pluginAssignment{
			AssignmentID: assignmentID,
			PluginID:     "http-synthetic-journey",
			Name:         name,
			Entrypoint:   entrypoint,
			Runtime:      "wasi-preview1",
			ParamsJSON:   configJSON,
			Capabilities: caps,
			Permissions:  perms,
			Resources: pluginResources{
				RequestedMemoryMB:  64,
				MaxOpenConnections: 4,
			},
			Timeout: 15 * time.Second,
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		require.NoError(t, manager.executeWithWasm(ctx, assignment, pluginModule{wasm: wasm}))
		require.True(t, loop.pushPluginResults(), "pushPluginResults should spool plugin result")
		require.True(t, loop.pushPluginSignals(), "pushPluginSignals should spool telemetry batch")
		flushJourneySpoolToIngest(t, sp, ingestClient)
	}

	t.Run("healthy multi-step TLS journey commits PluginResults and TelemetryBatch", func(t *testing.T) {
		healthyConfig := fmt.Sprintf(`{
			"journey_name": "tls-sso-journey",
			"web_property_id": %q,
			"device_id": "sr:device-pipeline-1",
			"target_ip": %q,
			"username": "synthetic-operator",
			"password": %q,
			"api_token": %q,
			"steps": [
				{
					"name": "login",
					"method": "POST",
					"url": %q,
					"headers": {"Authorization": "Bearer {{api_token}}"},
					"body": "{\"user\":\"{{username}}\",\"pass\":\"{{password}}\"}",
					"content_type": "application/json",
					"follow_redirects": false,
					"expect_status": [302],
					"expect_json_fields": [{"pointer": "/ok", "expected": "true", "value_type": "boolean"}],
					"extract_json_fields": [{"pointer": "/csrf", "var": "csrf_tok"}]
				},
				{
					"name": "redirect-callback",
					"method": "GET",
					"url": %q,
					"headers": {
						"X-CSRF": "{{csrf_tok}}",
						"Authorization": "Bearer {{api_token}}"
					},
					"follow_redirects": true,
					"expect_status": [200],
					"expect_json_fields": [
						{"pointer": "/authenticated", "expected": "true", "value_type": "boolean"},
						{"pointer": "/role", "expected": "operator", "value_type": "string"}
					],
					"min_cert_days_warn": 1,
					"min_cert_days_crit": 0
				}
			]
		}`, webPropertyID, host, password, apiToken, tlsSrv.URL+"/login", tlsSrv.URL+"/redirect")

		runJourney("healthy-journey", []byte(healthyConfig))

		records := ingestSrv.drainRecords()
		require.Len(t, records, 2)

		var pluginBatch *edgev1.WasmPluginResultBatchV1
		var teleBatch *addonpb.TelemetryBatch
		for _, rec := range records {
			switch rec.GetOutputContract().GetContractId() {
			case edgerecord.PluginResultsContractID:
				require.NoError(t, edgerecord.ValidatePluginResultRecord(rec))
				pluginBatch = &edgev1.WasmPluginResultBatchV1{}
				require.NoError(t, gproto.Unmarshal(decodeJourneyRecordBody(t, rec), pluginBatch))
			case edgerecord.TelemetryBatchContractID:
				require.NoError(t, edgerecord.ValidateTelemetryBatchRecord(rec))
				teleBatch = &addonpb.TelemetryBatch{}
				require.NoError(t, gproto.Unmarshal(decodeJourneyRecordBody(t, rec), teleBatch))
			default:
				t.Fatalf("unexpected contract id %q", rec.GetOutputContract().GetContractId())
			}
		}

		require.NotNil(t, pluginBatch)
		require.Len(t, pluginBatch.GetResults(), 1)
		item := pluginBatch.GetResults()[0]
		require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK, item.GetStatus())
		require.Equal(t, webPropertyID, item.GetLabels()["web_property_id"])
		require.Equal(t, assignmentID, item.GetLabels()["assignment_id"])
		require.Equal(t, "http-synthetic-journey", item.GetLabels()["plugin_id"])

		var hasStatCard, hasWaterfallTable bool
		for _, widget := range item.GetDisplay() {
			switch widget.GetWidget() {
			case "stat_card":
				hasStatCard = true
			case "table":
				hasWaterfallTable = true
				require.Contains(t, string(widget.GetDataJson()), "01. login")
				require.Contains(t, string(widget.GetDataJson()), "02. redirect-callback")
			}
		}
		require.True(t, hasStatCard, "expected stat_card display widgets")
		require.True(t, hasWaterfallTable, "expected waterfall table display widget")

		rawPluginBatch, err := gproto.Marshal(pluginBatch)
		require.NoError(t, err)
		for _, secret := range []string{apiToken, password, csrfSecret, sidSecret, querySecret} {
			require.NotContains(t, string(rawPluginBatch), secret, "plugin result leaked secret")
		}

		require.NotNil(t, teleBatch)
		producerType, producerID, ok := edgerecord.TelemetryBatchProducer(teleBatch)
		require.True(t, ok)
		require.Equal(t, "plugin", producerType)
		require.Equal(t, assignmentID, producerID)
		require.Len(t, teleBatch.GetRecords(), 1)
		require.Equal(t, addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS, teleBatch.GetRecords()[0].GetPayloadKind())

		var metricBatch metricpb.MetricBatch
		require.NoError(t, gproto.Unmarshal(teleBatch.GetRecords()[0].GetPayload(), &metricBatch))
		require.Equal(t, "serviceradar.metric.v1", metricBatch.GetSchemaVersion())

		rawMetricBatch := string(teleBatch.GetRecords()[0].GetPayload())
		for _, secret := range []string{apiToken, password, csrfSecret, sidSecret, querySecret} {
			require.NotContains(t, rawMetricBatch, secret, "metric batch leaked secret")
		}

		seenMetrics := map[string]bool{}
		for _, metric := range metricBatch.GetMetrics() {
			require.Equal(t, "synthetic", metric.GetMetricType())
			seenMetrics[metric.GetName()] = true
			for _, pt := range metric.GetPoints() {
				attrs := map[string]string{}
				for _, entry := range pt.GetAttributes() {
					attrs[entry.GetKey()] = entry.GetValue()
				}
				require.Equal(t, webPropertyID, attrs["web_property_id"], "metric %s missing web_property_id point attribute", metric.GetName())
				require.Equal(t, "tls-sso-journey", attrs["journey"])
			}
		}

		for _, expectedMetric := range []string{
			"synthetic.journey.available",
			"synthetic.journey.duration_ms",
			"synthetic.journey.steps_completed",
			"synthetic.step.duration_ms",
			"synthetic.step.dns_ms",
			"synthetic.step.connect_ms",
			"synthetic.step.tls_ms",
			"synthetic.step.ttfb_ms",
			"synthetic.step.transfer_ms",
			"synthetic.step.tls_cert_days_remaining",
		} {
			require.True(t, seenMetrics[expectedMetric], "missing canonical metric %s", expectedMetric)
		}
	})

	t.Run("failing step short-circuits downstream steps and marks journey unavailable", func(t *testing.T) {
		failingConfig := fmt.Sprintf(`{
			"journey_name": "failing-journey",
			"web_property_id": %q,
			"steps": [
				{
					"name": "broken-step",
					"method": "GET",
					"url": %q,
					"expect_status": [200]
				},
				{
					"name": "downstream-step",
					"method": "GET",
					"url": %q,
					"expect_status": [200]
				}
			]
		}`, webPropertyID, tlsSrv.URL+"/fail", tlsSrv.URL+"/redirect")

		runJourney("failing-journey", []byte(failingConfig))

		records := ingestSrv.drainRecords()
		require.Len(t, records, 2)

		var pluginBatch *edgev1.WasmPluginResultBatchV1
		var teleBatch *addonpb.TelemetryBatch
		for _, rec := range records {
			switch rec.GetOutputContract().GetContractId() {
			case edgerecord.PluginResultsContractID:
				pluginBatch = &edgev1.WasmPluginResultBatchV1{}
				require.NoError(t, gproto.Unmarshal(decodeJourneyRecordBody(t, rec), pluginBatch))
			case edgerecord.TelemetryBatchContractID:
				teleBatch = &addonpb.TelemetryBatch{}
				require.NoError(t, gproto.Unmarshal(decodeJourneyRecordBody(t, rec), teleBatch))
			}
		}

		require.NotNil(t, pluginBatch)
		item := pluginBatch.GetResults()[0]
		require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_CRITICAL, item.GetStatus())
		require.True(t, item.GetAlertHint())
		require.NotEmpty(t, item.GetEvents())

		var foundSkipped bool
		for _, w := range item.GetDisplay() {
			if w.GetWidget() == "table" && strings.Contains(string(w.GetDataJson()), "SKIPPED") {
				foundSkipped = true
			}
		}
		require.True(t, foundSkipped, "expected SKIPPED downstream step in waterfall table")

		var metricBatch metricpb.MetricBatch
		require.NoError(t, gproto.Unmarshal(teleBatch.GetRecords()[0].GetPayload(), &metricBatch))
		var availVal *float64
		for _, m := range metricBatch.GetMetrics() {
			if m.GetName() == "synthetic.journey.available" {
				v := m.GetPoints()[0].GetValue()
				availVal = &v
			}
		}
		require.NotNil(t, availVal)
		require.InDelta(t, 0.0, *availVal, 0)
	})

	t.Run("64-step journey stays within 64 MiB limit and 512 KiB protobuf payload cap", func(t *testing.T) {
		steps := make([]map[string]any, 0, 64)
		for i := 1; i <= 64; i++ {
			steps = append(steps, map[string]any{
				"name":          fmt.Sprintf("step-%02d", i),
				"method":        "GET",
				"url":           fmt.Sprintf("%s/step?n=%d", tlsSrv.URL, i),
				"expect_status": []int{200},
				"expect_json_fields": []map[string]any{
					{"pointer": "/ok", "expected": "true", "value_type": "boolean"},
					{"pointer": "/step", "expected": strconv.Itoa(i), "value_type": "number"},
				},
			})
		}
		cfg64, err := json.Marshal(map[string]any{
			"journey_name":    "pipeline-64-step",
			"web_property_id": webPropertyID,
			"device_id":       "sr:device-pipeline-64",
			"target_ip":       host,
			"emit_telemetry":  true,
			"steps":           steps,
		})
		require.NoError(t, err)

		runJourney("64-step-journey", cfg64)

		records := ingestSrv.drainRecords()
		require.Len(t, records, 2)

		var pluginBatch *edgev1.WasmPluginResultBatchV1
		var teleBatch *addonpb.TelemetryBatch
		for _, rec := range records {
			body := decodeJourneyRecordBody(t, rec)
			require.Less(t, len(body), edgeMetricsMaxPayloadBytes, "record %s exceeded 512 KiB protobuf cap", rec.GetOutputContract().GetContractId())
			switch rec.GetOutputContract().GetContractId() {
			case edgerecord.PluginResultsContractID:
				require.NoError(t, edgerecord.ValidatePluginResultRecord(rec))
				pluginBatch = &edgev1.WasmPluginResultBatchV1{}
				require.NoError(t, gproto.Unmarshal(body, pluginBatch))
			case edgerecord.TelemetryBatchContractID:
				require.NoError(t, edgerecord.ValidateTelemetryBatchRecord(rec))
				teleBatch = &addonpb.TelemetryBatch{}
				require.NoError(t, gproto.Unmarshal(body, teleBatch))
			default:
				t.Fatalf("unexpected contract id %q", rec.GetOutputContract().GetContractId())
			}
		}

		require.NotNil(t, pluginBatch)
		require.Len(t, pluginBatch.GetResults(), 1)
		require.Equal(t, edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK, pluginBatch.GetResults()[0].GetStatus())

		require.NotNil(t, teleBatch)
		var metricBatch metricpb.MetricBatch
		require.NoError(t, gproto.Unmarshal(teleBatch.GetRecords()[0].GetPayload(), &metricBatch))
		var stepsCompleted float64
		for _, m := range metricBatch.GetMetrics() {
			if m.GetName() == "synthetic.journey.steps_completed" {
				stepsCompleted = m.GetPoints()[0].GetValue()
			}
		}
		require.InDelta(t, 64.0, stepsCompleted, 0)
	})
}
