/*
 * Copyright 2025 Carver Automation Corporation.
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
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

type syntheticRenewalGatewayServer struct {
	proto.UnimplementedAgentGatewayServiceServer
	mu                 sync.Mutex
	caCert             *x509.Certificate
	caKey              *ecdsa.PrivateKey
	caPEM              []byte
	nowFunc            func() time.Time
	nextSerial         int64
	revokedSerials     map[int64]string
	pendingPredecessor map[int64]int64 // successorSerial -> predecessorSerial
	lastHelloSerial    int64
	lastPushSerial     int64
	renewCalls         int
}

func newSyntheticRenewalGatewayServer(caCert *x509.Certificate, caKey *ecdsa.PrivateKey, caPEM []byte) *syntheticRenewalGatewayServer {
	return &syntheticRenewalGatewayServer{
		caCert:             caCert,
		caKey:              caKey,
		caPEM:              caPEM,
		nowFunc:            time.Now,
		nextSerial:         5000,
		revokedSerials:     make(map[int64]string),
		pendingPredecessor: make(map[int64]int64),
	}
}

func (s *syntheticRenewalGatewayServer) peerLeaf(ctx context.Context) (*x509.Certificate, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.AuthInfo == nil {
		return nil, status.Error(codes.Unauthenticated, "missing peer auth info")
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.PeerCertificates) == 0 {
		return nil, status.Error(codes.Unauthenticated, "missing client certificate")
	}
	return tlsInfo.State.PeerCertificates[0], nil
}

func (s *syntheticRenewalGatewayServer) RenewCertificate(ctx context.Context, req *proto.CertificateRenewalRequest) (*proto.CertificateRenewalResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.renewCalls++

	peerCert, err := s.peerLeaf(ctx)
	if err != nil {
		return nil, err
	}

	now := s.nowFunc()
	if now.Before(peerCert.NotBefore) {
		return nil, status.Error(codes.PermissionDenied, "certificate_not_yet_valid")
	}
	if !now.Before(peerCert.NotAfter) {
		return nil, status.Error(codes.PermissionDenied, "certificate_expired")
	}
	if _, revoked := s.revokedSerials[peerCert.SerialNumber.Int64()]; revoked {
		return nil, status.Error(codes.PermissionDenied, "certificate_revoked")
	}

	csr, err := x509.ParseCertificateRequest(req.GetCsrDer())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid_csr")
	}
	if err := csr.CheckSignature(); err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid_csr_signature")
	}

	expectedCN := peerCert.Subject.CommonName
	if csr.Subject.CommonName != "" && csr.Subject.CommonName != expectedCN {
		return nil, status.Error(codes.PermissionDenied, "csr_identity_mismatch")
	}
	for _, dns := range csr.DNSNames {
		if dns != expectedCN {
			return nil, status.Error(codes.PermissionDenied, "csr_identity_mismatch")
		}
	}
	if len(peerCert.URIs) > 0 {
		expectedURI := peerCert.URIs[0].String()
		for _, u := range csr.URIs {
			if u.String() != expectedURI {
				return nil, status.Error(codes.PermissionDenied, "csr_identity_mismatch")
			}
		}
	}

	s.nextSerial++
	newSerial := s.nextSerial
	notBefore := now.Add(-time.Minute).UTC().Truncate(time.Second)
	notAfter := now.Add(90 * 24 * time.Hour).UTC().Truncate(time.Second)

	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(newSerial),
		Subject:      pkix.Name{CommonName: expectedCN},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{expectedCN},
		URIs:         peerCert.URIs,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, tpl, s.caCert, csr.PublicKey, s.caKey)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to sign renewed certificate")
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	fp := sha256.Sum256(certDER)

	// Mark predecessor as pending retirement until successor completes Hello.
	s.pendingPredecessor[newSerial] = peerCert.SerialNumber.Int64()

	return &proto.CertificateRenewalResponse{
		CertificatePem:         certPEM,
		CaChainPem:             s.caPEM,
		SerialNumber:           hex.EncodeToString(big.NewInt(newSerial).Bytes()),
		CertificateFingerprint: hex.EncodeToString(fp[:]),
		NotBeforeUnix:          notBefore.Unix(),
		NotAfterUnix:           notAfter.Unix(),
	}, nil
}

func (s *syntheticRenewalGatewayServer) Hello(ctx context.Context, req *proto.AgentHelloRequest) (*proto.AgentHelloResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	peerCert, err := s.peerLeaf(ctx)
	if err != nil {
		return nil, err
	}
	serial := peerCert.SerialNumber.Int64()
	if _, revoked := s.revokedSerials[serial]; revoked {
		return nil, status.Error(codes.PermissionDenied, "certificate_revoked")
	}

	s.lastHelloSerial = serial
	if predSerial, ok := s.pendingPredecessor[serial]; ok {
		s.revokedSerials[predSerial] = "superseded_by_renewal"
		delete(s.pendingPredecessor, serial)
	}

	return &proto.AgentHelloResponse{
		Accepted:             true,
		AgentId:              req.GetAgentId(),
		GatewayId:            "gw-synth-1",
		HeartbeatIntervalSec: 30,
	}, nil
}

func (s *syntheticRenewalGatewayServer) PushStatus(ctx context.Context, _ *proto.GatewayStatusRequest) (*proto.GatewayStatusResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	peerCert, err := s.peerLeaf(ctx)
	if err != nil {
		return nil, err
	}
	s.lastPushSerial = peerCert.SerialNumber.Int64()
	return &proto.GatewayStatusResponse{Received: true}, nil
}

type renewalTestHarness struct {
	certDir   string
	caCert    *x509.Certificate
	caKey     *ecdsa.PrivateKey
	caPEM     []byte
	gwServer  *syntheticRenewalGatewayServer
	grpcSrv   *grpc.Server
	gwClient  *agentgateway.GatewayClient
	initialSN int64
}

func setupRenewalTestHarness(t *testing.T, notBefore, notAfter time.Time) *renewalTestHarness {
	t.Helper()

	certDir := t.TempDir()
	now := time.Now().UTC()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	caTpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "ServiceRadar Synthetic Test CA"},
		NotBefore:             now.Add(-365 * 24 * time.Hour),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	require.NoError(t, err)
	caCert, err := x509.ParseCertificate(caDER)
	require.NoError(t, err)
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})

	// Generate server certificate for localhost.
	srvKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	srvTpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "gateway.default.serviceradar"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost", "gateway.default.serviceradar"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	srvDER, err := x509.CreateCertificate(rand.Reader, srvTpl, caCert, &srvKey.PublicKey, caKey)
	require.NoError(t, err)
	srvPKCS8, err := x509.MarshalPKCS8PrivateKey(srvKey)
	require.NoError(t, err)
	srvCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srvDER})
	srvKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: srvPKCS8})
	srvTLSCert, err := tls.X509KeyPair(srvCertPEM, srvKeyPEM)
	require.NoError(t, err)

	// Generate initial agent client certificate.
	initialSN := int64(1001)
	agentCertPEM, agentKeyPEM := issueSyntheticAgentCert(t, caCert, caKey, initialSN, "agent-synth-1", "default", notBefore, notAfter)

	require.NoError(t, os.WriteFile(filepath.Join(certDir, "root.pem"), caPEM, 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(certDir, "component.pem"), agentCertPEM, 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(certDir, "component-key.pem"), agentKeyPEM, 0o600))

	caPool := x509.NewCertPool()
	require.True(t, caPool.AppendCertsFromPEM(caPEM))

	srvTLSConfig := &tls.Config{
		Certificates: []tls.Certificate{srvTLSCert},
		ClientCAs:    caPool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)

	gwServer := newSyntheticRenewalGatewayServer(caCert, caKey, caPEM)
	grpcSrv := grpc.NewServer(grpc.Creds(credentials.NewTLS(srvTLSConfig)))
	proto.RegisterAgentGatewayServiceServer(grpcSrv, gwServer)

	go func() {
		_ = grpcSrv.Serve(lis)
	}()
	t.Cleanup(func() {
		grpcSrv.Stop()
	})

	secCfg := &models.SecurityConfig{
		Mode:       srgrpc.SecurityModeMTLS,
		Role:       models.RoleAgent,
		CertDir:    certDir,
		ServerName: "gateway.default.serviceradar",
		TLS: models.TLSConfig{
			CertFile: "component.pem",
			KeyFile:  "component-key.pem",
			CAFile:   "root.pem",
		},
	}

	gwClient := agentgateway.NewGatewayClient(lis.Addr().String(), secCfg, logger.NewTestLogger())
	t.Cleanup(func() {
		_ = gwClient.Disconnect()
	})

	return &renewalTestHarness{
		certDir:   certDir,
		caCert:    caCert,
		caKey:     caKey,
		caPEM:     caPEM,
		gwServer:  gwServer,
		grpcSrv:   grpcSrv,
		gwClient:  gwClient,
		initialSN: initialSN,
	}
}

func issueSyntheticAgentCert(t *testing.T, caCert *x509.Certificate, caKey *ecdsa.PrivateKey, serial int64, componentID, partitionID string, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	cn := componentID + "." + partitionID + ".serviceradar"
	spiffeURI, err := url.Parse("spiffe://serviceradar.local/agent/" + partitionID + "/" + componentID)
	require.NoError(t, err)

	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{cn},
		URIs:         []*url.URL{spiffeURI},
	}

	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &key.PublicKey, caKey)
	require.NoError(t, err)
	pkcs8, err := x509.MarshalPKCS8PrivateKey(key)
	require.NoError(t, err)

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8})
	return certPEM, keyPEM
}

// Evidence 1: An agent with a near-expiry test cert renews through the gateway, hot-reloads MTLSProvider,
// reconnects with Hello presenting the successor cert, retires the predecessor, and keeps its connection.
func TestCertRenewalNearExpiryRenewsHotReloadsAndKeepsConnection(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	now := time.Now().UTC()
	// 90-day certificate with 70 days elapsed (> 2/3 of lifetime).
	notBefore := now.Add(-70 * 24 * time.Hour)
	notAfter := now.Add(20 * 24 * time.Hour)

	h := setupRenewalTestHarness(t, notBefore, notAfter)
	require.NoError(t, h.gwClient.Connect(ctx))

	mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
	mgr.jitterFunc = func(time.Duration) time.Duration { return 0 }
	mgr.helloBuilder = func() *proto.AgentHelloRequest {
		return &proto.AgentHelloRequest{AgentId: "agent-synth-1"}
	}

	delay, leaf, err := mgr.NextRenewalDelay()
	require.NoError(t, err)
	require.NotNil(t, leaf)
	assert.Equal(t, time.Duration(0), delay)
	assert.Equal(t, h.initialSN, leaf.SerialNumber.Int64())

	require.NoError(t, mgr.RenewOnce(ctx))

	// Provider was hot-reloaded in-memory with the new leaf certificate.
	newLeaf := h.gwClient.MTLSProvider().ClientLeaf()
	require.NotNil(t, newLeaf)
	assert.Equal(t, int64(5001), newLeaf.SerialNumber.Int64())

	// Successor Hello retired the predecessor certificate on the gateway.
	h.gwServer.mu.Lock()
	assert.Equal(t, int64(5001), h.gwServer.lastHelloSerial)
	assert.Equal(t, "superseded_by_renewal", h.gwServer.revokedSerials[h.initialSN])
	h.gwServer.mu.Unlock()

	// Subsequent RPCs over the reconnected gateway client use the renewed certificate.
	_, err = h.gwClient.PushStatus(ctx, &proto.GatewayStatusRequest{AgentId: "agent-synth-1"})
	require.NoError(t, err)

	h.gwServer.mu.Lock()
	assert.Equal(t, int64(5001), h.gwServer.lastPushSerial)
	h.gwServer.mu.Unlock()
}

// Evidence 2: A forged CSR (wrong key signature or a different identity in CN/SAN) is rejected.
func TestCertRenewalRejectsForgedCSR(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	now := time.Now().UTC()
	h := setupRenewalTestHarness(t, now.Add(-70*24*time.Hour), now.Add(20*24*time.Hour))
	require.NoError(t, h.gwClient.Connect(ctx))

	t.Run("mismatched identity in CSR CN is rejected with PERMISSION_DENIED", func(t *testing.T) {
		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		mgr.csrBuilderFunc = func(_ *x509.Certificate, signer crypto.Signer) ([]byte, error) {
			return x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
				Subject:  pkix.Name{CommonName: "agent-impostor.default.serviceradar"},
				DNSNames: []string{"agent-impostor.default.serviceradar"},
			}, signer)
		}

		err := mgr.RenewOnce(ctx)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "csr_identity_mismatch")
		assert.Equal(t, h.initialSN, h.gwClient.MTLSProvider().ClientLeaf().SerialNumber.Int64())
	})

	t.Run("tampered CSR signature is rejected with INVALID_ARGUMENT", func(t *testing.T) {
		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		mgr.csrBuilderFunc = func(leaf *x509.Certificate, signer crypto.Signer) ([]byte, error) {
			csrDER, err := buildRenewalCSRFromLeaf(leaf, signer)
			if err != nil {
				return nil, err
			}
			csrDER[len(csrDER)-1] ^= 0xFF
			return csrDER, nil
		}

		err := mgr.RenewOnce(ctx)
		require.Error(t, err)
		assert.Contains(t, err.Error(), "invalid_csr_signature")
		assert.Equal(t, h.initialSN, h.gwClient.MTLSProvider().ClientLeaf().SerialNumber.Int64())
	})
}

// Evidence 3: A crash mid-write leaves the old cert usable (before bundle commit) or self-heals
// from component-bundle.pem on startup (after bundle commit), and survives repeated startup crashes.
func TestCertRenewalCrashMidWriteAndStartupSelfHeal(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	now := time.Now().UTC()
	h := setupRenewalTestHarness(t, now.Add(-70*24*time.Hour), now.Add(20*24*time.Hour))
	require.NoError(t, h.gwClient.Connect(ctx))

	t.Run("crash before component-bundle.pem rename leaves old cert pair usable", func(t *testing.T) {
		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		mgr.writeHooks = CertRenewalWriteHooks{
			BeforeBundleRename: func(_ string) error {
				return errors.New("simulated crash before bundle rename")
			},
		}

		err := mgr.RenewOnce(ctx)
		require.ErrorContains(t, err, "simulated crash before bundle rename")

		// Old certificate and key on disk are untouched and loadable.
		provider, err := srgrpc.NewMTLSProvider(&models.SecurityConfig{
			Mode:    srgrpc.SecurityModeMTLS,
			Role:    models.RoleAgent,
			CertDir: h.certDir,
			TLS: models.TLSConfig{
				CertFile: "component.pem",
				KeyFile:  "component-key.pem",
				CAFile:   "root.pem",
			},
		}, logger.NewTestLogger())
		require.NoError(t, err)
		assert.Equal(t, h.initialSN, provider.ClientLeaf().SerialNumber.Int64())
	})

	t.Run("crash after key rename (with mismatched component.pem) self-heals from component-bundle.pem on startup", func(t *testing.T) {
		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		mgr.writeHooks = CertRenewalWriteHooks{
			AfterKeyRename: func(_ string) error {
				return errors.New("simulated crash after key rename before cert rename")
			},
		}

		err := mgr.RenewOnce(ctx)
		require.ErrorContains(t, err, "simulated crash after key rename")

		certPath := filepath.Join(h.certDir, "component.pem")
		keyPath := filepath.Join(h.certDir, "component-key.pem")
		bundlePath := filepath.Join(h.certDir, "component-bundle.pem")

		// Raw LoadX509KeyPair fails because component-key.pem has the new key while component.pem still has the old cert.
		_, rawErr := tls.LoadX509KeyPair(certPath, keyPath)
		require.Error(t, rawErr)

		// Startup NewMTLSProvider self-heals component.pem and component-key.pem from component-bundle.pem.
		secCfg := &models.SecurityConfig{
			Mode:    srgrpc.SecurityModeMTLS,
			Role:    models.RoleAgent,
			CertDir: h.certDir,
			TLS: models.TLSConfig{
				CertFile: "component.pem",
				KeyFile:  "component-key.pem",
				CAFile:   "root.pem",
			},
		}
		provider, err := srgrpc.NewMTLSProvider(secCfg, logger.NewTestLogger())
		require.NoError(t, err)
		require.NotNil(t, provider.ClientLeaf())
		assert.Greater(t, provider.ClientLeaf().SerialNumber.Int64(), h.initialSN)

		// component-bundle.pem is retained so a second crash during repair self-heals again.
		_, statErr := os.Stat(bundlePath)
		require.NoError(t, statErr)
	})
}

// Evidence 4: An expired cert is refused renewal (both pre-attempt on the agent and PERMISSION_DENIED on the gateway).
func TestCertRenewalRefusesExpiredCertificate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	now := time.Now().UTC()
	h := setupRenewalTestHarness(t, now.Add(-90*24*time.Hour), now.Add(10*time.Minute))
	require.NoError(t, h.gwClient.Connect(ctx))

	t.Run("server rejects RenewCertificate when peer certificate has expired", func(t *testing.T) {
		h.gwServer.mu.Lock()
		h.gwServer.nowFunc = func() time.Time { return now.Add(1 * time.Hour) }
		h.gwServer.mu.Unlock()

		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		err := mgr.RenewOnce(ctx)
		require.ErrorIs(t, err, srgrpc.ErrClientCertificateExpired)
		assert.Contains(t, err.Error(), "local mTLS client certificate expired")
		assert.Contains(t, err.Error(), "re-enroll required")
	})

	t.Run("agent refuses renewal before dialing when local certificate is expired", func(t *testing.T) {
		h.gwClient.MTLSProvider().SetNowFunc(func() time.Time { return now.Add(2 * time.Hour) })
		h.gwServer.mu.Lock()
		callsBefore := h.gwServer.renewCalls
		h.gwServer.mu.Unlock()

		mgr := NewCertRenewalManager(h.gwClient, logger.NewTestLogger())
		mgr.nowFunc = func() time.Time { return now.Add(2 * time.Hour) }

		err := mgr.RenewOnce(ctx)
		require.ErrorIs(t, err, srgrpc.ErrClientCertificateExpired)
		assert.Contains(t, err.Error(), "local mTLS client certificate expired")
		assert.Contains(t, err.Error(), "re-enroll required")

		h.gwServer.mu.Lock()
		assert.Equal(t, callsBefore, h.gwServer.renewCalls)
		h.gwServer.mu.Unlock()
	})
}
