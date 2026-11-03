package agent

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/nats-io/nkeys"
	"github.com/rs/zerolog"
)

type localNATSLogCapture struct {
	logger.Logger
	output zerolog.Logger
}

func (l *localNATSLogCapture) Warn() *zerolog.Event  { return l.output.Warn() }
func (l *localNATSLogCapture) Debug() *zerolog.Event { return l.output.Debug() }

// localNATSLogBuffer serializes the authorizer goroutine's log writes with the
// test goroutine's snapshots. bytes.Buffer is not safe for that overlap, which
// synctest.Wait can allow while a filesystem call is in progress.
type localNATSLogBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *localNATSLogBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *localNATSLogBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *localNATSLogBuffer) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Len()
}

func TestManagedLocalNATSLoopExitsInContainer(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "192.0.2.1")
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		done := make(chan struct{})
		go func() {
			p.managedLocalNATSLoop(ctx)
			close(done)
		}()
		synctest.Wait()
		select {
		case <-done:
		default:
			t.Error("unconfigured container kept the local NATS retry loop running")
		}
		cancel()
		<-done
		if output.Len() != 0 {
			t.Fatalf("unconfigured container logged an authorization failure: %s", output.String())
		}
	})
}

func TestManagedLocalNATSUnconfiguredUnsafeRootDoesNotRetry(t *testing.T) {
	root := t.TempDir()
	if err := os.Chown(root, 10001, 10001); err != nil {
		t.Fatal(err)
	}
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithTimeout(t.Context(), time.Second)
		defer cancel()
		store := managedCertificateStore{root: root}
		started := time.Now()
		store.runLocalNATSLoop(ctx, p)
		if elapsed := time.Since(started); elapsed != 0 {
			t.Fatalf("absent local authority entered the retry loop for %s", elapsed)
		}
		if output.Len() != 0 {
			t.Fatalf("absent local authority checked unrelated root ownership: %s", output.String())
		}
	})
}

func TestManagedLocalNATSFailureLogsOnlyOnChangeAndStopsWhenUnconfigured(t *testing.T) {
	root := t.TempDir()
	metadataPath := filepath.Join(root, "local-nats.json")
	if err := os.WriteFile(metadataPath, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(root, 10001, 10001); err != nil {
		t.Fatal(err)
	}
	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)}}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		store := managedCertificateStore{root: root}
		done := make(chan struct{})
		go func() {
			store.runLocalNATSLoop(ctx, p)
			close(done)
		}()
		time.Sleep(16 * time.Second)
		synctest.Wait()
		levels := localNATSLogLevels(t, output.String())
		if levels["warn"] != 1 || levels["debug"] != 3 {
			t.Fatalf("repeated unsafe-root error did not stay at bounded debug retries: %v", levels)
		}
		if !strings.Contains(output.String(), ErrAddonPrivilegedRootUnsafe.Error()) {
			t.Fatal("configured local authority did not enforce root ownership")
		}

		// Repairing ownership exposes a different, real failure: invalid metadata.
		if err := os.Chown(root, 0, 0); err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Second)
		synctest.Wait()
		levels = localNATSLogLevels(t, output.String())
		if levels["warn"] != 2 || levels["debug"] != 3 {
			t.Fatalf("changed error did not get one new warning: %v", levels)
		}
		if !strings.Contains(output.String(), errLocalNATSAuthorityMetadata.Error()) {
			t.Fatal("changed metadata error was not reported")
		}

		if err := os.Remove(metadataPath); err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Second)
		synctest.Wait()
		select {
		case <-done:
		default:
			t.Fatal("removed local authority kept the retry loop running")
		}
	})
}

func TestManagedLocalNATSMissingClientCertificateRetries(t *testing.T) {
	root := t.TempDir()
	if err := os.Chown(root, 0, 0); err != nil {
		t.Fatal(err)
	}
	account, err := nkeys.CreateAccount()
	if err != nil {
		t.Fatal(err)
	}
	user, err := nkeys.CreateUser()
	if err != nil {
		t.Fatal(err)
	}
	issuer, err := account.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	auth, err := user.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	metadata, err := json.Marshal(managedLocalNATSMetadata{
		managedLocalNATSBinding: managedLocalNATSBinding{
			ComponentID: "local-nats",
			HostAgentID: "agent-under-test",
			PartitionID: "partition-a",
		},
		IssuerPublicKey:   issuer,
		AuthUserPublicKey: auth,
	})
	if err != nil {
		t.Fatal(err)
	}
	metadataPath := filepath.Join(root, "local-nats.json")
	if err := os.WriteFile(metadataPath, metadata, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(metadataPath, 0, 0); err != nil {
		t.Fatal(err)
	}
	certFile := filepath.Join(root, "client.pem")
	if _, err := os.Lstat(certFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("client certificate fixture must be absent, got %v", err)
	}

	synctest.Test(t, func(t *testing.T) {
		output := &localNATSLogBuffer{}
		p := &PushLoop{
			logger: &localNATSLogCapture{Logger: logger.NewTestLogger(), output: zerolog.New(output)},
			server: &Server{config: &ServerConfig{
				AgentID:   "agent-under-test",
				Partition: "partition-a",
				GatewaySecurity: &models.SecurityConfig{
					Mode: models.SecurityModeMTLS,
					TLS: models.TLSConfig{
						CertFile: certFile,
						KeyFile:  filepath.Join(root, "client.key"),
						CAFile:   filepath.Join(root, "ca.pem"),
					},
				},
			}},
		}
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		store := managedCertificateStore{root: root}
		done := make(chan struct{})
		go func() {
			store.runLocalNATSLoop(ctx, p)
			close(done)
		}()
		time.Sleep(16 * time.Second)
		synctest.Wait()
		select {
		case <-done:
			t.Fatal("configured local authority exited on a missing client certificate")
		default:
		}
		levels := localNATSLogLevels(t, output.String())
		if levels["warn"] != 1 || levels["debug"] != 3 {
			t.Fatalf("missing client certificate did not stay at bounded debug retries: %v", levels)
		}
		if !strings.Contains(output.String(), certFile) {
			t.Fatalf("missing client certificate was not reported: %s", output.String())
		}
		cancel()
		<-done
	})
}

func TestLocalNATSReceiverAcceptsBoundedServerCommonName(t *testing.T) {
	clearLocalReceiverFingerprints()
	t.Cleanup(clearLocalReceiverFingerprints)

	// Independent oracle: lowercase SHA-256 of the 65-character DNS identity.
	const longCN = "799d3721353e6858d032b4b8c95d6a537b4619c76a54369a0457863f56384e5f"
	longID := "leaf-" + strings.Repeat("a", 32) + "-server.default.serviceradar"
	shortID := "leaf-short-server.default.serviceradar"
	if len(longID) != 65 || len(shortID) > 64 || len(longCN) != 64 {
		t.Fatalf("synthetic DNS fixtures drifted: long=%d short=%d", len(longID), len(shortID))
	}
	if managedCertificateCommonName(longID) != longCN || managedCertificateCommonName(shortID) != shortID {
		t.Fatal("bounded common name helper drifted from the synthetic oracle")
	}

	longClient, ca, caKey := syntheticLocalNATSTLS(t, "leaf-"+strings.Repeat("a", 32))
	shortClient, shortCA, shortKey := syntheticLocalNATSTLS(t, "leaf-short")
	authorized := localNATSServerCertificate(t, ca, caKey, longCN, []string{longID, "localhost"}, nil)
	shortCert := localNATSServerCertificate(t, shortCA, shortKey, shortID, []string{shortID, "localhost"}, nil)
	uri, err := url.Parse("spiffe://synthetic.example/leaf")
	if err != nil {
		t.Fatal(err)
	}
	overlong := localNATSServerCertificate(t, ca, caKey, longID, []string{longID, "localhost"}, nil)
	withURI := localNATSServerCertificate(t, ca, caKey, longCN, []string{longID, "localhost"}, uri)
	missingDNS := localNATSServerCertificate(t, ca, caKey, longCN, []string{"localhost"}, nil)
	otherCA, otherKey := syntheticCertificateAuthority(t)
	untrusted := localNATSServerCertificate(t, otherCA, otherKey, longCN, []string{longID, "localhost"}, nil)

	if err := longClient.VerifyConnection(tls.ConnectionState{}); !errors.Is(err, errLocalNATSPKIX) {
		t.Fatalf("missing PKIX result = %v", err)
	}
	if localReceiverFingerprintHeader() != "" {
		t.Fatal("unverified server certificate was observed")
	}

	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	prepareLocalNATSPolicyPath(t)
	useSignedLocalNATSPolicy(t, now, []string{certificateDERFingerprint(authorized), certificateDERFingerprint(shortCert)}, public, private)

	requireLocalNATSAcceptance(t, longClient, authorized)
	requireLocalNATSAcceptance(t, shortClient, shortCert)
	requireLocalNATSRejection(t, longClient, overlong, errLocalNATSServerIdentity)
	requireLocalNATSRejection(t, longClient, withURI, errLocalNATSServerIdentity)
	requireLocalNATSRejection(t, longClient, missingDNS, errLocalNATSServerIdentity)
	requireUntrustedLocalNATS(t, longClient, untrusted)

	useSignedLocalNATSPolicy(t, now.Add(time.Second), []string{strings.Repeat("ab", 32)}, public, private)
	requireLocalNATSRejection(t, longClient, authorized, errLocalNATSServerRevoked)

	if err := os.Remove(ManagedCertificatePolicyPath); err != nil {
		t.Fatal(err)
	}
	requireLocalNATSRejection(t, longClient, authorized, os.ErrNotExist)
	requireLocalNATSRejection(t, longClient, overlong, errLocalNATSServerIdentity)
}

func requireLocalNATSAcceptance(t *testing.T, client *tls.Config, server tls.Certificate) {
	t.Helper()
	clearLocalReceiverFingerprints()
	if err := dialManagedLocalNATS(t, client, server); err != nil {
		t.Fatalf("authorized server rejected: %v", err)
	}
	if got := localReceiverFingerprintHeader(); got != certificateDERFingerprint(server) {
		t.Fatalf("receiver observation = %q", got)
	}
}

func requireLocalNATSRejection(t *testing.T, client *tls.Config, server tls.Certificate, want error) {
	t.Helper()
	clearLocalReceiverFingerprints()
	err := dialManagedLocalNATS(t, client, server)
	if !errors.Is(err, want) {
		t.Fatalf("receiver error = %v, want %v", err, want)
	}
	if localReceiverFingerprintHeader() != "" {
		t.Fatal("rejected server certificate was observed")
	}
}

func requireUntrustedLocalNATS(t *testing.T, client *tls.Config, server tls.Certificate) {
	t.Helper()
	clearLocalReceiverFingerprints()
	err := dialManagedLocalNATS(t, client, server)
	var unknown x509.UnknownAuthorityError
	if err == nil || !errors.As(err, &unknown) {
		t.Fatalf("PKIX accepted an untrusted server: %v", err)
	}
	if localReceiverFingerprintHeader() != "" {
		t.Fatal("untrusted server certificate was observed")
	}
}

func dialManagedLocalNATS(t *testing.T, client *tls.Config, server tls.Certificate) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	serverErr := make(chan error, 1)
	go func() {
		raw, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer func() { _ = raw.Close() }()
		conn := tls.Server(raw, &tls.Config{Certificates: []tls.Certificate{server}, MinVersion: tls.VersionTLS13})
		if err := conn.HandshakeContext(ctx); err != nil {
			serverErr <- err
			return
		}
		serverErr <- nil
		_, _ = io.Copy(io.Discard, conn)
	}()
	raw, err := (&net.Dialer{}).DialContext(ctx, "tcp", listener.Addr().String())
	if err != nil {
		return err
	}
	defer func() { _ = raw.Close() }()
	conn := tls.Client(raw, client.Clone())
	if err := conn.HandshakeContext(ctx); err != nil {
		if remote := <-serverErr; remote != nil {
			return fmt.Errorf("%w (server: %w)", err, remote)
		}
		return err
	}
	if remote := <-serverErr; remote != nil {
		return remote
	}
	return nil
}

func prepareLocalNATSPolicyPath(t *testing.T) {
	t.Helper()
	// readLocalNATSPolicy has one path. This test runs as root in its own container.
	if _, err := os.Lstat(ManagedCertificatePolicyPath); err == nil {
		t.Fatalf("refusing to replace certificate policy %s", ManagedCertificatePolicyPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	dir := filepath.Dir(ManagedCertificatePolicyPath)
	_, dirErr := os.Lstat(dir)
	created := errors.Is(dirErr, os.ErrNotExist)
	if dirErr != nil && !created {
		t.Fatal(dirErr)
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Remove(ManagedCertificatePolicyPath)
		if created {
			_ = os.Remove(dir)
		}
	})
}

func useSignedLocalNATSPolicy(t *testing.T, when time.Time, fingerprints []string, public ed25519.PublicKey, private ed25519.PrivateKey) {
	t.Helper()
	when = when.UTC()
	snapshot := managedCertificatePolicySnapshot{Version: 1, GeneratedAt: when, ValidUntil: when.Add(30 * time.Second), AllowedFingerprints: fingerprints}
	store := managedCertificatePolicyStore{path: ManagedCertificatePolicyPath, key: public, now: func() time.Time { return when }}
	if _, err := store.install(signedManagedPolicy(t, private, snapshot)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(ManagedCertificatePolicyPath, 0, 0); err != nil {
		t.Fatal(err)
	}
}

func syntheticLocalNATSTLS(t *testing.T, component string) (*tls.Config, *x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	dir := t.TempDir()
	ca, caKey := syntheticCertificateAuthority(t)
	clientKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "synthetic-agent"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	clientDER, err := x509.CreateCertificate(rand.Reader, clientTemplate, ca, &clientKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca.Raw})
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: clientDER})
	keyDER, err := x509.MarshalECPrivateKey(clientKey)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	for name, data := range map[string][]byte{"ca.pem": caPEM, "client.pem": certPEM, "client.key": keyPEM} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	config, err := localNATSTLS(ServerConfig{
		AgentID:   "agent-synthetic",
		Partition: "default",
		GatewaySecurity: &models.SecurityConfig{
			Mode: models.SecurityModeMTLS,
			TLS: models.TLSConfig{
				CertFile: filepath.Join(dir, "client.pem"),
				KeyFile:  filepath.Join(dir, "client.key"),
				CAFile:   filepath.Join(dir, "ca.pem"),
			},
		},
	}, &managedLocalNATSMetadata{managedLocalNATSBinding: managedLocalNATSBinding{
		ComponentID: component, HostAgentID: "agent-synthetic", PartitionID: "default",
	}})
	if err != nil {
		t.Fatal(err)
	}
	return config, ca, caKey
}

func syntheticCertificateAuthority(t *testing.T) (*x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "synthetic-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return cert, key
}

func localNATSServerCertificate(t *testing.T, ca *x509.Certificate, caKey *ecdsa.PrivateKey, cn string, dns []string, uri *url.URL) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     dns,
	}
	if uri != nil {
		template.URIs = []*url.URL{uri}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}

func certificateDERFingerprint(cert tls.Certificate) string {
	return fmt.Sprintf("%x", sha256.Sum256(cert.Leaf.Raw))
}

func localNATSLogLevels(t *testing.T, output string) map[string]int {
	t.Helper()
	levels := make(map[string]int)
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		var entry struct {
			Level string `json:"level"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatal(err)
		}
		levels[entry.Level]++
	}
	return levels
}
