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

package netperf

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/durationpb"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

func setupLoopbackPair(t *testing.T, maxSessions uint32) (*Responder, *Sender, ed25519.PrivateKey, []byte) {
	t.Helper()

	pki := newTestPKI(t)
	hubSec := pki.agentSecurity(t, "agent-hub-01", 100)
	spokeSec := pki.agentSecurity(t, "agent-spoke-01", 101)

	seed := bytes.Repeat([]byte{0x77}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	keyID := []byte("0123456789abcdef")

	snap := makeTestTrustSnapshot(t, "agent-hub-01", []byte("serviceradar-core"), keyID, pub, "valid", []string{"production"})
	resolver := TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return snap }}

	resp, err := NewResponder(ResponderConfig{
		AgentID:               "agent-hub-01",
		PartitionID:           "default",
		ListenAddress:         "127.0.0.1",
		AllowEphemeralPort:    true,
		UDPEnabled:            true,
		MaxConcurrentSessions: maxSessions,
		MaxTotalBandwidthBps:  1_000_000_000,
		MinAuthorityEpoch:     1,
		Security:              hubSec,
		KeyResolver:           resolver,
		Logger:                logger.NewTestLogger(),
	})
	require.NoError(t, err)
	require.NoError(t, resp.Start(context.Background()))
	t.Cleanup(func() { _ = resp.Close() })

	sender, err := NewSender(SenderConfig{
		AgentID:     "agent-spoke-01",
		PartitionID: "default",
		Security:    spokeSec,
		Logger:      logger.NewTestLogger(),
	})
	require.NoError(t, err)

	return resp, sender, priv, keyID
}

func makeLoopbackPermit(t *testing.T, priv ed25519.PrivateKey, keyID []byte) *netperfpb.NetperfPermitV1 {
	t.Helper()
	now := time.Now()
	return signTestPermit(t, priv, &netperfpb.NetperfPermitV1{
		PermitVersion:    1,
		PermitId:         "permit-loopback-1",
		PartitionId:      "default",
		SenderAgentId:    "agent-spoke-01",
		ResponderAgentId: "agent-hub-01",
		PolicyId:         "policy-loopback-1",
		MaxBandwidthBps:  100_000_000,
		MaxDurationSec:   10,
		MaxParallel:      4,
		AllowedProtocols: []netperfpb.NetperfProtocol{
			netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
			netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
		},
		AllowedDirections: []netperfpb.NetperfDirection{
			netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL,
		},
		IssuedAtUnix:   now.Unix() - 60,
		ExpiresAtUnix:  now.Unix() + 600,
		AuthorityEpoch: 1,
		IssuerId:       "serviceradar-core",
		IssuerKeyId:    keyID,
		Algorithm:      "ed25519",
	})
}

func TestSenderAndResponderTCPModes(t *testing.T) {
	t.Parallel()

	resp, sender, priv, keyID := setupLoopbackPair(t, 4)
	host, port := testHostPort(t, resp.ListenAddr())
	permit := makeLoopbackPermit(t, priv, keyID)

	for _, tc := range []struct {
		name     string
		dir      netperfpb.NetperfDirection
		parallel uint32
	}{
		{"tcp_upload_p2", netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD, 2},
		{"tcp_download_p2", netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD, 2},
		{"tcp_bidirectional_p1", netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, err := sender.RunTest(context.Background(), TestRequest{
				TargetAddress:    host,
				TargetPort:       port,
				ResponderAgentID: "agent-hub-01",
				ResponderLabel:   "hub-01",
				PolicyID:         "policy-loopback-1",
				ProfileID:        "profile-1",
				Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
				Direction:        tc.dir,
				BandwidthBps:     10_000_000,
				DurationSec:      1,
				OmitSec:          0,
				Parallel:         tc.parallel,
				ExecutionSource:  netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_SCHEDULED_POLICY,
				Permit:           permit,
			})
			require.NoError(t, err)
			require.True(t, res.Available)
			require.Greater(t, res.Primary.BitsPerSecond, 0.0)

			switch tc.dir {
			case netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD:
				require.NotNil(t, res.Upload)
				require.Positive(t, res.Upload.BytesReceived)
			case netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD:
				require.NotNil(t, res.Download)
				require.Positive(t, res.Download.BytesReceived)
			case netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL:
				require.NotNil(t, res.Upload)
				require.NotNil(t, res.Download)
				require.Positive(t, res.Upload.BytesReceived)
				require.Positive(t, res.Download.BytesReceived)
			case netperfpb.NetperfDirection_NETPERF_DIRECTION_UNSPECIFIED:
				t.Fatalf("unexpected unspecified direction")
			}
		})
	}

	snap := resp.SnapshotMetrics()
	require.Equal(t, uint64(0), snap.ActiveSessions)
	require.Equal(t, uint64(3), snap.SessionsTotal)
	require.Positive(t, snap.BytesTotal)
}

func TestSenderAndResponderUDPModesAndOmitWindow(t *testing.T) {
	t.Parallel()

	resp, sender, priv, keyID := setupLoopbackPair(t, 4)
	host, port := testHostPort(t, resp.ListenAddr())
	permit := makeLoopbackPermit(t, priv, keyID)

	for _, tc := range []struct {
		name        string
		dir         netperfpb.NetperfDirection
		durationSec uint32
		omitSec     uint32
	}{
		{"udp_upload_with_omit", netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD, 2, 1},
		{"udp_download", netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD, 1, 0},
		{"udp_bidirectional", netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL, 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res, err := sender.RunTest(context.Background(), TestRequest{
				TargetAddress:    host,
				TargetPort:       port,
				ResponderAgentID: "agent-hub-01",
				ResponderLabel:   "hub-01",
				PolicyID:         "policy-loopback-1",
				ProfileID:        "profile-udp",
				Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
				Direction:        tc.dir,
				BandwidthBps:     2_000_000,
				DurationSec:      tc.durationSec,
				OmitSec:          tc.omitSec,
				Parallel:         1,
				PacketLength:     1200,
				ExecutionSource:  netperfpb.NetperfExecutionSource_NETPERF_EXECUTION_SOURCE_ON_DEMAND,
				Permit:           permit,
			})
			require.NoError(t, err)
			require.True(t, res.Available)
			require.Positive(t, res.Primary.PacketsReceived)
			require.Positive(t, res.Primary.BytesReceived)
			require.GreaterOrEqual(t, res.Primary.JitterMs, 0.0)
			require.Less(t, res.Primary.LossPercent, 50.0)
		})
	}
}

func TestSenderRejectsMismatchedResponderIdentity(t *testing.T) {
	t.Parallel()

	pki := newTestPKI(t)
	// Responder presents agent-other-hub cert while sender expects agent-hub-01.
	otherSec := pki.agentSecurity(t, "agent-other-hub", 200)
	spokeSec := pki.agentSecurity(t, "agent-spoke-01", 201)

	seed := bytes.Repeat([]byte{0x88}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	keyID := []byte("0123456789abcdef")

	snap := makeTestTrustSnapshot(t, "agent-other-hub", []byte("serviceradar-core"), keyID, pub, "valid", []string{"production"})
	resp, err := NewResponder(ResponderConfig{
		AgentID:            "agent-other-hub",
		PartitionID:        "default",
		ListenAddress:      "127.0.0.1",
		AllowEphemeralPort: true,
		Security:           otherSec,
		KeyResolver:        TrustSnapshotKeyResolver{Snapshot: func() *edgerecord.TrustSnapshot { return snap }},
		Logger:             logger.NewTestLogger(),
	})
	require.NoError(t, err)
	require.NoError(t, resp.Start(context.Background()))
	t.Cleanup(func() { _ = resp.Close() })

	sender, err := NewSender(SenderConfig{
		AgentID:     "agent-spoke-01",
		PartitionID: "default",
		Security:    spokeSec,
		Logger:      logger.NewTestLogger(),
	})
	require.NoError(t, err)

	host, port := testHostPort(t, resp.ListenAddr())
	permit := makeLoopbackPermit(t, priv, keyID)
	res, err := sender.RunTest(context.Background(), TestRequest{
		TargetAddress:    host,
		TargetPort:       port,
		ResponderAgentID: "agent-hub-01",
		PolicyID:         "policy-loopback-1",
		Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps:     1_000_000,
		DurationSec:      1,
		Parallel:         1,
		Permit:           permit,
	})
	require.Error(t, err)
	require.NotNil(t, res)
	require.False(t, res.Available)
	require.False(t, res.BusyExhausted)
}

type busyStubPeerServer struct {
	netperfpb.UnimplementedNetworkPerfPeerServiceServer
	calls atomic.Int32
}

func (b *busyStubPeerServer) OpenSession(_ context.Context, _ *netperfpb.OpenSessionRequest) (*netperfpb.OpenSessionResponse, error) {
	b.calls.Add(1)
	st := status.New(codes.ResourceExhausted, "busy capacity full")
	if det, err := st.WithDetails(&errdetails.RetryInfo{
		RetryDelay: durationpb.New(500 * time.Millisecond),
	}); err == nil {
		st = det
	}
	return &netperfpb.OpenSessionResponse{Accepted: false, RetryAfterMs: 500, RejectReason: "busy"}, st.Err()
}

func TestSenderBusyExhaustedSetsRetryAfterWithoutFalseFailure(t *testing.T) {
	t.Parallel()

	pki := newTestPKI(t)
	hubSec := pki.agentSecurity(t, "agent-hub-01", 300)
	spokeSec := pki.agentSecurity(t, "agent-spoke-01", 301)

	creds, owned, err := buildServerTransportCredentials(hubSec, nil, nil, logger.NewTestLogger())
	require.NoError(t, err)
	t.Cleanup(func() {
		if owned != nil {
			_ = owned.Close()
		}
	})

	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.Creds(creds))
	stub := &busyStubPeerServer{}
	netperfpb.RegisterNetworkPerfPeerServiceServer(srv, stub)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	sender, err := NewSender(SenderConfig{
		AgentID:        "agent-spoke-01",
		PartitionID:    "default",
		Security:       spokeSec,
		MaxBusyRetries: 1,
		Logger:         logger.NewTestLogger(),
		DialContext: func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		},
	})
	require.NoError(t, err)

	seed := bytes.Repeat([]byte{0x99}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	permit := makeLoopbackPermit(t, priv, []byte("0123456789abcdef"))

	res, err := sender.RunTest(context.Background(), TestRequest{
		TargetAddress:    "hub.example.invalid",
		TargetPort:       5199,
		ResponderAgentID: "agent-hub-01",
		PolicyID:         "policy-loopback-1",
		Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps:     1_000_000,
		DurationSec:      1,
		Parallel:         1,
		Permit:           permit,
	})
	require.ErrorIs(t, err, ErrResponderBusy)
	require.NotNil(t, res)
	require.False(t, res.Available)
	require.True(t, res.BusyExhausted)
	require.GreaterOrEqual(t, res.RetryAfterMs, uint32(400))
	require.Equal(t, int32(2), stub.calls.Load())
}

func TestSenderUDPDownloadContextCancelAndResponderClose(t *testing.T) {
	t.Parallel()

	t.Run("ctx_cancel_at_200ms", func(t *testing.T) {
		t.Parallel()

		resp, sender, priv, keyID := setupLoopbackPair(t, 4)
		host, port := testHostPort(t, resp.ListenAddr())
		permit := makeLoopbackPermit(t, priv, keyID)

		ctx, cancel := context.WithCancel(context.Background())
		time.AfterFunc(200*time.Millisecond, cancel)

		start := time.Now()
		res, err := sender.RunTest(ctx, TestRequest{
			TargetAddress:    host,
			TargetPort:       port,
			ResponderAgentID: "agent-hub-01",
			PolicyID:         "policy-loopback-1",
			Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
			Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			BandwidthBps:     2_000_000,
			DurationSec:      5,
			Parallel:         1,
			PacketLength:     1200,
			Permit:           permit,
		})
		elapsed := time.Since(start)

		require.Error(t, err)
		require.True(t, errors.Is(err, context.Canceled) || status.Code(err) == codes.Canceled, "unexpected error: %v", err)
		require.NotNil(t, res)
		require.False(t, res.Available)
		require.Less(t, elapsed, 2*time.Second, "UDP download cancel must unblock promptly")
		require.Eventually(t, func() bool {
			return resp.SnapshotMetrics().ActiveSessions == 0
		}, 2*time.Second, 20*time.Millisecond)
	})

	t.Run("responder_close_mid_stream", func(t *testing.T) {
		t.Parallel()

		resp, sender, priv, keyID := setupLoopbackPair(t, 4)
		host, port := testHostPort(t, resp.ListenAddr())
		permit := makeLoopbackPermit(t, priv, keyID)

		time.AfterFunc(200*time.Millisecond, func() { _ = resp.Close() })

		start := time.Now()
		res, err := sender.RunTest(context.Background(), TestRequest{
			TargetAddress:    host,
			TargetPort:       port,
			ResponderAgentID: "agent-hub-01",
			PolicyID:         "policy-loopback-1",
			Protocol:         netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
			Direction:        netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			BandwidthBps:     2_000_000,
			DurationSec:      5,
			Parallel:         1,
			PacketLength:     1200,
			Permit:           permit,
		})
		elapsed := time.Since(start)

		require.Error(t, err)
		require.NotNil(t, res)
		require.False(t, res.Available)
		require.Less(t, elapsed, 2*time.Second, "UDP download must unblock promptly when responder closes mid-stream")
	})
}

func TestSenderShortContextTimeoutFailsAndNotAvailable(t *testing.T) {
	t.Parallel()

	resp, sender, priv, keyID := setupLoopbackPair(t, 8)
	host, port := testHostPort(t, resp.ListenAddr())
	permit := makeLoopbackPermit(t, priv, keyID)

	for _, tc := range []struct {
		name  string
		proto netperfpb.NetperfProtocol
		dir   netperfpb.NetperfDirection
	}{
		{"tcp_upload", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP, netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD},
		{"tcp_download", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP, netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD},
		{"udp_upload", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP, netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD},
		{"udp_download", netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP, netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer cancel()

			start := time.Now()
			res, err := sender.RunTest(ctx, TestRequest{
				TargetAddress:    host,
				TargetPort:       port,
				ResponderAgentID: "agent-hub-01",
				PolicyID:         "policy-loopback-1",
				Protocol:         tc.proto,
				Direction:        tc.dir,
				BandwidthBps:     4_000_000,
				DurationSec:      5,
				Parallel:         1,
				PacketLength:     1200,
				Permit:           permit,
			})
			elapsed := time.Since(start)

			require.Error(t, err)
			require.NotNil(t, res)
			require.False(t, res.Available, "premature context timeout must never report Available: true")
			require.Less(t, elapsed, 2*time.Second)
		})
	}

	require.Eventually(t, func() bool {
		return resp.SnapshotMetrics().ActiveSessions == 0
	}, 2*time.Second, 20*time.Millisecond)
}

func TestBidirectionalSummaryComputesLossPercent(t *testing.T) {
	t.Parallel()

	combined := combineBidirectionalSummaries(
		&netperfpb.TestSummary{
			DurationSeconds:   1.0,
			DurationNs:        1_000_000_000,
			BytesSent:         120_000,
			BytesReceived:     108_000,
			PacketsSent:       100,
			PacketsReceived:   90,
			PacketsLost:       10,
			OutOfOrderPackets: 1,
			LossPercent:       10.0,
			JitterMs:          1.2,
		},
		&netperfpb.TestSummary{
			DurationSeconds:   1.0,
			DurationNs:        1_000_000_000,
			BytesSent:         120_000,
			BytesReceived:     114_000,
			PacketsSent:       100,
			PacketsReceived:   95,
			PacketsLost:       5,
			OutOfOrderPackets: 2,
			LossPercent:       5.0,
			JitterMs:          2.4,
		},
	)
	require.NotNil(t, combined)
	require.Equal(t, uint64(200), combined.GetPacketsSent())
	require.Equal(t, uint64(15), combined.GetPacketsLost())
	require.InDelta(t, 7.5, combined.GetLossPercent(), 1e-6)
	require.InDelta(t, 2.4, combined.GetJitterMs(), 1e-6)

	res := &TestResult{}
	mergeCloseSessionResult(
		res,
		netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL,
		&PhaseResult{
			Direction:   netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			PacketsSent: 100,
		},
		&PhaseResult{
			Direction:       netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD,
			PacketsReceived: 95,
			BytesReceived:   114_000,
			DurationSeconds: 1.0,
			DurationNs:      1_000_000_000,
		},
		&netperfpb.CloseSessionResponse{
			UploadSummary: &netperfpb.TestSummary{
				DurationSeconds: 1.0,
				DurationNs:      1_000_000_000,
				BytesReceived:   108_000,
				PacketsSent:     100,
				PacketsReceived: 90,
				PacketsLost:     10,
				LossPercent:     10.0,
				JitterMs:        1.2,
			},
			DownloadSummary: &netperfpb.TestSummary{
				DurationSeconds: 1.0,
				DurationNs:      1_000_000_000,
				BytesSent:       120_000,
				PacketsSent:     100,
			},
		},
	)
	require.Equal(t, uint64(200), res.Primary.PacketsSent)
	require.Equal(t, uint64(15), res.Primary.PacketsLost)
	require.InDelta(t, 7.5, res.Primary.LossPercent, 1e-6)
}
