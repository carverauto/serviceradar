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
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

type testPKI struct {
	caCert *x509.Certificate
	caKey  *ecdsa.PrivateKey
	caFile string
	dir    string
}

func newTestPKI(t *testing.T) *testPKI {
	t.Helper()
	dir := t.TempDir()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	now := time.Now().UTC()
	caTpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "ServiceRadar Synthetic Netperf CA"},
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

	return &testPKI{caCert: caCert, caKey: caKey, caFile: caFile, dir: dir}
}

func (p *testPKI) agentSecurity(t *testing.T, agentID string, serial int64) *models.SecurityConfig {
	t.Helper()
	const partitionID = "default"
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	dns := agentID + "." + partitionID + ".serviceradar"
	spiffe, err := url.Parse("spiffe://serviceradar.local/agent/" + partitionID + "/" + agentID)
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
	der, err := x509.CreateCertificate(rand.Reader, tpl, p.caCert, &leafKey.PublicKey, p.caKey)
	require.NoError(t, err)
	pkcs8, err := x509.MarshalPKCS8PrivateKey(leafKey)
	require.NoError(t, err)

	certPath := filepath.Join(p.dir, agentID+"-"+strconv.FormatInt(serial, 10)+".pem")
	keyPath := filepath.Join(p.dir, agentID+"-"+strconv.FormatInt(serial, 10)+"-key.pem")
	require.NoError(t, os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644))
	require.NoError(t, os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8}), 0o600))

	return &models.SecurityConfig{
		Mode: models.SecurityModeMTLS,
		// Intentionally omit Role to verify host_trust_linux.go normalization!
		ServerName: "serviceradar-agent-gateway.ignored.invalid",
		TLS: models.TLSConfig{
			CertFile: certPath,
			KeyFile:  keyPath,
			CAFile:   p.caFile,
		},
	}
}

func testHostPort(t *testing.T, addr string) (string, uint32) {
	t.Helper()
	host, portStr, err := net.SplitHostPort(addr)
	require.NoError(t, err)
	port, err := strconv.ParseUint(portStr, 10, 32)
	require.NoError(t, err)
	return host, uint32(port)
}

func TestResponderAdmissionControlEpochUpdateAndReaper(t *testing.T) {
	t.Parallel()

	pki := newTestPKI(t)
	hubSec := pki.agentSecurity(t, "agent-hub-01", 10)
	spokeSec := pki.agentSecurity(t, "agent-spoke-01", 11)

	seed := bytes.Repeat([]byte{0x55}, ed25519.SeedSize)
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
		MaxConcurrentSessions: 1,
		MaxTotalBandwidthBps:  10_000_000,
		MinAuthorityEpoch:     2,
		Security:              hubSec,
		KeyResolver:           resolver,
		Logger:                logger.NewTestLogger(),
	})
	require.NoError(t, err)
	require.NoError(t, resp.Start(context.Background()))
	t.Cleanup(func() { _ = resp.Close() })

	creds, owned, err := buildClientTransportCredentials(spokeSec, nil, nil, "agent-hub-01", "default", logger.NewTestLogger())
	require.NoError(t, err)
	t.Cleanup(func() {
		if owned != nil {
			_ = owned.Close()
		}
	})

	conn, err := grpc.NewClient(resp.ListenAddr(), grpc.WithTransportCredentials(creds))
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })

	client := netperfpb.NewNetworkPerfPeerServiceClient(conn)
	now := time.Now()

	makePermit := func(epoch uint64, maxBw uint64) *netperfpb.NetperfPermitV1 {
		return signTestPermit(t, priv, &netperfpb.NetperfPermitV1{
			PermitVersion:    1,
			PermitId:         "permit-adm-" + strconv.FormatUint(epoch, 10),
			PartitionId:      "default",
			SenderAgentId:    "agent-spoke-01",
			ResponderAgentId: "agent-hub-01",
			PolicyId:         "policy-adm",
			MaxBandwidthBps:  maxBw,
			MaxDurationSec:   5,
			MaxParallel:      2,
			AllowedProtocols: []netperfpb.NetperfProtocol{
				netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
				netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
			},
			AllowedDirections: []netperfpb.NetperfDirection{
				netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
			},
			IssuedAtUnix:   now.Unix() - 60,
			ExpiresAtUnix:  now.Unix() + 600,
			AuthorityEpoch: epoch,
			IssuerId:       "serviceradar-core",
			IssuerKeyId:    keyID,
			Algorithm:      "ed25519",
		})
	}

	// Open session #1 -> accepted
	open1, err := client.OpenSession(context.Background(), &netperfpb.OpenSessionRequest{
		Permit:       makePermit(2, 10_000_000),
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: 5_000_000,
		DurationSec:  1,
		OmitSec:      0,
		Parallel:     1,
		PacketLength: 1200,
	})
	require.NoError(t, err)
	require.True(t, open1.GetAccepted())
	require.Len(t, open1.GetSessionId(), UDPSessionSize)
	require.Len(t, open1.GetUdpSessionKey(), UDPKeySize)
	require.Equal(t, uint64(1), resp.SnapshotMetrics().ActiveSessions)

	// Session #2 exceeds MaxConcurrentSessions=1 -> ResourceExhausted + RetryInfo
	_, err = client.OpenSession(context.Background(), &netperfpb.OpenSessionRequest{
		Permit:       makePermit(2, 10_000_000),
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: 1_000_000,
		DurationSec:  1,
		OmitSec:      0,
		Parallel:     1,
	})
	require.Error(t, err)
	st, ok := status.FromError(err)
	require.True(t, ok)
	require.Equal(t, codes.ResourceExhausted, st.Code())
	var gotRetry bool
	for _, detail := range st.Details() {
		if ri, ok := detail.(*errdetails.RetryInfo); ok {
			gotRetry = true
			ms := ri.GetRetryDelay().AsDuration().Milliseconds()
			require.GreaterOrEqual(t, ms, int64(MinRetryAfterMs))
			require.LessOrEqual(t, ms, int64(MaxRetryAfterMs))
		}
	}
	require.True(t, gotRetry)
	require.Equal(t, uint64(1), resp.SnapshotMetrics().BusyRejectionsTotal)

	// Unauthenticated / invalid UDP packets produce 0 reply bytes (no amplification).
	udpConn, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: int(resp.UDPPort())})
	require.NoError(t, err)
	t.Cleanup(func() { _ = udpConn.Close() })
	_, err = udpConn.Write([]byte("arbitrary-unauthenticated-probe-payload-bytes-0123456789abcdef"))
	require.NoError(t, err)
	badMACPkt := make([]byte, DefaultPacketLength)
	var sid [UDPSessionSize]byte
	copy(sid[:], open1.GetSessionId())
	require.NoError(t, EncodeUDPDatagram(badMACPkt, bytes.Repeat([]byte{0x99}, UDPKeySize), UDPFlagData, sid, 1, uint64(now.UnixNano())))
	_, err = udpConn.Write(badMACPkt)
	require.NoError(t, err)
	_ = udpConn.SetReadDeadline(time.Now().Add(80 * time.Millisecond))
	replyBuf := make([]byte, 256)
	_, err = udpConn.Read(replyBuf)
	require.Error(t, err, "responder must drop invalid UDP packets silently with zero reply bytes")

	// Close session #1 releases slot
	_, err = client.CloseSession(context.Background(), &netperfpb.CloseSessionRequest{SessionId: open1.GetSessionId()})
	require.NoError(t, err)
	require.Equal(t, uint64(0), resp.SnapshotMetrics().ActiveSessions)

	// Bump min_authority_epoch dynamically -> epoch 2 permit is now fenced!
	resp.UpdateConfig(2, 10_000_000, 3)
	_, err = client.OpenSession(context.Background(), &netperfpb.OpenSessionRequest{
		Permit:       makePermit(2, 5_000_000),
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: 5_000_000,
		DurationSec:  1,
		Parallel:     1,
	})
	require.Error(t, err)
	require.Equal(t, codes.PermissionDenied, status.Code(err))

	// Epoch 3 permit succeeds and bandwidth admission is checked (2*6M > 10M fails!)
	open3, err := client.OpenSession(context.Background(), &netperfpb.OpenSessionRequest{
		Permit:       makePermit(3, 10_000_000),
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: 6_000_000,
		DurationSec:  1,
		Parallel:     1,
	})
	require.NoError(t, err)
	require.True(t, open3.GetAccepted())

	_, err = client.OpenSession(context.Background(), &netperfpb.OpenSessionRequest{
		Permit:       makePermit(3, 10_000_000),
		Protocol:     netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP,
		Direction:    netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD,
		BandwidthBps: 5_000_000,
		DurationSec:  1,
		Parallel:     1,
	})
	require.Equal(t, codes.ResourceExhausted, status.Code(err))

	_, err = client.CloseSession(context.Background(), &netperfpb.CloseSessionRequest{SessionId: open3.GetSessionId()})
	require.NoError(t, err)

	// Unauthenticated plaintext TCP client fails TLS handshake.
	plainConn, err := grpc.NewClient(resp.ListenAddr(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	require.NoError(t, err)
	t.Cleanup(func() { _ = plainConn.Close() })
	plainClient := netperfpb.NewNetworkPerfPeerServiceClient(plainConn)
	ctxShort, cancelShort := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancelShort()
	_, err = plainClient.OpenSession(ctxShort, &netperfpb.OpenSessionRequest{})
	require.Error(t, err)
}
