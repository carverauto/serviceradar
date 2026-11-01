//go:build linux

package agent

import (
	"bytes"
	"encoding/pem"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestPackagedHostTrustRejectsRuntimeIdentityAndKeepsRenewalWritable(t *testing.T) {
	if _, err := parseHostTrustIdentity([]byte(`{"agent_id":"trust-agent","partition":"edge-a","host_ip":"203.0.113.9"}`)); err == nil {
		t.Fatal("host trust accepted a runtime agent.json document")
	}
	root := t.TempDir()
	certDir := filepath.Join(root, "certs")
	if err := os.Mkdir(certDir, 0o750); err != nil {
		t.Fatal(err)
	}
	runtime := []byte(`{"agent_id":"runtime-agent","partition":"runtime-partition","host_ip":"203.0.113.9"}`)
	for name, body := range map[string][]byte{
		filepath.Join(root, "agent.json"):           runtime,
		filepath.Join(certDir, "ca-chain.pem"):      []byte("runtime-ca"),
		filepath.Join(certDir, "root.pem"):          []byte("runtime-root"),
		filepath.Join(certDir, "component.pem"):     []byte("original-cert"),
		filepath.Join(certDir, "component-key.pem"): []byte("original-key"),
	} {
		if err := os.WriteFile(name, body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte("synthetic-deployment-ca")})
	trustDir := filepath.Join(root, "host-trust")
	if err := os.Mkdir(trustDir, 0o755); err != nil {
		t.Fatal(err)
	}
	identity := []byte(`{"agent_id":"trust-agent","partition":"edge-a"}`)
	if err := os.WriteFile(filepath.Join(trustDir, "identity.json"), identity, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trustDir, "ca.pem"), ca, 0o644); err != nil {
		t.Fatal(err)
	}

	renew := func() {
		t.Helper()
		certPath := filepath.Join(certDir, "component.pem")
		keyPath := filepath.Join(certDir, "component-key.pem")
		if err := WriteRenewedCertificateAtomically(certPath, keyPath, []byte("runtime-ca"), []byte("renewed-cert"), []byte("renewed-key"), CertRenewalWriteHooks{}); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(certPath)
		if err != nil || !bytes.Equal(got, []byte("renewed-cert")) {
			t.Fatalf("renewed certificate = %q, err %v", got, err)
		}
		kept, err := os.ReadFile(filepath.Join(trustDir, "ca.pem"))
		if err != nil || !bytes.Equal(kept, ca) {
			t.Fatalf("renewal rewrote host trust CA: %q %v", kept, err)
		}
	}

	if os.Getuid() != 0 {
		if _, _, err := loadManagedHostTrust(root); err == nil {
			t.Fatal("caller-owned host trust was accepted")
		}
		renew()
		t.Fatalf("host-trust root acceptance requires uid 0; got uid=%d euid=%d", os.Getuid(), os.Geteuid())
	}
	t.Logf("host-trust root acceptance running as uid=%d euid=%d", os.Getuid(), os.Geteuid())

	for _, path := range []string{filepath.Join(root, "agent.json"), certDir, filepath.Join(certDir, "ca-chain.pem"), filepath.Join(certDir, "root.pem"), filepath.Join(certDir, "component.pem"), filepath.Join(certDir, "component-key.pem")} {
		if err := os.Chown(path, 65534, 65534); err != nil {
			t.Fatal(err)
		}
	}
	binding, roots, err := loadManagedHostTrust(root)
	if err != nil {
		t.Fatal(err)
	}
	if binding.AgentID != "trust-agent" || binding.Partition != "edge-a" || !bytes.Equal(roots, ca) {
		t.Fatalf("trusted host = %s/%s ca %q", binding.AgentID, binding.Partition, roots)
	}

	if err := os.RemoveAll(trustDir); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadManagedHostTrust(root); err == nil {
		t.Fatal("service-owned agent.json and certs/root.pem were accepted as host trust")
	}
	if err := os.Mkdir(trustDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trustDir, "identity.json"), identity, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(trustDir, "ca.pem"), ca, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(filepath.Join(trustDir, "identity.json"), 65534, 65534); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadManagedHostTrust(root); err == nil {
		t.Fatal("service-owned host identity was accepted")
	}
	if err := os.Chown(filepath.Join(trustDir, "identity.json"), 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(trustDir, "ca.pem"), 0o666); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadManagedHostTrust(root); err == nil {
		t.Fatal("group-writable deployment CA was accepted")
	}
	if err := os.Chmod(filepath.Join(trustDir, "ca.pem"), 0o644); err != nil {
		t.Fatal(err)
	}

	renew()
	if uid := fileUID(t, certDir); uid != 65534 {
		t.Fatalf("certificate directory uid = %d, want the service owner", uid)
	}
}

func fileUID(t *testing.T, path string) int {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("stat has no unix owner")
	}
	return int(stat.Uid)
}
