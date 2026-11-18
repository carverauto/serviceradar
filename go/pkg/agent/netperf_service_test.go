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
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/netperf"
	"github.com/carverauto/serviceradar/proto"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

func TestAgentCapabilitiesAdvertiseNetperf(t *testing.T) {
	t.Parallel()

	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)

	enrollReq := loop.buildEnrollmentHelloRequest()
	require.Contains(t, enrollReq.GetCapabilities(), capabilityNetperf)

	controlReq := loop.buildControlHelloRequest()
	require.Contains(t, controlReq.GetHello().GetCapabilities(), capabilityNetperf)
}

func TestNetperfSlotOffsetDeterministicSpread(t *testing.T) {
	t.Parallel()

	const interval = uint32(900)
	first := netperfSlotOffset("pol-1", "hub-1", "spoke-1", interval)
	again := netperfSlotOffset("pol-1", "hub-1", "spoke-1", interval)
	require.Equal(t, first, again)
	require.GreaterOrEqual(t, first, time.Duration(0))
	require.Less(t, first, time.Duration(interval)*time.Second)

	offsets := make(map[time.Duration]struct{})
	for i := range 50 {
		off := netperfSlotOffset("pol-1", "hub-1", "spoke-"+strconv.Itoa(i), interval)
		offsets[off] = struct{}{}
	}
	require.Greater(t, len(offsets), 25, "distinct tuples should spread across interval")
}

func TestNetperfConfigHotApplyLifecycleAndNotModifiedTrustRetention(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	now := time.Now().UTC()
	caTpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Synthetic Netperf Agent CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	require.NoError(t, err)
	caCert, err := x509.ParseCertificate(caDER)
	require.NoError(t, err)
	caFile := filepath.Join(dir, "root.pem")
	require.NoError(t, os.WriteFile(caFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o644))

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	dns := sysmonEdgeAgentID + ".default.serviceradar"
	spiffe, err := url.Parse("spiffe://serviceradar.local/agent/default/" + sysmonEdgeAgentID)
	require.NoError(t, err)
	leafTpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: dns},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(12 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{dns},
		URIs:         []*url.URL{spiffe},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTpl, caCert, &leafKey.PublicKey, caKey)
	require.NoError(t, err)
	pkcs8, err := x509.MarshalPKCS8PrivateKey(leafKey)
	require.NoError(t, err)
	certFile := filepath.Join(dir, "agent.pem")
	keyFile := filepath.Join(dir, "agent-key.pem")
	require.NoError(t, os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}), 0o644))
	require.NoError(t, os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0o600))

	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	loop.server.config.Partition = "default"
	loop.server.config.GatewaySecurity = &models.SecurityConfig{
		Mode: models.SecurityModeMTLS,
		TLS: models.TLSConfig{
			CertFile: certFile,
			KeyFile:  keyFile,
			CAFile:   caFile,
		},
	}

	svc := loop.ensureNetperfService()
	var startCalls int
	svc.startRespFn = func(ctx context.Context, cfg netperf.ResponderConfig) (*netperf.Responder, error) {
		startCalls++
		cfg.ListenAddress = "127.0.0.1"
		cfg.ListenPort = 0
		cfg.AllowEphemeralPort = true
		r, err := netperf.NewResponder(cfg)
		if err != nil {
			return nil, err
		}
		if err := r.Start(ctx); err != nil {
			return nil, err
		}
		return r, nil
	}

	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	trustRaw, err := json.Marshal(map[string]any{
		"clock_tolerance_nano": int64(300_000_000_000),
		"keys": []map[string]any{{
			"issuer_id":     []byte("serviceradar-core"),
			"issuer_key_id": []byte("0123456789abcdef"),
			"public_key":    key.Public().(ed25519.PublicKey),
			"purposes":      []string{"production"},
			"status":        "valid",
		}},
		"fences":             []any{},
		"scopes":             []any{},
		"terminal_intervals": []any{},
	})
	require.NoError(t, err)

	// v1: enable responder on 5199 TCP+UDP
	require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:           "v1",
		EdgeRecordTrustDocument: trustRaw,
		NetperfConfig: &netperfpb.NetperfConfig{
			Responder: &netperfpb.NetperfResponderConfig{
				Enabled:               true,
				ListenPort:            5199,
				UdpEnabled:            true,
				MaxConcurrentSessions: 4,
				MaxTotalBandwidthBps:  1_000_000_000,
				MinAuthorityEpoch:     2,
			},
		},
	}, "control_stream", loop.nextConfigSequence()))
	require.Equal(t, 1, startCalls)
	require.NotNil(t, loop.EdgeRecordTrustSnapshot())
	require.NotNil(t, svc.responder)
	require.NotEmpty(t, svc.responder.ListenAddr())

	// NotModified retains TrustSnapshot and does not restart responder
	require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion: "v1",
		NotModified:   true,
	}, "poll", loop.nextConfigSequence()))
	require.Equal(t, 1, startCalls)
	require.NotNil(t, loop.EdgeRecordTrustSnapshot())

	// v2: same listener port/UDP, bumped min_authority_epoch & max_concurrent_sessions -> updates in place without restart
	prevResp := svc.responder
	require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:           "v2",
		EdgeRecordTrustDocument: trustRaw,
		NetperfConfig: &netperfpb.NetperfConfig{
			Responder: &netperfpb.NetperfResponderConfig{
				Enabled:               true,
				ListenPort:            5199,
				UdpEnabled:            true,
				MaxConcurrentSessions: 8,
				MaxTotalBandwidthBps:  2_000_000_000,
				MinAuthorityEpoch:     5,
			},
		},
	}, "control_stream", loop.nextConfigSequence()))
	require.Equal(t, 1, startCalls)
	require.Same(t, prevResp, svc.responder)

	// v3: disable responder -> closes listener dynamically
	require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:           "v3",
		EdgeRecordTrustDocument: trustRaw,
		NetperfConfig: &netperfpb.NetperfConfig{
			Responder: &netperfpb.NetperfResponderConfig{Enabled: false},
		},
	}, "control_stream", loop.nextConfigSequence()))
	require.Nil(t, svc.responder)
}

func TestControlStreamNetperfRunPreemptsSpoolsBeforeResultAndRejectsConcurrent(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	svc := loop.ensureNetperfService()

	schedStarted := make(chan struct{})
	schedCanceled := make(chan struct{})
	onDemandStarted := make(chan struct{})
	onDemandRelease := make(chan struct{})

	var callMu sync.Mutex
	var sources []netperfpb.NetperfExecutionSource

	svc.runSenderFn = func(ctx context.Context, req netperf.TestRequest) (*netperf.TestResult, error) {
		callMu.Lock()
		sources = append(sources, req.ExecutionSource)
		callMu.Unlock()

		if req.ExecutionSource == netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_SCHEDULED_POLICY {
			close(schedStarted)
			<-ctx.Done()
			close(schedCanceled)
			return &netperf.TestResult{
				Available:        false,
				Error:            ctx.Err().Error(),
				ResponderAgentID: req.ResponderAgentID,
				Protocol:         req.Protocol,
				Direction:        req.Direction,
				ExecutionSource:  req.ExecutionSource,
			}, ctx.Err()
		}

		// Check that RecordSpool has NOT yet received this run's batch while test is executing.
		require.Empty(t, spooledMetricBatches(t, sp))
		close(onDemandStarted)
		<-onDemandRelease

		return &netperf.TestResult{
			Available:        true,
			Target:           req.TargetAddress + ":5199",
			ResponderAgentID: req.ResponderAgentID,
			PolicyID:         req.PolicyID,
			Protocol:         req.Protocol,
			Direction:        req.Direction,
			Parallel:         req.Parallel,
			ExecutionSource:  req.ExecutionSource,
			Primary: netperf.PhaseResult{
				Direction:       req.Direction,
				DurationSeconds: 1.0,
				BytesSent:       500_000,
				BytesReceived:   500_000,
				BitsPerSecond:   4_000_000,
			},
			Upload: &netperf.PhaseResult{
				Direction:       netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
				DurationSeconds: 1.0,
				BytesSent:       500_000,
				BytesReceived:   500_000,
				BitsPerSecond:   4_000_000,
			},
		}, nil
	}

	require.NoError(t, svc.Start(context.Background()))
	t.Cleanup(func() { _ = svc.Stop(context.Background()) })

	// Install a due scheduled target to simulate an in-flight scheduled run.
	svc.mu.Lock()
	svc.targets = []*scheduledNetperfTarget{{
		key:      "sched-1",
		interval: 60 * time.Second,
		nextRun:  time.Now().Add(-time.Second),
		assignment: &netperfpb.NetperfTargetAssignment{
			PolicyId:         "pol-sched",
			ProfileId:        "prof-sched",
			ResponderAgentId: "agent-hub-01",
			TargetAddress:    "192.0.2.10",
			TargetPort:       5199,
			Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
			Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			BandwidthBps:     10_000_000,
			DurationSec:      5,
			Parallel:         1,
			IntervalSeconds:  60,
			Permit: &netperfpb.NetperfPermitV1{
				PermitId:         "permit-sched-1",
				ResponderAgentId: "agent-hub-01",
				SenderAgentId:    sysmonEdgeAgentID,
			},
		},
	}}
	svc.mu.Unlock()
	svc.wakeScheduler()

	<-schedStarted

	permit := &netperfpb.NetperfPermitV1{
		PermitVersion:    1,
		PermitId:         "permit-ondemand-1",
		PartitionId:      "default",
		SenderAgentId:    sysmonEdgeAgentID,
		ResponderAgentId: "agent-hub-01",
		PolicyId:         "on_demand:cmd-1",
	}
	permitBytes, err := gproto.Marshal(permit)
	require.NoError(t, err)

	payloadBytes, err := json.Marshal(netperfRunPayload{
		PermitID:         "permit-ondemand-1",
		ResponderAgentID: "agent-hub-01",
		TargetAddress:    "192.0.2.10",
		TargetPort:       5199,
		Protocol:         "tcp",
		Direction:        "upload",
		BandwidthBps:     10_000_000,
		DurationSec:      1,
		OmitSec:          0,
		Parallel:         1,
		ExecutionSource:  "on_demand",
		PermitB64:        base64.StdEncoding.EncodeToString(permitBytes),
	})
	require.NoError(t, err)

	fakeStream := &fakeControlStreamClient{}
	sender := &controlStreamSender{stream: fakeStream}

	var onDemandWG sync.WaitGroup
	onDemandWG.Add(1)
	go func() {
		defer onDemandWG.Done()
		loop.handleNetperfRun(context.Background(), &proto.CommandRequest{
			CommandId:   "cmd-1",
			CommandType: commandTypeNetperfRun,
			PayloadJson: payloadBytes,
			CreatedAt:   time.Now().Unix(),
			TtlSeconds:  60,
		}, sender)
	}()

	<-schedCanceled
	<-onDemandStarted

	// Concurrent second netperf.run must be rejected immediately as busy.
	fakeStream2 := &fakeControlStreamClient{}
	loop.handleNetperfRun(context.Background(), &proto.CommandRequest{
		CommandId:   "cmd-2",
		CommandType: commandTypeNetperfRun,
		PayloadJson: payloadBytes,
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  60,
	}, &controlStreamSender{stream: fakeStream2})

	require.Len(t, fakeStream2.sent, 1)
	res2 := fakeStream2.sent[0].GetCommandResult()
	require.NotNil(t, res2)
	require.False(t, res2.GetSuccess())
	require.Contains(t, res2.GetMessage(), "busy")

	// Release first on-demand run and verify RecordSpool has the batch when CommandResult is emitted!
	close(onDemandRelease)
	onDemandWG.Wait()

	// Find CommandResult on fakeStream.
	var cmdRes *proto.CommandResult
	for _, msg := range fakeStream.sent {
		if r := msg.GetCommandResult(); r != nil {
			cmdRes = r
		}
	}
	require.NotNil(t, cmdRes)
	require.True(t, cmdRes.GetSuccess())

	batches := spooledMetricBatches(t, sp)
	require.Len(t, batches, 1, "on-demand result must be committed to RecordSpool before CommandResult")
	require.Equal(t, "rperf-metrics", batches[0].GetIngestIdentity().GetSource())
	require.Equal(t, "agent", batches[0].GetIngestIdentity().GetProducerKind())

	// Scheduled run was preempted -> no false rperf.available=0 sample queued.
	require.Empty(t, svc.DrainSamples())
	require.Zero(t, rperfMetricStatuses(loop.collectAllStatuses(context.Background())))

	callMu.Lock()
	defer callMu.Unlock()
	require.True(t, slices.Contains(sources, netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_ON_DEMAND))
}

func TestNetperfScheduledBusyReschedulesWithoutFalseFailureSample(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	svc := loop.ensureNetperfService()

	var calls atomic.Int32
	done := make(chan struct{})
	svc.runSenderFn = func(_ context.Context, req netperf.TestRequest) (*netperf.TestResult, error) {
		if calls.Add(1) == 1 {
			close(done)
		}
		return &netperf.TestResult{
			Available:        false,
			BusyExhausted:    true,
			RetryAfterMs:     3000,
			ResponderAgentID: req.ResponderAgentID,
		}, netperf.ErrResponderBusy
	}

	require.NoError(t, svc.Start(context.Background()))
	t.Cleanup(func() { _ = svc.Stop(context.Background()) })

	svc.mu.Lock()
	svc.targets = []*scheduledNetperfTarget{{
		key:      "sched-busy",
		interval: 900 * time.Second,
		nextRun:  time.Now().Add(-time.Second),
		assignment: &netperfpb.NetperfTargetAssignment{
			PolicyId:         "pol-busy",
			ResponderAgentId: "agent-hub-01",
			TargetAddress:    "192.0.2.10",
			Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
			Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			IntervalSeconds:  900,
			Permit:           &netperfpb.NetperfPermitV1{PermitId: "p1", ResponderAgentId: "agent-hub-01", SenderAgentId: sysmonEdgeAgentID},
		},
	}}
	svc.mu.Unlock()
	svc.wakeScheduler()

	<-done
	// Give scheduler loop a brief moment to process busy reschedule.
	require.Eventually(t, func() bool {
		svc.mu.Lock()
		defer svc.mu.Unlock()
		return svc.targets[0].busyRetries == 1 && svc.targets[0].nextRun.After(time.Now())
	}, 2*time.Second, 20*time.Millisecond)
	require.Empty(t, svc.DrainSamples(), "BusyExhausted must not emit false rperf.available=0")
}
