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
	"errors"
	"math/big"
	"net"
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

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/netperf"
	"github.com/carverauto/serviceradar/proto"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

const netperfTestLoopback = "127.0.0.1"

var errTransientBindFailure = errors.New("transient bind failure")

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
	loop.server.config.Partition = defaultPartition
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
		cfg.ListenAddress = netperfTestLoopback
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
		PartitionId:      defaultPartition,
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

func TestNetperfConcurrentApplyConfigAndSchedulerNoRace(t *testing.T) {
	t.Parallel()

	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	svc := loop.ensureNetperfService()

	var runs atomic.Int32
	svc.runSenderFn = func(_ context.Context, req netperf.TestRequest) (*netperf.TestResult, error) {
		runs.Add(1)
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
				BytesSent:       100_000,
				BytesReceived:   100_000,
				BitsPerSecond:   800_000,
			},
		}, nil
	}

	require.NoError(t, svc.Start(context.Background()))
	t.Cleanup(func() { _ = svc.Stop(context.Background()) })

	makeCfg := func(bw uint64) *netperfpb.NetperfConfig {
		return &netperfpb.NetperfConfig{
			Targets: []*netperfpb.NetperfTargetAssignment{{
				PolicyId:         "pol-race",
				ProfileId:        "prof-race",
				ResponderAgentId: "agent-hub-01",
				TargetAddress:    "192.0.2.10",
				TargetPort:       5199,
				Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
				Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
				BandwidthBps:     bw,
				DurationSec:      1,
				Parallel:         1,
				IntervalSeconds:  60,
				Permit: &netperfpb.NetperfPermitV1{
					PermitId:         "permit-race-1",
					ResponderAgentId: "agent-hub-01",
					SenderAgentId:    sysmonEdgeAgentID,
				},
			}},
		}
	}

	// Seed immediately due target, then concurrently mutate via ApplyConfig while scheduler executes.
	svc.ApplyConfig(context.Background(), makeCfg(1_000_000))
	svc.mu.Lock()
	svc.targets[0].nextRun = time.Now().Add(-time.Second)
	svc.mu.Unlock()
	svc.wakeScheduler()

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := range 200 {
			if ctx.Err() != nil {
				return
			}
			svc.ApplyConfig(context.Background(), makeCfg(uint64(1_000_000+i*1000)))
			svc.mu.Lock()
			if len(svc.targets) > 0 {
				svc.targets[0].nextRun = time.Now().Add(-time.Millisecond)
			}
			svc.mu.Unlock()
			svc.wakeScheduler()
			time.Sleep(time.Millisecond)
		}
	}()
	wg.Wait()
	require.GreaterOrEqual(t, runs.Load(), int32(1))
}

func makeNetperfAgentPKI(t *testing.T, agentID string, serial int64, caCert *x509.Certificate, caKey *ecdsa.PrivateKey, caFile, dir string) *models.SecurityConfig {
	t.Helper()
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	dns := agentID + ".default.serviceradar"
	spiffe, err := url.Parse("spiffe://serviceradar.local/agent/default/" + agentID)
	require.NoError(t, err)
	now := time.Now().UTC()
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: dns},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(12 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{dns},
		URIs:         []*url.URL{spiffe},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &leafKey.PublicKey, caKey)
	require.NoError(t, err)
	pkcs8, err := x509.MarshalPKCS8PrivateKey(leafKey)
	require.NoError(t, err)
	certFile := filepath.Join(dir, agentID+".pem")
	keyFile := filepath.Join(dir, agentID+"-key.pem")
	require.NoError(t, os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644))
	require.NoError(t, os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0o600))
	return &models.SecurityConfig{
		Mode: models.SecurityModeMTLS,
		TLS: models.TLSConfig{
			CertFile: certFile,
			KeyFile:  keyFile,
			CAFile:   caFile,
		},
	}
}

func TestNetperfRealSenderResponderPreemption(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name     string
		proto    netperfpb.NetperfProtocol
		protoStr string
	}{
		{"tcp_download_preemption", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP, "tcp"},
		{"udp_download_preemption", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP, "udp"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			dir := t.TempDir()
			caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			require.NoError(t, err)
			now := time.Now().UTC()
			caTpl := &x509.Certificate{
				SerialNumber:          big.NewInt(1),
				Subject:               pkix.Name{CommonName: "Synthetic Netperf Preemption CA"},
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

			hubSec := makeNetperfAgentPKI(t, "agent-hub-01", 10, caCert, caKey, caFile, dir)
			spokeSec := makeNetperfAgentPKI(t, sysmonEdgeAgentID, 11, caCert, caKey, caFile, dir)

			_, priv, err := ed25519.GenerateKey(nil)
			require.NoError(t, err)
			pub := priv.Public().(ed25519.PublicKey)
			keyID := []byte("0123456789abcdef")

			trustRaw, err := json.Marshal(map[string]any{
				"clock_tolerance_nano": int64(300_000_000_000),
				"keys": []map[string]any{{
					"issuer_id":     []byte("serviceradar-core"),
					"issuer_key_id": keyID,
					"public_key":    pub,
					"purposes":      []string{"production"},
					"status":        "valid",
				}},
				"fences":             []any{},
				"scopes":             []any{},
				"terminal_intervals": []any{},
			})
			require.NoError(t, err)
			snap, err := edgerecord.ParseTrustDocument(trustRaw, []byte("agent-hub-01"), 1)
			require.NoError(t, err)

			resp, err := netperf.NewResponder(netperf.ResponderConfig{
				AgentID:               "agent-hub-01",
				PartitionID:           "default",
				ListenAddress:         netperfTestLoopback,
				AllowEphemeralPort:    true,
				UDPEnabled:            true,
				MaxConcurrentSessions: 4,
				MaxTotalBandwidthBps:  100_000_000,
				MinAuthorityEpoch:     1,
				Security:              hubSec,
				KeyResolver:           netperf.TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return snap }},
				Logger:                logger.NewTestLogger(),
			})
			require.NoError(t, err)
			require.NoError(t, resp.Start(context.Background()))
			t.Cleanup(func() { _ = resp.Close() })

			host, portStr, err := net.SplitHostPort(resp.ListenAddr())
			require.NoError(t, err)
			port64, err := strconv.ParseUint(portStr, 10, 32)
			require.NoError(t, err)
			port := uint32(port64)

			sp := openTestEdgeSpool(t)
			loop, _ := sysmonEdgeLoop(t, sp)
			loop.server.config.Partition = defaultPartition
			loop.server.config.GatewaySecurity = spokeSec
			installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

			svc := loop.ensureNetperfService()
			require.NoError(t, svc.Start(context.Background()))
			t.Cleanup(func() { _ = svc.Stop(context.Background()) })

			signPermit := func(id string, maxDur uint32) *netperfpb.NetperfPermitV1 {
				p := &netperfpb.NetperfPermitV1{
					PermitVersion:    1,
					PermitId:         id,
					PartitionId:      defaultPartition,
					SenderAgentId:    sysmonEdgeAgentID,
					ResponderAgentId: "agent-hub-01",
					PolicyId:         "pol-preempt",
					MaxBandwidthBps:  20_000_000,
					MaxDurationSec:   maxDur,
					MaxParallel:      2,
					AllowedProtocols: []netperfpb.NetperfProtocol{
						netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
						netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
					},
					AllowedDirections: []netperfpb.NetperfDirection{
						netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
						netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
					},
					IssuedAtUnix:   now.Unix() - 60,
					ExpiresAtUnix:  now.Unix() + 600,
					AuthorityEpoch: 1,
					IssuerId:       "serviceradar-core",
					IssuerKeyId:    keyID,
					Algorithm:      "ed25519",
				}
				p.Signature = ed25519.Sign(priv, netperf.CanonicalPermitPreimage(p))
				return p
			}

			// Start a 10s scheduled download with the real netperf.Sender.
			svc.mu.Lock()
			svc.targets = []*scheduledNetperfTarget{{
				key:      "sched-real",
				interval: 60 * time.Second,
				nextRun:  time.Now().Add(-time.Second),
				assignment: &netperfpb.NetperfTargetAssignment{
					PolicyId:         "pol-preempt",
					ProfileId:        "prof-preempt",
					ResponderAgentId: "agent-hub-01",
					TargetAddress:    host,
					TargetPort:       port,
					Protocol:         tc.proto,
					Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
					BandwidthBps:     4_000_000,
					DurationSec:      10,
					Parallel:         1,
					IntervalSeconds:  60,
					Permit:           signPermit("permit-sched-real", 10),
				},
			}}
			svc.mu.Unlock()
			svc.wakeScheduler()

			require.Eventually(t, func() bool {
				return resp.SnapshotMetrics().ActiveSessions == 1
			}, 3*time.Second, 10*time.Millisecond)

			// Trigger on-demand netperf.run (1s upload) and assert <1s preemption + zero false rperf.available=0!
			odPermitBytes, err := gproto.Marshal(signPermit("permit-od-real", 5))
			require.NoError(t, err)
			payloadBytes, err := json.Marshal(netperfRunPayload{
				PermitID:         "permit-od-real",
				ResponderAgentID: "agent-hub-01",
				TargetAddress:    host,
				TargetPort:       port,
				Protocol:         tc.protoStr,
				Direction:        "upload",
				BandwidthBps:     4_000_000,
				DurationSec:      1,
				Parallel:         1,
				ExecutionSource:  "on_demand",
				PermitB64:        base64.StdEncoding.EncodeToString(odPermitBytes),
			})
			require.NoError(t, err)

			fakeStream := &fakeControlStreamClient{}
			preemptStart := time.Now()
			var odWG sync.WaitGroup
			odWG.Add(1)
			go func() {
				defer odWG.Done()
				loop.handleNetperfRun(context.Background(), &proto.CommandRequest{
					CommandId:   "cmd-real-preempt",
					CommandType: commandTypeNetperfRun,
					PayloadJson: payloadBytes,
					CreatedAt:   time.Now().Unix(),
					TtlSeconds:  60,
				}, &controlStreamSender{stream: fakeStream})
			}()

			// On-demand session must open within < 1s (proving scheduled download preempted immediately).
			require.Eventually(t, func() bool {
				return resp.SnapshotMetrics().SessionsTotal >= 2
			}, time.Second, 10*time.Millisecond, "scheduled %s test did not preempt within 1s", tc.name)
			preemptDelay := time.Since(preemptStart)
			require.Less(t, preemptDelay, time.Second)

			odWG.Wait()

			var cmdRes *proto.CommandResult
			for _, msg := range fakeStream.sent {
				if r := msg.GetCommandResult(); r != nil {
					cmdRes = r
				}
			}
			require.NotNil(t, cmdRes)
			require.True(t, cmdRes.GetSuccess(), "on-demand failed: %s", cmdRes.GetMessage())

			// Wait for both sessions to close and the preempted scheduler run to defer its target.
			require.Eventually(t, func() bool {
				if resp.SnapshotMetrics().ActiveSessions != 0 {
					return false
				}
				svc.mu.Lock()
				defer svc.mu.Unlock()
				return len(svc.targets) == 1 && svc.targets[0].nextRun.After(time.Now())
			}, 2*time.Second, 15*time.Millisecond)

			// Flush any remaining scheduler samples and verify zero rperf.available=0 batches!
			loop.pushNetperfMetrics()
			batches := spooledMetricBatches(t, sp)
			require.NotEmpty(t, batches)
			for _, batch := range batches {
				for _, m := range batch.GetMetrics() {
					if m.GetName() == "rperf.available" {
						for _, pt := range m.GetPoints() {
							require.InDelta(t, 1.0, pt.GetValue(), 1e-6, "preempted scheduled test must not emit rperf.available=0")
						}
					}
				}
			}
			require.Empty(t, svc.DrainSamples())
		})
	}
}

func TestNetperfResponderStartupRetryAcrossNotModifiedAndScheduler(t *testing.T) {
	t.Parallel()

	newFakeStartResp := func(t *testing.T, failFirst bool) (func(context.Context, netperf.ResponderConfig) (*netperf.Responder, error), *atomic.Int32) {
		t.Helper()
		dir := t.TempDir()
		caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		require.NoError(t, err)
		now := time.Now().UTC()
		caTpl := &x509.Certificate{
			SerialNumber:          big.NewInt(1),
			Subject:               pkix.Name{CommonName: "Synthetic Netperf Retry CA"},
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
		sec := makeNetperfAgentPKI(t, sysmonEdgeAgentID, 10, caCert, caKey, caFile, dir)

		var attempts atomic.Int32
		fn := func(ctx context.Context, cfg netperf.ResponderConfig) (*netperf.Responder, error) {
			n := attempts.Add(1)
			if failFirst && n == 1 {
				return nil, errTransientBindFailure
			}
			cfg.ListenAddress = netperfTestLoopback
			cfg.ListenPort = 0
			cfg.AllowEphemeralPort = true
			cfg.Security = sec
			r, err := netperf.NewResponder(cfg)
			if err != nil {
				return nil, err
			}
			if err := r.Start(ctx); err != nil {
				return nil, err
			}
			return r, nil
		}
		return fn, &attempts
	}

	t.Run("not_modified_poll_retries_failed_responder", func(t *testing.T) {
		t.Parallel()

		sp := openTestEdgeSpool(t)
		loop, _ := sysmonEdgeLoop(t, sp)
		svc := loop.ensureNetperfService()
		t.Cleanup(func() { _ = svc.Stop(context.Background()) })

		startFn, attempts := newFakeStartResp(t, true)
		svc.startRespFn = startFn

		// Initial v1 fails transiently -> responder remains nil, config still commits.
		require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
			ConfigVersion: "v1",
			NetperfConfig: &netperfpb.NetperfConfig{
				Responder: &netperfpb.NetperfResponderConfig{
					Enabled:    true,
					ListenPort: 5199,
				},
			},
		}, "control_stream", loop.nextConfigSequence()))
		require.Equal(t, int32(1), attempts.Load())
		require.Nil(t, svc.responder)

		// Subsequent NotModified poll retries startup and succeeds!
		require.True(t, loop.applyConfigResponseWithSequence(context.Background(), &proto.AgentConfigResponse{
			ConfigVersion: "v1",
			NotModified:   true,
		}, "poll", loop.nextConfigSequence()))
		require.Equal(t, int32(2), attempts.Load())
		require.NotNil(t, svc.responder)
	})

	t.Run("scheduler_autonomously_retries_with_zero_targets", func(t *testing.T) {
		t.Parallel()

		sp := openTestEdgeSpool(t)
		loop, _ := sysmonEdgeLoop(t, sp)
		svc := loop.ensureNetperfService()
		svc.respRetryDelay = 25 * time.Millisecond

		startFn, attempts := newFakeStartResp(t, true)
		svc.startRespFn = startFn

		require.NoError(t, svc.Start(context.Background()))
		t.Cleanup(func() { _ = svc.Stop(context.Background()) })

		svc.ApplyConfig(context.Background(), &netperfpb.NetperfConfig{
			Responder: &netperfpb.NetperfResponderConfig{
				Enabled:    true,
				ListenPort: 5199,
			},
		})
		require.Eventually(t, func() bool {
			svc.mu.Lock()
			defer svc.mu.Unlock()
			return svc.responder != nil && attempts.Load() >= 2
		}, 2*time.Second, 15*time.Millisecond)
	})
}

func TestControlStreamNetperfRunRespectsHigherTTLCeilingAndPermitIDFallback(t *testing.T) {
	t.Parallel()

	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentMetricsGrant(t)}, time.Now())

	svc := loop.ensureNetperfService()
	var observedRemaining time.Duration
	svc.runSenderFn = func(ctx context.Context, req netperf.TestRequest) (*netperf.TestResult, error) {
		deadline, ok := ctx.Deadline()
		require.True(t, ok)
		observedRemaining = time.Until(deadline)
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
				BytesReceived:   100_000,
				BitsPerSecond:   800_000,
			},
		}, nil
	}

	permit := &netperfpb.NetperfPermitV1{
		PermitVersion:    1,
		PermitId:         "permit-fallback-1",
		PartitionId:      defaultPartition,
		SenderAgentId:    sysmonEdgeAgentID,
		ResponderAgentId: "agent-hub-01",
		PolicyId:         "on_demand:cmd-ttl",
	}
	permitBytes, err := gproto.Marshal(permit)
	require.NoError(t, err)

	// Omit permit_id from JSON payload to exercise permit.GetPermitId() fallback.
	payloadBytes, err := json.Marshal(netperfRunPayload{
		ResponderAgentID: "agent-hub-01",
		TargetAddress:    "192.0.2.10",
		TargetPort:       5199,
		Protocol:         "tcp",
		Direction:        "bidirectional",
		BandwidthBps:     10_000_000,
		DurationSec:      30,
		OmitSec:          5,
		Parallel:         1,
		ExecutionSource:  "on_demand",
		PermitB64:        base64.StdEncoding.EncodeToString(permitBytes),
	})
	require.NoError(t, err)

	fakeStream := &fakeControlStreamClient{}
	loop.handleNetperfRun(context.Background(), &proto.CommandRequest{
		CommandId:   "cmd-ttl",
		CommandType: commandTypeNetperfRun,
		PayloadJson: payloadBytes,
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  120,
	}, &controlStreamSender{stream: fakeStream})

	require.Greater(t, observedRemaining, 80*time.Second, "120s TTL must not be clamped to 75s")

	var cmdRes *proto.CommandResult
	for _, msg := range fakeStream.sent {
		if r := msg.GetCommandResult(); r != nil {
			cmdRes = r
		}
	}
	require.NotNil(t, cmdRes)
	require.True(t, cmdRes.GetSuccess())

	var summary map[string]any
	require.NoError(t, json.Unmarshal(cmdRes.GetPayloadJson(), &summary))
	require.Equal(t, "permit-fallback-1", summary["permit_id"])
}
