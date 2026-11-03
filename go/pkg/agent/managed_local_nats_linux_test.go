package agent

import (
	"bytes"
	"context"
	"crypto/ecdsa"
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
	"math/big"
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
	boundaryID := "leaf-" + strings.Repeat("a", 31) + "-server.default.serviceradar"
	shortID := "leaf-short-server.default.serviceradar"
	if len(longID) != 65 || len(boundaryID) != 64 || len(shortID) > 64 || len(longCN) != 64 {
		t.Fatalf("synthetic DNS fixtures drifted: long=%d boundary=%d short=%d", len(longID), len(boundaryID), len(shortID))
	}
	longCfg := syntheticLocalNATSTLS(t, "leaf-"+strings.Repeat("a", 32))
	uri := &url.URL{Scheme: "spiffe", Host: "synthetic.example", Path: "/leaf"}
	authorized := localNATSServerCert(longCN, longID, nil)
	cases := []struct {
		name     string
		identity string
		cert     *x509.Certificate
		verified bool
		want     error
	}{
		{name: "long bounded cn", identity: longID, cert: authorized, verified: true},
		{name: "long full cn", identity: longID, cert: localNATSServerCert(longID, longID, nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "long wrong hash", identity: longID, cert: localNATSServerCert(strings.Repeat("ab", 32), longID, nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "long missing dns", identity: longID, cert: localNATSServerCert(longCN, "", nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "long other dns", identity: longID, cert: localNATSServerCert(longCN, "leaf-other-server.default.serviceradar", nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "long uri", identity: longID, cert: localNATSServerCert(longCN, longID, uri), verified: true, want: errLocalNATSServerIdentity},
		{name: "long revoked", identity: longID, cert: localNATSServerCert(longCN, longID, nil), verified: true, want: errLocalNATSServerRevoked},
		{name: "boundary full cn", identity: boundaryID, cert: localNATSServerCert(boundaryID, boundaryID, nil), verified: true},
		{name: "boundary hashed cn", identity: boundaryID, cert: localNATSServerCert(longCN, boundaryID, nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "short full cn", identity: shortID, cert: localNATSServerCert(shortID, shortID, nil), verified: true},
		{name: "short hashed cn", identity: shortID, cert: localNATSServerCert(longCN, shortID, nil), verified: true, want: errLocalNATSServerIdentity},
		{name: "missing pkix", identity: longID, cert: authorized, verified: false, want: errLocalNATSPKIX},
		{name: "missing peer", identity: longID, verified: true, want: errLocalNATSPKIX},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clearLocalReceiverFingerprints()
			state := tls.ConnectionState{}
			if tc.cert != nil {
				state.PeerCertificates = []*x509.Certificate{tc.cert}
			}
			if tc.verified {
				state.VerifiedChains = [][]*x509.Certificate{{tc.cert}}
			}
			err := verifyLocalNATSServer(state, tc.identity, func() (*managedCertificatePolicySnapshot, error) {
				fingerprint := strings.Repeat("cd", 32)
				if tc.want == nil && tc.cert != nil {
					fingerprint = fmt.Sprintf("%x", sha256.Sum256(tc.cert.Raw))
				}
				return &managedCertificatePolicySnapshot{AllowedFingerprints: []string{fingerprint}}, nil
			})
			if !errors.Is(err, tc.want) {
				t.Fatalf("receiver error = %v, want %v", err, tc.want)
			}
			fingerprint := ""
			if tc.cert != nil {
				fingerprint = fmt.Sprintf("%x", sha256.Sum256(tc.cert.Raw))
			}
			observed := localReceiverFingerprintHeader()
			if tc.want == nil && observed != fingerprint {
				t.Fatalf("receiver observation = %q", observed)
			}
			if tc.want != nil && observed != "" {
				t.Fatal("rejected server certificate was observed")
			}
		})
	}
	installed := localNATSReceiverState(authorized, true)
	if err := longCfg.VerifyConnection(installed); errors.Is(err, errLocalNATSServerIdentity) || errors.Is(err, errLocalNATSPKIX) {
		t.Fatalf("installed receiver rejected the bounded certificate before fingerprint authorization: %v", err)
	}
	direct := verifyLocalNATSServer(installed, longID, readLocalNATSPolicy)
	if err := longCfg.VerifyConnection(installed); err != direct && (err == nil || direct == nil || err.Error() != direct.Error()) {
		t.Fatalf("installed receiver = %v, decision = %v", err, direct)
	}
	rejected := localNATSReceiverState(localNATSServerCert(longID, longID, nil), true)
	if err := longCfg.VerifyConnection(rejected); !errors.Is(err, errLocalNATSServerIdentity) {
		t.Fatalf("installed receiver accepted the overlong common name: %v", err)
	}
}

func localNATSReceiverState(cert *x509.Certificate, verified bool) tls.ConnectionState {
	state := tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}
	if verified {
		state.VerifiedChains = [][]*x509.Certificate{{cert}}
	}
	return state
}

func syntheticLocalNATSTLS(t *testing.T, component string) *tls.Config {
	t.Helper()
	dir := t.TempDir()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "synthetic-agent"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	for name, data := range map[string][]byte{"ca.pem": certPEM, "client.pem": certPEM, "client.key": keyPEM} {
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
	return config
}

func localNATSServerCert(cn, dns string, uri *url.URL) *x509.Certificate {
	cert := &x509.Certificate{Raw: []byte("synthetic-der:" + cn), Subject: pkix.Name{CommonName: cn}}
	if dns != "" {
		cert.DNSNames = []string{dns}
	}
	if uri != nil {
		cert.URIs = []*url.URL{uri}
	}
	return cert
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
