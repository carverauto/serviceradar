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

package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	ggrpc "google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/go/pkg/datasvc"
	"github.com/carverauto/serviceradar/go/pkg/lifecycle"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	rulesKey = "zen/rulesets/events/logs.syslog.json"
	otherKey = "agents/agent01/config.json"
)

type testCA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pool *x509.CertPool
	pem  []byte
}

func newTestCA(t *testing.T) *testCA {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test-ca", Organization: []string{"Example"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	require.NoError(t, err)
	cert, err := x509.ParseCertificate(der)
	require.NoError(t, err)

	pool := x509.NewCertPool()
	pool.AddCert(cert)

	return &testCA{
		cert: cert,
		key:  key,
		pool: pool,
		pem:  pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
	}
}

// issue signs a leaf certificate and returns its PEM encoded cert and key.
func (ca *testCA) issue(t *testing.T, serial int64, cn string, usages []x509.ExtKeyUsage, ips ...net.IP) (certPEM, keyPEM []byte) {
	t.Helper()

	return ca.issueSubject(t, serial, pkix.Name{CommonName: cn, Organization: []string{"Example"}}, usages, ips...)
}

// issueSubject signs a leaf certificate carrying subject.
func (ca *testCA) issueSubject(t *testing.T, serial int64, subject pkix.Name, usages []x509.ExtKeyUsage, ips ...net.IP) (certPEM, keyPEM []byte) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      subject,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  usages,
		IPAddresses:  ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	require.NoError(t, err)
	keyDER, err := x509.MarshalECPrivateKey(key)
	require.NoError(t, err)

	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
}

func freeAddr(t *testing.T) string {
	t.Helper()

	lis, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	require.NoError(t, err)
	addr := lis.Addr().String()
	require.NoError(t, lis.Close())

	return addr
}

// startDatasvc runs datasvc with its production server options against an
// embedded JetStream server, both behind certificates issued by ca.
func startDatasvc(t *testing.T, ca *testCA, roles []datasvc.RBACRule) string {
	t.Helper()

	dir := t.TempDir()
	certPEM, keyPEM := ca.issue(t, 2, "datasvc", []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}, net.ParseIP("127.0.0.1"))
	certFile := filepath.Join(dir, "datasvc.pem")
	keyFile := filepath.Join(dir, "datasvc-key.pem")
	caFile := filepath.Join(dir, "root.pem")
	require.NoError(t, os.WriteFile(certFile, certPEM, 0o600))
	require.NoError(t, os.WriteFile(keyFile, keyPEM, 0o600))
	require.NoError(t, os.WriteFile(caFile, ca.pem, 0o600))

	serverCert, err := tls.X509KeyPair(certPEM, keyPEM)
	require.NoError(t, err)
	natsServer, err := server.NewServer(&server.Options{
		Host:       "127.0.0.1",
		Port:       -1,
		JetStream:  true,
		StoreDir:   t.TempDir(),
		TLSVerify:  true,
		TLSTimeout: 5,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{serverCert},
			ClientCAs:    ca.pool,
			ClientAuth:   tls.RequireAndVerifyClientCert,
			MinVersion:   tls.VersionTLS12,
		},
	})
	require.NoError(t, err)
	go natsServer.Start()
	t.Cleanup(natsServer.Shutdown)
	require.True(t, natsServer.ReadyForConnections(10*time.Second), "embedded NATS server not ready")

	security := &models.SecurityConfig{
		Mode: models.SecurityMode("mtls"),
		Role: models.RoleDataService,
		TLS:  models.TLSConfig{CertFile: certFile, KeyFile: keyFile, CAFile: caFile},
	}
	natsSecurity := *security
	cfg := &datasvc.Config{
		ListenAddr:   freeAddr(t),
		NATSURL:      natsServer.ClientURL(),
		Security:     security,
		NATSSecurity: &natsSecurity,
	}
	cfg.RBAC.Roles = roles

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	svc, err := datasvc.NewServer(ctx, cfg)
	require.NoError(t, err)
	t.Cleanup(func() { _ = svc.Stop(context.Background()) })

	go func() { _ = lifecycle.RunServer(ctx, serverOptions(cfg, svc, nil)) }()

	return cfg.ListenAddr
}

func dial(t *testing.T, ca *testCA, addr, cn string) *ggrpc.ClientConn {
	t.Helper()

	return dialSubject(t, ca, addr, pkix.Name{CommonName: cn, Organization: []string{"Example"}})
}

func dialSubject(t *testing.T, ca *testCA, addr string, subject pkix.Name) *ggrpc.ClientConn {
	t.Helper()

	certPEM, keyPEM := ca.issueSubject(t, time.Now().UnixNano(), subject, []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	require.NoError(t, err)

	conn, err := ggrpc.NewClient(addr, ggrpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      ca.pool,
		MinVersion:   tls.VersionTLS13,
	})))
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })

	return conn
}

func firstWatchValue(ctx context.Context, kv proto.KVServiceClient, key string) ([]byte, error) {
	stream, err := kv.Watch(ctx, &proto.WatchRequest{Key: key})
	if err != nil {
		return nil, err
	}

	resp, err := stream.Recv()
	if err != nil {
		return nil, err
	}

	return resp.GetValue(), nil
}

func firstDownloadChunk(ctx context.Context, data proto.DataServiceClient) error {
	stream, err := data.DownloadObject(ctx, &proto.DownloadObjectRequest{Key: rulesKey})
	if err != nil {
		return err
	}

	_, err = stream.Recv()

	return err
}

func uploadObject(ctx context.Context, data proto.DataServiceClient, key string) error {
	stream, err := data.UploadObject(ctx)
	if err != nil {
		return err
	}

	_ = stream.Send(&proto.ObjectUploadChunk{
		Metadata: &proto.ObjectMetadata{Key: key},
		Data:     []byte("payload"),
		IsFinal:  true,
	})
	_, err = stream.CloseAndRecv()

	return err
}

// TestDatasvcServerEnforcesRBAC drives the server main builds with real mTLS
// clients. The expected outcomes come from the documented role contract:
// readers read, writers write, unlisted identities reach nothing in the KV or
// object-store services, and a key-limited identity reaches only keys under
// its prefixes.
func TestDatasvcServerEnforcesRBAC(t *testing.T) {
	ca := newTestCA(t)
	addr := startDatasvc(t, ca, []datasvc.RBACRule{
		{Identity: "CN=writer01,O=Example", Role: datasvc.RoleWriter},
		{Identity: "CN=reader01,O=Example", Role: datasvc.RoleReader},
		{Identity: "CN=rules-reader,O=Example", Role: datasvc.RoleReader, KeyPrefixes: []string{"zen/rulesets/"}},
		{Identity: "CN=rules-writer,O=Example", Role: datasvc.RoleWriter, KeyPrefixes: []string{"zen/rulesets/"}},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	unlisted := dial(t, ca, addr, "stranger01")
	health := healthpb.NewHealthClient(unlisted)
	require.Eventually(t, func() bool {
		resp, err := health.Check(ctx, &healthpb.HealthCheckRequest{})
		return err == nil && resp.GetStatus() == healthpb.HealthCheckResponse_SERVING
	}, 15*time.Second, 100*time.Millisecond, "health check from an unlisted identity must succeed")

	_, err := proto.NewKVServiceClient(unlisted).Get(ctx, &proto.GetRequest{Key: rulesKey})
	assert.Equal(t, codes.PermissionDenied, status.Code(err), "unlisted identity Get")

	writer := proto.NewKVServiceClient(dial(t, ca, addr, "writer01"))
	_, err = writer.Put(ctx, &proto.PutRequest{Key: rulesKey, Value: []byte("rules")})
	require.NoError(t, err, "writer Put")
	_, err = writer.Put(ctx, &proto.PutRequest{Key: otherKey, Value: []byte("other")})
	require.NoError(t, err, "writer Put")

	reader := proto.NewKVServiceClient(dial(t, ca, addr, "reader01"))
	got, err := reader.Get(ctx, &proto.GetRequest{Key: otherKey})
	require.NoError(t, err, "reader Get")
	assert.Equal(t, []byte("other"), got.GetValue())
	_, err = reader.Put(ctx, &proto.PutRequest{Key: otherKey, Value: []byte("changed")})
	assert.Equal(t, codes.PermissionDenied, status.Code(err), "reader Put")

	limitedConn := dial(t, ca, addr, "rules-reader")
	limited := proto.NewKVServiceClient(limitedConn)

	got, err = limited.Get(ctx, &proto.GetRequest{Key: rulesKey})
	require.NoError(t, err, "limited Get of its own key")
	assert.Equal(t, []byte("rules"), got.GetValue())

	watchCtx, stopWatch := context.WithCancel(ctx)
	value, err := firstWatchValue(watchCtx, limited, rulesKey)
	stopWatch()
	require.NoError(t, err, "limited Watch of its own key")
	assert.Equal(t, []byte("rules"), value)

	listed, err := limited.ListKeys(ctx, &proto.ListKeysRequest{Prefix: "zen/rulesets/"})
	require.NoError(t, err, "limited ListKeys inside its prefix")
	assert.Equal(t, []string{rulesKey}, listed.GetKeys())

	denied := map[string]error{}
	_, denied["Get outside its prefix"] = limited.Get(ctx, &proto.GetRequest{Key: otherKey})
	_, denied["Watch outside its prefix"] = firstWatchValue(ctx, limited, otherKey)
	_, denied["ListKeys of every key"] = limited.ListKeys(ctx, &proto.ListKeysRequest{})
	_, denied["ListKeys of a wider prefix"] = limited.ListKeys(ctx, &proto.ListKeysRequest{Prefix: "zen/"})
	_, denied["Put of its own key"] = limited.Put(ctx, &proto.PutRequest{Key: rulesKey, Value: []byte("x")})
	_, denied["Info"] = limited.Info(ctx, &proto.InfoRequest{})
	objects := proto.NewDataServiceClient(limitedConn)
	_, denied["GetObjectInfo"] = objects.GetObjectInfo(ctx, &proto.GetObjectInfoRequest{Key: rulesKey})
	_, denied["ListObjects"] = objects.ListObjects(ctx, &proto.ListObjectsRequest{})
	denied["DownloadObject"] = firstDownloadChunk(ctx, objects)
	denied["UploadObject as a key-limited writer"] = uploadObject(ctx, proto.NewDataServiceClient(dial(t, ca, addr, "rules-writer")), rulesKey)

	for name, err := range denied {
		assert.Equal(t, codes.PermissionDenied, status.Code(err), "limited identity %s: %v", name, err)
	}
}

// TestDatasvcServerMatchesChartRolesOnCommonName runs the server with the
// Helm chart's certificate rules, which name each platform component by
// common name only. The oracle is that contract: a component certificate is
// authorized whatever organization, unit, locality, state or country it
// carries, while edge certificates (CN <component>.<partition>.serviceradar or
// a 64-hex hash) and look-alike names match no rule.
func TestDatasvcServerMatchesChartRolesOnCommonName(t *testing.T) {
	ca := newTestCA(t)
	// Same identities as the certificate rules in
	// helm/serviceradar/files/serviceradar-config.yaml.
	addr := startDatasvc(t, ca, []datasvc.RBACRule{
		{Identity: "CN=serviceradar-agent", Role: datasvc.RoleReader},
		{Identity: "CN=serviceradar-log-collector", Role: datasvc.RoleReader, KeyPrefixes: []string{"zen/rulesets/"}},
		{Identity: "CN=serviceradar-core", Role: datasvc.RoleWriter},
		{Identity: "CN=serviceradar-web-ng", Role: datasvc.RoleWriter},
		{Identity: "CN=serviceradar-agent-gateway", Role: datasvc.RoleWriter},
		{Identity: "CN=serviceradar-falcosidekick", Role: datasvc.RoleReader},
		{Identity: "CN=serviceradar-tools", Role: datasvc.RoleReader},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	otherSubject := func(cn string) pkix.Name {
		return pkix.Name{
			CommonName:         cn,
			Organization:       []string{"Other Org"},
			OrganizationalUnit: []string{"Platform"},
			Locality:           []string{"Springfield"},
			Province:           []string{"ZZ"},
			Country:            []string{"XX"},
		}
	}
	chartSubject := func(cn string) pkix.Name {
		return pkix.Name{
			CommonName:         cn,
			Organization:       []string{"ServiceRadar"},
			OrganizationalUnit: []string{"Kubernetes"},
			Locality:           []string{"San Francisco"},
			Province:           []string{"CA"},
			Country:            []string{"US"},
		}
	}

	core := proto.NewKVServiceClient(dialSubject(t, ca, addr, otherSubject("serviceradar-core")))
	require.Eventually(t, func() bool {
		_, err := core.Put(ctx, &proto.PutRequest{Key: rulesKey, Value: []byte("rules")})
		return err == nil
	}, 15*time.Second, 100*time.Millisecond, "core with another subject must be authorized as writer")
	_, err := core.Put(ctx, &proto.PutRequest{Key: otherKey, Value: []byte("other")})
	require.NoError(t, err, "core Put")

	tests := []struct {
		name    string
		subject pkix.Name
		get     codes.Code // Get of otherKey
		getRule codes.Code // Get of rulesKey
		put     codes.Code
	}{
		{"core, other subject", otherSubject("serviceradar-core"), codes.OK, codes.OK, codes.OK},
		{"web-ng, other subject", otherSubject("serviceradar-web-ng"), codes.OK, codes.OK, codes.OK},
		{"agent-gateway, other subject", otherSubject("serviceradar-agent-gateway"), codes.OK, codes.OK, codes.OK},
		{"core, chart subject", chartSubject("serviceradar-core"), codes.OK, codes.OK, codes.OK},
		{"agent reader", otherSubject("serviceradar-agent"), codes.OK, codes.OK, codes.PermissionDenied},
		{"tools reader", chartSubject("serviceradar-tools"), codes.OK, codes.OK, codes.PermissionDenied},
		{"log collector", otherSubject("serviceradar-log-collector"), codes.PermissionDenied, codes.OK, codes.PermissionDenied},
		{"look-alike name", chartSubject("serviceradar-core-evil"), codes.PermissionDenied, codes.PermissionDenied, codes.PermissionDenied},
		{"edge agent name", chartSubject("agent01.default.serviceradar"), codes.PermissionDenied, codes.PermissionDenied, codes.PermissionDenied},
		{"edge hash name", chartSubject("3f2a9c1e7b4d6058a1c2e3f4a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"), codes.PermissionDenied, codes.PermissionDenied, codes.PermissionDenied},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			kv := proto.NewKVServiceClient(dialSubject(t, ca, addr, tc.subject))

			_, err := kv.Get(ctx, &proto.GetRequest{Key: otherKey})
			assert.Equal(t, tc.get, status.Code(err), "Get %s: %v", otherKey, err)
			_, err = kv.Get(ctx, &proto.GetRequest{Key: rulesKey})
			assert.Equal(t, tc.getRule, status.Code(err), "Get %s: %v", rulesKey, err)
			_, err = kv.Put(ctx, &proto.PutRequest{Key: otherKey, Value: []byte("other")})
			assert.Equal(t, tc.put, status.Code(err), "Put %s: %v", otherKey, err)
		})
	}
}
