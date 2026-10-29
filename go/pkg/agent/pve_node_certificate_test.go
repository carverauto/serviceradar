package agent

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"math/big"
	"net"
	"testing"
	"time"

	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

// servePVECertificate stands in for a local pveproxy: a loopback TLS listener
// presenting a self-signed certificate with the given subject. It returns the
// listener address and the SHA-256 of the presented certificate.
func servePVECertificate(t *testing.T, subject pkix.Name) (string, string) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      subject,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"node-a.example.com"},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}

	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				_ = conn.(*tls.Conn).HandshakeContext(context.Background())
			}()
		}
	}()

	digest := sha256.Sum256(der)

	return listener.Addr().String(), hex.EncodeToString(digest[:])
}

func probeAt(t *testing.T, address string) pveCertificateProbe {
	t.Helper()

	return pveCertificateProbe{configDir: t.TempDir(), address: address, port: 8006, timeout: 2 * time.Second}
}

func TestPVECertificateProbeReportsTheNodeCertificate(t *testing.T) {
	address, want := servePVECertificate(t, pkix.Name{
		OrganizationalUnit: []string{"PVE Cluster Node"},
		Organization:       []string{"Proxmox Virtual Environment"},
		CommonName:         "node-a.example.com",
	})

	got := probeAt(t, address).fingerprints()
	if len(got) != 1 || !gproto.Equal(got[0], &proto.HostTlsFingerprint{Port: 8006, Sha256: want}) {
		t.Fatalf("fingerprints = %v, want port 8006 sha256 %s", got, want)
	}
}

// A custom or ACME certificate can be one wildcard shared by many nodes, so the
// agent never reports it as host identity.
func TestPVECertificateProbeIgnoresACertificateThatIsNotTheNodes(t *testing.T) {
	address, _ := servePVECertificate(t, pkix.Name{CommonName: "*.example.com", Organization: []string{"Example"}})

	if got := probeAt(t, address).fingerprints(); got != nil {
		t.Fatalf("fingerprints = %v, want none for a non-node certificate", got)
	}
}

func TestPVECertificateProbeReportsNothingOffAProxmoxNode(t *testing.T) {
	address, _ := servePVECertificate(t, pkix.Name{OrganizationalUnit: []string{"PVE Cluster Node"}})

	probe := probeAt(t, address)
	probe.configDir += "/absent"
	if got := probe.fingerprints(); got != nil {
		t.Fatalf("fingerprints without /etc/pve = %v, want none", got)
	}

	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closed := listener.Addr().String()
	_ = listener.Close()
	if got := probeAt(t, closed).fingerprints(); got != nil {
		t.Fatalf("fingerprints with nothing listening = %v, want none", got)
	}
}

func TestBothHellosCarryTheHostCertificateFingerprints(t *testing.T) {
	want := []*proto.HostTlsFingerprint{{Port: 8006, Sha256: "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"}}

	loop := NewPushLoop(&Server{config: &ServerConfig{}}, nil, 0, logger.NewTestLogger())
	loop.hostInventory = func() []hostInterface { return nil }
	loop.hostTLSFingerprints = func() []*proto.HostTlsFingerprint { return want }

	stream := &fakeControlStreamClient{}
	if err := loop.sendControlHello(newControlStreamSender(stream)); err != nil {
		t.Fatal(err)
	}
	if len(stream.sent) == 0 || stream.sent[0].GetHello() == nil {
		t.Fatal("control stream did not send an initial hello")
	}

	for transport, got := range map[string][]*proto.HostTlsFingerprint{
		"control":    stream.sent[0].GetHello().GetHostTlsFingerprints(),
		"enrollment": loop.buildEnrollmentHelloRequest().GetHostTlsFingerprints(),
	} {
		if len(got) != 1 || !gproto.Equal(got[0], want[0]) {
			t.Fatalf("%s hello fingerprints = %v, want %v", transport, got, want)
		}
	}
}
