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
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"
)

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
	if service == "nats-leaf" {
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
		if role == "local_server" {
			usage = x509.ExtKeyUsageServerAuth
		}
		cert := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: csr.Subject, URIs: csr.URIs, DNSNames: csr.DNSNames, IPAddresses: csr.IPAddresses, NotBefore: f.store.now().Add(-time.Minute), NotAfter: f.store.now().Add(24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}}
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
	p, a := f.prepare(t, "prepare-1", "nats-leaf")
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
	client, err := x509.ParseCertificateRequest(p.CSRs["upstream_client"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	server, err := x509.ParseCertificateRequest(p.CSRs["local_server"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	if reflect.DeepEqual(client.RawSubjectPublicKeyInfo, server.RawSubjectPublicKeyInfo) {
		t.Fatal("leaf roles reused private key")
	}
	if client.URIs[0].String() != "spiffe://serviceradar.local/nats_leaf/default/component-synthetic" || server.URIs[0].String() != "spiffe://serviceradar.local/nats_leaf_server/default/component-synthetic-server" {
		t.Fatal("wrong certificate identities")
	}
	if !reflect.DeepEqual(server.DNSNames, []string{"localhost", "leaf.example.test"}) || !server.IPAddresses[1].Equal(net.ParseIP("192.0.2.10")) {
		t.Fatal("missing requested server identities")
	}
	req := f.issue(t, p, nil)
	result, err := restarted.install(context.Background(), req)
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
	retry, err := restarted.install(context.Background(), req)
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
					return errors.New("service failed")
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

func TestManagedCertificatesInstallBMPIdentity(t *testing.T) {
	f := newManagedCertificateFixture(t)
	p, _ := f.prepare(t, "bmp-request", "bmp-collector")
	csr, err := x509.ParseCertificateRequest(p.CSRs["client"].CSRDER)
	if err != nil {
		t.Fatal(err)
	}
	if csr.URIs[0].String() != "spiffe://serviceradar.local/bmp_collector/default/component-synthetic" {
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
