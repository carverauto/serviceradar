package agent

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/natsutil"
)

// Static test error for err113 compliance.
var errManagedServiceFailed = errors.New("service failed")

type managedCertificateFixture struct {
	store      managedCertificateStore
	ca         *x509.Certificate
	key        *ecdsa.PrivateKey
	operations []managedCertificateAdapter
}

func newManagedCertificateFixture(t *testing.T) *managedCertificateFixture {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Synthetic deployment CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(30 * 24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	ca, err = x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	f := &managedCertificateFixture{ca: ca, key: key}
	f.store = managedCertificateStore{root: t.TempDir(), agentID: "agent-synthetic", partition: "default", roots: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), now: func() time.Time { return now }, owner: func(string) (int, int, error) { return os.Getuid(), os.Getgid(), nil }, activate: func(_ context.Context, a managedCertificateAdapter) error {
		f.operations = append(f.operations, a)
		return nil
	}}
	return f
}

func (f *managedCertificateFixture) prepare(t *testing.T, id, service string) (*ManagedCertificatePreparation, ManagedCertificateAssignment) {
	t.Helper()
	a := ManagedCertificateAssignment{RequestID: id, ComponentID: "component-synthetic", HostAgentID: "agent-synthetic", PartitionID: "default", Generation: 1, Service: service}
	if service == managedServiceNATSLeaf {
		a.ServerHosts = []string{"leaf.example.test", "192.0.2.10"}
	}
	prepared, err := f.store.prepare(a)
	if err != nil {
		t.Fatal(err)
	}
	return prepared, a
}

func (f *managedCertificateFixture) issue(t *testing.T, p *ManagedCertificatePreparation, mutate func(string, *x509.Certificate)) ManagedCertificateInstallRequest {
	t.Helper()
	req := ManagedCertificateInstallRequest{RequestID: p.RequestID, Generation: p.Generation, Certificates: map[string]ManagedCertificateIssued{}}
	for role, csrBytes := range p.CSRs {
		csr, err := x509.ParseCertificateRequest(csrBytes.CSRDER)
		if err != nil {
			t.Fatal(err)
		}
		if err = csr.CheckSignature(); err != nil {
			t.Fatal(err)
		}
		usage := x509.ExtKeyUsageClientAuth
		if role == managedRoleLocalServer {
			usage = x509.ExtKeyUsageServerAuth
		}
		cert := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: csr.Subject, NotBefore: f.store.now().Add(-time.Minute), NotAfter: f.store.now().Add(24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}}
		applyPlainIssuerNames(csr, cert)
		if mutate != nil {
			mutate(role, cert)
		}
		der, err := x509.CreateCertificate(rand.Reader, cert, f.ca, csr.PublicKey, f.key)
		if err != nil {
			t.Fatal(err)
		}
		req.Certificates[role] = ManagedCertificateIssued{CertificatePEM: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), CAChainPEM: string(f.store.roots)}
	}
	return req
}

func TestManagedCertificatesPrepareAndInstallAcrossRestart(t *testing.T) {
	previousUmask := syscall.Umask(0077)
	defer syscall.Umask(previousUmask)
	f := newManagedCertificateFixture(t)
	p, a := f.prepare(t, "prepare-1", managedServiceNATSLeaf)
	restarted := f.store
	again, err := restarted.prepare(a)
	if err != nil || !reflect.DeepEqual(p, again) {
		t.Fatalf("prepare retry changed CSR: %v", err)
	}
	a.Generation++
	if _, err := restarted.prepare(a); err == nil {
		t.Fatal("accepted changed assignment under existing request ID")
	}
	info, err := os.Stat(f.store.requestPath(p.RequestID))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("private keys not stored privately: %v", err)
	}
	assertPreparedManagedLeafIdentities(t, p)
	assertManagedLeafInstalled(t, f, restarted, p)
}

func assertPreparedManagedLeafIdentities(t *testing.T, p *ManagedCertificatePreparation) {
	t.Helper()
	client, err := x509.ParseCertificateRequest(p.CSRs["upstream_client"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	server, err := x509.ParseCertificateRequest(p.CSRs[managedRoleLocalServer].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	if reflect.DeepEqual(client.RawSubjectPublicKeyInfo, server.RawSubjectPublicKeyInfo) {
		t.Fatal("leaf roles reused private key")
	}
	if len(client.URIs) != 0 || client.Subject.CommonName != "component-synthetic.default.serviceradar" || len(server.URIs) != 0 || server.Subject.CommonName != "component-synthetic-server.default.serviceradar" {
		t.Fatal("wrong certificate identities")
	}
	if !reflect.DeepEqual(server.DNSNames, []string{"localhost", "leaf.example.test"}) || !server.IPAddresses[1].Equal(net.ParseIP("192.0.2.10")) {
		t.Fatal("missing requested server identities")
	}
}

func assertManagedLeafInstalled(t *testing.T, f *managedCertificateFixture, store managedCertificateStore, p *ManagedCertificatePreparation) {
	t.Helper()
	req := f.issue(t, p, nil)
	result, err := store.install(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Installed || !result.Activated || result.RolledBack || !result.RenewAfter.After(f.store.now()) || !result.RenewAfter.Before(f.store.now().Add(24*time.Hour)) {
		t.Fatalf("unexpected install receipt: %+v", result)
	}
	for _, paths := range result.Files {
		for _, dir := range []string{filepath.Dir(paths.KeyPath), filepath.Join(f.store.root, "component-synthetic"), filepath.Join(f.store.root, "component-synthetic", "generations")} {
			info, err := os.Stat(dir)
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0755 {
				t.Fatalf("managed directory prevents service traversal: %s mode=%o", dir, info.Mode().Perm())
			}
		}
		pair, err := tls.LoadX509KeyPair(paths.CertificatePath, paths.KeyPath)
		if err != nil {
			t.Fatal(err)
		}
		if len(pair.Certificate) != 1 {
			t.Fatal("unexpected root in served chain")
		}
		info, err := os.Stat(paths.KeyPath)
		if err != nil || info.Mode().Perm() != 0400 {
			t.Fatalf("key permissions: %v", err)
		}
	}
	if len(f.operations) != 1 || f.operations[0].unit != "serviceradar-nats.service" || f.operations[0].operation != "reload-or-restart" {
		t.Fatalf("unexpected service activation: %+v", f.operations)
	}
	retry, err := store.install(context.Background(), req)
	if err != nil || !reflect.DeepEqual(result, retry) || len(f.operations) != 1 {
		t.Fatalf("install retry repeated activation: %v", err)
	}
}

func TestManagedCertificatesRejectInvalidRotationWithoutTouchingCurrent(t *testing.T) {
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "old", "log-collector")
	old, err := f.store.install(context.Background(), f.issue(t, p, nil))
	if err != nil {
		t.Fatal(err)
	}
	oldBytes, err := os.ReadFile(old.Files["client"].CertificatePath)
	if err != nil {
		t.Fatal(err)
	}
	now := f.store.now().Add(time.Second)
	f.store.now = func() time.Time { return now }
	p, _ = f.prepare(t, "next", "log-collector")
	cases := map[string]func(string, *x509.Certificate){
		"expired":        func(_ string, c *x509.Certificate) { c.NotAfter = now.Add(-time.Second) },
		"not-yet-valid":  func(_ string, c *x509.Certificate) { c.NotBefore = now.Add(time.Hour) },
		"wrong-identity": func(_ string, c *x509.Certificate) { c.Subject.CommonName = "other.default.serviceradar" },
		"wrong-host":     func(_ string, c *x509.Certificate) { c.DNSNames = []string{"unexpected.example.test"} },
		"wrong-usage":    func(_ string, c *x509.Certificate) { c.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := f.store.install(context.Background(), f.issue(t, p, mutate)); err == nil {
				t.Fatal("accepted invalid certificate")
			}
		})
	}
	wrongKey := f.issue(t, p, nil)
	wrongKey.Certificates["client"] = f.issue(t, &ManagedCertificatePreparation{RequestID: "unused", Generation: 1, CSRs: map[string]ManagedCertificateCSR{"client": {CSRDER: mustOtherManagedCSR(t)}}}, nil).Certificates["client"]
	if _, err := f.store.install(context.Background(), wrongKey); err == nil {
		t.Fatal("accepted a certificate for another private key")
	}
	otherCA := newManagedCertificateFixture(t)
	if _, err := f.store.install(context.Background(), otherCA.issue(t, p, nil)); err == nil {
		t.Fatal("trusted a response-provided CA instead of installed deployment root")
	}
	after, err := os.ReadFile(old.Files["client"].CertificatePath)
	if err != nil || string(after) != string(oldBytes) || len(f.operations) != 1 {
		t.Fatalf("invalid rotation changed active state: %v", err)
	}
}

func mustOtherManagedCSR(t *testing.T) []byte {
	t.Helper()
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "other", "log-collector")
	return p.CSRs["client"].CSRDER
}

func TestManagedCertificatesInterruptedActivationRollsBack(t *testing.T) {
	for _, rollbackFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "rollback-succeeds", true: "rollback-fails"}[rollbackFails], func(t *testing.T) {
			f := newManagedCertificateFixture(t)
			p, _ := f.prepare(t, "old", "flow-collector")
			if _, err := f.store.install(context.Background(), f.issue(t, p, nil)); err != nil {
				t.Fatal(err)
			}
			now := f.store.now().Add(time.Second)
			f.store.now = func() time.Time { return now }
			p, _ = f.prepare(t, "next", "flow-collector")
			req := f.issue(t, p, nil)
			f.store.activate = func(context.Context, managedCertificateAdapter) error {
				panic("simulated process exit during activation")
			}
			func() {
				defer func() {
					if recover() == nil {
						t.Error("did not reach activation")
					}
				}()
				_, _ = f.store.install(context.Background(), req)
			}()
			calls := 0
			f.store.activate = func(_ context.Context, a managedCertificateAdapter) error {
				calls++
				if a.operation != "restart" {
					t.Fatal("collector must restart")
				}
				if calls == 1 || rollbackFails {
					return errManagedServiceFailed
				}
				return nil
			}
			result, err := f.store.install(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			target, err := os.Readlink(filepath.Join(f.store.root, "component-synthetic", "current"))
			if err != nil {
				t.Fatal(err)
			}
			if target != filepath.Join("generations", "old") || !result.Installed || result.Activated || result.ActivationError == "" || result.RolledBack == rollbackFails || (result.RollbackError != "") != rollbackFails || calls != 2 {
				t.Fatalf("rollback receipt lost prior generation: %+v target=%s calls=%d", result, target, calls)
			}
		})
	}
}

func TestManagedCertificatesRejectUnboundAssignments(t *testing.T) {
	f := newManagedCertificateFixture(t)
	base := ManagedCertificateAssignment{RequestID: "request", ComponentID: "component", HostAgentID: "agent-synthetic", PartitionID: "default", Generation: 1, Service: "trapd"}
	for name, mutate := range map[string]func(*ManagedCertificateAssignment){"other-agent": func(a *ManagedCertificateAssignment) { a.HostAgentID = "other-agent" }, "other-partition": func(a *ManagedCertificateAssignment) { a.PartitionID = "other" }, "path": func(a *ManagedCertificateAssignment) { a.ComponentID = "../escape" }, "service": func(a *ManagedCertificateAssignment) { a.Service = "arbitrary.service" }} {
		t.Run(name, func(t *testing.T) {
			a := base
			mutate(&a)
			if _, err := f.store.prepare(a); err == nil {
				t.Fatal("accepted unbound assignment")
			}
		})
	}
}

func TestManagedCertificatesServeVerifiedIntermediateChain(t *testing.T) {
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "intermediate", "trapd")
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issuer := &x509.Certificate{SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Synthetic intermediate CA"}, NotBefore: f.store.now().Add(-time.Hour), NotAfter: f.store.now().Add(48 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, issuer, f.ca, &key.PublicKey, f.key)
	if err != nil {
		t.Fatal(err)
	}
	f.ca, err = x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	f.key = key
	req := f.issue(t, p, nil)
	issued := req.Certificates["client"]
	issued.CAChainPEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	req.Certificates["client"] = issued
	result, err := f.store.install(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	paths := result.Files["client"]
	pair, err := tls.LoadX509KeyPair(paths.CertificatePath, paths.KeyPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(pair.Certificate) != 2 || !reflect.DeepEqual(pair.Certificate[1], der) {
		t.Fatal("installed certificate does not serve the verified intermediate")
	}
	root, err := os.ReadFile(paths.CAPath)
	if err != nil || string(root) != string(f.store.roots) {
		t.Fatal("response expanded the installed deployment trust roots")
	}
}

func TestManagedCertificatesLongCollectorIdentity(t *testing.T) {
	f := newManagedCertificateFixture(t)
	a := ManagedCertificateAssignment{RequestID: "long-collector", ComponentID: "collector-11111111-2222-4333-8444-555555555555", HostAgentID: "agent-synthetic", PartitionID: "default", Generation: 1, Service: "log-collector", ServerHosts: []string{"localhost", "127.0.0.1"}}
	p, err := f.store.prepare(a)
	if err != nil {
		t.Fatal(err)
	}
	csr, err := x509.ParseCertificateRequest(p.CSRs["client"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	// Independent cross-language vector: SHA-256 of the full DNS identity.
	if csr.Subject.CommonName != "972377158e25ac5f5d62010910da01e3fa7ba0a4006793d5cc501c95355b989a" {
		t.Fatalf("CSR common name exceeds the X.509 contract: %q", csr.Subject.CommonName)
	}
	req := f.issue(t, p, func(_ string, cert *x509.Certificate) {
		cert.DNSNames = []string{"collector-11111111-2222-4333-8444-555555555555.default.serviceradar", "localhost"}
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}
	})
	result, err := f.store.install(context.Background(), req)
	if err != nil || !result.Activated {
		t.Fatalf("bounded CN certificate did not activate: %v", err)
	}
	leaf := installedManagedLeaf(t, result.Files["client"])
	if err := leaf.VerifyHostname("collector-11111111-2222-4333-8444-555555555555.default.serviceradar"); err != nil {
		t.Fatal(err)
	}
}

func TestManagedCertificatesCollectorServerIdentity(t *testing.T) {
	f := newManagedCertificateFixture(t)
	a := ManagedCertificateAssignment{RequestID: "collector-server", ComponentID: "component-synthetic", HostAgentID: "agent-synthetic", PartitionID: "default", Generation: 1, Service: "trapd", ServerHosts: []string{"collector.example.test", "192.0.2.21"}}
	p, err := f.store.prepare(a)
	if err != nil {
		t.Fatal(err)
	}
	for _, usage := range []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth} {
		req := f.issue(t, p, func(_ string, cert *x509.Certificate) { cert.ExtKeyUsage = []x509.ExtKeyUsage{usage} })
		if _, err := f.store.install(context.Background(), req); err == nil {
			t.Fatalf("accepted single-purpose certificate for dual-use collector: %v", usage)
		}
	}
	if len(f.operations) != 0 {
		t.Fatal("activated collector with unusable certificate")
	}
	req := f.issue(t, p, func(_ string, cert *x509.Certificate) {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}
	})
	result, err := f.store.install(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	paths := result.Files["client"]
	pair, err := tls.LoadX509KeyPair(paths.CertificatePath, paths.KeyPath)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, host := range a.ServerHosts {
		if err := leaf.VerifyHostname(host); err != nil {
			t.Fatalf("installed collector cannot serve approved host: %v", err)
		}
	}
	if !sameSorted(leaf.DNSNames, []string{"collector.example.test", "component-synthetic.default.serviceradar"}) || len(leaf.IPAddresses) != 1 || !leaf.IPAddresses[0].Equal(net.ParseIP("192.0.2.21")) || !result.Activated {
		t.Fatal("collector installation changed approved hosts or did not activate")
	}
}

func TestManagedCertificatesAcceptExactIssuerSANs(t *testing.T) {
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "issuer-sans", managedServiceNATSLeaf)
	result, err := f.store.install(context.Background(), f.issue(t, p, nil))
	if err != nil {
		t.Fatal(err)
	}
	upstream := installedManagedLeaf(t, result.Files["upstream_client"])
	if len(upstream.URIs) != 0 || !sameSorted(upstream.DNSNames, []string{"component-synthetic.default.serviceradar"}) || len(upstream.IPAddresses) != 0 {
		t.Fatalf("upstream certificate is not the plain X509 name set: uris=%v dns=%v", certificateURIStrings(upstream.URIs), upstream.DNSNames)
	}
	server := installedManagedLeaf(t, result.Files[managedRoleLocalServer])
	if len(server.URIs) != 0 || !sameSorted(server.DNSNames, []string{"component-synthetic-server.default.serviceradar", "leaf.example.test", "localhost"}) || !sameCertificateIPs(server.IPAddresses, []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("192.0.2.10")}) {
		t.Fatalf("server certificate is not the plain X509 name set: uris=%v dns=%v ips=%v", certificateURIStrings(server.URIs), server.DNSNames, server.IPAddresses)
	}
}

func TestLocalReceiverReportsGrantedCertificateAndVerifiedServerOnly(t *testing.T) {
	clearLocalReceiverFingerprints()
	t.Cleanup(clearLocalReceiverFingerprints)
	denied := strings.Repeat("ab", 32)
	noteLocalCertificateUse("", &natsutil.CertificateAuthorization{Allowed: false, Fingerprint: denied})
	if localReceiverFingerprintHeader() != "" {
		t.Fatal("a refused client certificate was reported as observed")
	}
	server := strings.Repeat("12", 32)
	client := strings.Repeat("34", 32)
	noteLocalCertificateUse(server, &natsutil.CertificateAuthorization{Allowed: true, Fingerprint: client})
	noteLocalCertificateUse(server, &natsutil.CertificateAuthorization{Allowed: true, Fingerprint: "not-a-fingerprint"})
	if localReceiverFingerprintHeader() != server+","+client {
		t.Fatalf("receiver report = %s", localReceiverFingerprintHeader())
	}
	ackLocalReceiverFingerprints(client)
	if localReceiverFingerprintHeader() != server {
		t.Fatalf("acknowledged client still pending: %s", localReceiverFingerprintHeader())
	}
}

func TestManagedCertificatesRejectIssuerSANOutsideExtfile(t *testing.T) {
	cases := []struct {
		name    string
		service string
		hosts   []string
		role    string
		edit    func(*x509.Certificate)
	}{
		{name: "extra-uri", service: managedServiceNATSLeaf, role: "upstream_client", edit: func(c *x509.Certificate) {
			extra, _ := url.Parse("spiffe://serviceradar.local/other/default")
			c.URIs = append(c.URIs, extra)
		}},
		{name: "hub-uri-on-server", service: managedServiceNATSLeaf, role: managedRoleLocalServer, edit: func(c *x509.Certificate) {
			extra, _ := url.Parse("spiffe://serviceradar.local/nats-leaf/default")
			c.URIs = append(c.URIs, extra)
		}},
		{name: "missing-cn", service: managedServiceNATSLeaf, role: managedRoleLocalServer, edit: func(c *x509.Certificate) {
			c.DNSNames = []string{"localhost", "leaf.example.test"}
		}},
		{name: "extra-dns", service: "trapd", hosts: []string{"collector.example.test"}, role: "client", edit: func(c *x509.Certificate) {
			c.DNSNames = append(c.DNSNames, "extra.example.test")
		}},
		{name: "extra-ip", service: "trapd", hosts: []string{"192.0.2.21"}, role: "client", edit: func(c *x509.Certificate) {
			c.IPAddresses = append(c.IPAddresses, net.ParseIP("192.0.2.99"))
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newManagedCertificateFixture(t)
			hosts := tc.hosts
			if tc.service == managedServiceNATSLeaf {
				hosts = []string{"leaf.example.test", "192.0.2.10"}
			}
			a := ManagedCertificateAssignment{RequestID: "issuer-san", ComponentID: "component-synthetic", HostAgentID: "agent-synthetic", PartitionID: "default", Generation: 1, Service: tc.service, ServerHosts: hosts}
			p, err := f.store.prepare(a)
			if err != nil {
				t.Fatal(err)
			}
			_, err = f.store.install(context.Background(), f.issue(t, p, func(role string, cert *x509.Certificate) {
				if role == tc.role {
					tc.edit(cert)
				}
			}))
			if err == nil || (!strings.Contains(err.Error(), "identity differs") && !strings.Contains(err.Error(), "hosts differ")) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func applyPlainIssuerNames(csr *x509.CertificateRequest, cert *x509.Certificate) {
	cert.URIs = nil
	cert.DNSNames = append([]string{csr.Subject.CommonName}, csr.DNSNames...)
	cert.IPAddresses = append([]net.IP(nil), csr.IPAddresses...)
}

func installedManagedLeaf(t *testing.T, files ManagedCertificateFiles) *x509.Certificate {
	t.Helper()
	pair, err := tls.LoadX509KeyPair(files.CertificatePath, files.KeyPath)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	return leaf
}

func certificateURIStrings(uris []*url.URL) []string {
	out := make([]string, len(uris))
	for i, uri := range uris {
		out[i] = uri.String()
	}
	return out
}

func sameSorted(actual, expected []string) bool {
	return slices.Equal(slices.Sorted(slices.Values(actual)), slices.Sorted(slices.Values(expected)))
}

func TestManagedCertificatesInstallBMPIdentity(t *testing.T) {
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "bmp-request", "bmp-collector")
	csr, err := x509.ParseCertificateRequest(p.CSRs["client"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	if len(csr.URIs) != 0 || csr.Subject.CommonName != "component-synthetic.default.serviceradar" {
		t.Fatal("BMP certificate has the wrong service identity")
	}
	result, err := f.store.install(context.Background(), f.issue(t, p, nil))
	if err != nil {
		t.Fatal(err)
	}
	if !result.Activated || len(f.operations) != 1 || f.operations[0].unit != "serviceradar-bmp-collector.service" || f.operations[0].operation != "restart" || f.operations[0].owner != "serviceradar" {
		t.Fatalf("BMP activation did not use its packaged service: %+v", f.operations)
	}
}

// This owns the persisted privileged authority boundary; the real-broker suite
// owns grants, permissions, offline ingestion and expiry of active connections.
func TestManagedLocalNATSBootstrapPreservesAuthority(t *testing.T) {
	if os.Getuid() != 0 {
		t.Fatal("privileged bootstrap test requires the root RBE execution image")
	}
	f := newManagedCertificateFixture(t)
	binding := managedLocalNATSBinding{ComponentID: "leaf-synthetic", HostAgentID: f.store.agentID, PartitionID: f.store.partition}
	bindingDir := filepath.Join(f.store.root, ".bindings")
	if err := os.Mkdir(bindingDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bindingDir, "nats-leaf.json"), []byte(`{"component_id":"leaf-synthetic","host_agent_id":"agent-synthetic"}`), 0600); err != nil {
		t.Fatal(err)
	}
	previousUmask := syscall.Umask(0077)
	defer syscall.Umask(previousUmask)
	first, err := f.store.bootstrapLocalNATS(binding)
	if err != nil {
		t.Fatal(err)
	}
	for path, mode := range map[string]os.FileMode{
		".nats-auth": 0700, ".nats-auth/issuer.seed": 0600,
		"local-nats-auth.seed": 0640, "local-nats.json": 0644,
		"leaf-synthetic/local-auth.conf": 0640,
	} {
		info, err := os.Stat(filepath.Join(f.store.root, path))
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("wrong persisted authority permissions for %s: %v", path, err)
		}
	}
	again, err := f.store.bootstrapLocalNATS(binding)
	if err != nil || !reflect.DeepEqual(first, again) {
		t.Fatalf("bootstrap retry changed local authority: %v", err)
	}
	other := binding
	other.ComponentID = "another-leaf"
	if _, err := f.store.bootstrapLocalNATS(other); err == nil {
		t.Fatal("a second component replaced the fixed broker authority")
	}
	issuerPath := filepath.Join(f.store.root, ".nats-auth", "issuer.seed")
	if err := os.Remove(issuerPath); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.bootstrapLocalNATS(binding); err == nil {
		t.Fatal("bootstrap silently replaced a missing established signing key")
	}
	if _, err := os.Stat(issuerPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed bootstrap recreated an established signing key")
	}
}
