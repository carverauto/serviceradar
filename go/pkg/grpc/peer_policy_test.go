package grpc

import (
	"context"
	"crypto/sha256"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/certpolicy"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/stretchr/testify/require"
	gogrpc "google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

// This exercises both transport owners through established HTTP/2 streams, not
// just the policy predicate or a new handshake. The peers intentionally share
// an issuer and serial, as older enrollment certificates can do.
func TestManagedCertificateRevocationClosesGRPCPeers(t *testing.T) {
	for _, side := range []string{"client", "server"} {
		t.Run(side, func(t *testing.T) {
			ca, key, caPEM := generateTestCAPEM(t)
			now := time.Now()
			aCert, aKey := generateTestLeafPEM(t, ca, key, 7, now.Add(-time.Hour), now.Add(time.Hour))
			bCert, bKey := generateTestLeafPEM(t, ca, key, 7, now.Add(-time.Hour), now.Add(time.Hour))
			cCert, cKey := generateTestLeafPEM(t, ca, key, 8, now.Add(-time.Hour), now.Add(time.Hour))
			fpA, fpB := certificateFingerprint(t, aCert), certificateFingerprint(t, bCert)
			require.NotEqual(t, fpA, fpB)
			policy := certpolicy.New()
			t.Cleanup(policy.Close)
			apply := func(lifetime time.Duration, fingerprints ...string) {
				generated := time.Now()
				require.NoError(t, policy.Apply(certpolicy.Snapshot{Version: 1, GeneratedAt: generated, ValidUntil: generated.Add(lifetime), AllowedFingerprints: fingerprints}))
			}
			apply(20*time.Second, fpA, fpB)
			a := policyTestProvider(t, caPEM, aCert, aKey)
			b := policyTestProvider(t, caPEM, bCert, bKey)
			common := policyTestProvider(t, caPEM, cCert, cKey, WithPeerCertificatePolicy(policy))
			var clientA, clientB healthpb.HealthClient
			if side == "client" {
				clientA = policyHealthClient(t, common, policyHealthServer(t, a))
				clientB = policyHealthClient(t, common, policyHealthServer(t, b))
			} else {
				address := policyHealthServer(t, common)
				clientA = policyHealthClient(t, a, address)
				clientB = policyHealthClient(t, b, address)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			watchA, err := clientA.Watch(ctx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			require.NoError(t, err)
			_, err = watchA.Recv()
			require.NoError(t, err)
			watchB, err := clientB.Watch(ctx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			require.NoError(t, err)
			_, err = watchB.Recv()
			require.NoError(t, err)
			endedA, endedB := make(chan error, 1), make(chan error, 1)
			go func() { _, err := watchA.Recv(); endedA <- err }()
			go func() { _, err := watchB.Recv(); endedB <- err }()

			apply(2*time.Second, fpB)
			requireStreamClosed(t, endedA)
			_, err = clientB.Check(ctx, &healthpb.HealthCheckRequest{})
			require.NoError(t, err, "the same-serial control must remain usable")
			deniedCtx, deniedCancel := context.WithTimeout(ctx, 250*time.Millisecond)
			_, err = clientA.Check(deniedCtx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			deniedCancel()
			require.Error(t, err, "revoked peers must not reconnect")
			requireStreamClosed(t, endedB)
			_, err = clientB.Check(ctx, &healthpb.HealthCheckRequest{})
			require.Error(t, err, "expired policy must close established sessions")

			// A fresh authority snapshot permits surviving clients to reconnect.
			apply(20*time.Second, fpA, fpB)
			_, err = clientA.Check(ctx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			require.NoError(t, err)
			_, err = clientB.Check(ctx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			require.NoError(t, err)
		})
	}
}

func TestManagedPolicyRetainsTLSIdentityVerification(t *testing.T) {
	ca, key, caPEM := generateTestCAPEM(t)
	now := time.Now()
	cert, privateKey := generateTestLeafPEM(t, ca, key, 9, now.Add(-time.Hour), now.Add(time.Hour))
	server := policyTestProvider(t, caPEM, cert, privateKey)
	address := policyHealthServer(t, server)
	for _, invalid := range []string{"hostname", "issuer"} {
		t.Run(invalid, func(t *testing.T) {
			policy := certpolicy.New()
			defer policy.Close()
			require.NoError(t, policy.Apply(certpolicy.Snapshot{Version: 1, GeneratedAt: now, ValidUntil: now.Add(20 * time.Second), AllowedFingerprints: []string{certificateFingerprint(t, cert)}}))
			roots := caPEM
			if invalid == "issuer" {
				_, _, roots = generateTestCAPEM(t)
			}
			client := policyTestProvider(t, roots, cert, privateKey, WithPeerCertificatePolicy(policy))
			if invalid == "hostname" {
				require.NoError(t, client.clientCreds.OverrideServerName("wrong.example.test"))
			}
			healthClient := policyHealthClient(t, client, address)
			ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
			defer cancel()
			_, err := healthClient.Check(ctx, &healthpb.HealthCheckRequest{}, gogrpc.WaitForReady(true))
			require.Error(t, err, "allowlisted fingerprint must not bypass TLS identity checks")
		})
	}
}

func certificateFingerprint(t *testing.T, certPEM []byte) string {
	t.Helper()
	block, _ := pem.Decode(certPEM)
	require.NotNil(t, block)
	return fmt.Sprintf("%x", sha256.Sum256(block.Bytes))
}

func policyTestProvider(t *testing.T, ca, cert, key []byte, options ...MTLSOption) *MTLSProvider {
	t.Helper()
	dir := t.TempDir()
	for name, contents := range map[string][]byte{"root.pem": ca, "component.pem": cert, "component-key.pem": key} {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), contents, 0600))
	}
	provider, err := NewMTLSProvider(&models.SecurityConfig{Mode: SecurityModeMTLS, Role: models.RoleAgent, CertDir: dir, ServerName: "agent-synth-1.default.serviceradar", TLS: models.TLSConfig{CAFile: "root.pem", CertFile: "component.pem", KeyFile: "component-key.pem"}}, createTestLogger(t), options...)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, provider.Close()) })
	return provider
}

func policyHealthServer(t *testing.T, provider *MTLSProvider) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	option, err := provider.GetServerCredentials(context.Background())
	require.NoError(t, err)
	server := gogrpc.NewServer(option)
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(server, healthServer)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	return listener.Addr().String()
}

func policyHealthClient(t *testing.T, provider *MTLSProvider, address string) healthpb.HealthClient {
	t.Helper()
	option, err := provider.GetClientCredentials(context.Background())
	require.NoError(t, err)
	client, err := gogrpc.NewClient(address, option)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, client.Close()) })
	return healthpb.NewHealthClient(client)
}

func requireStreamClosed(t *testing.T, ended <-chan error) {
	t.Helper()
	select {
	case err := <-ended:
		require.Error(t, err)
	case <-time.After(4 * time.Second):
		t.Fatal("managed gRPC stream remained open after revocation or expiry")
	}
}
