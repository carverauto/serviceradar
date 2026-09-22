package agent

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// Mirrors the shape a Proxmox VE node presents: a certificate issued by the
// cluster's own CA, carrying the node address as an IP SAN because
// ProxmoxHostAuthority.canonical_origin/3 forces an IP-literal origin.
func newPrivateCAAndLeaf(t *testing.T, ip net.IP) (caPEM string, leaf tls.Certificate) {
	t.Helper()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test Cluster Manager CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create CA: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse CA: %v", err)
	}

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate leaf key: %v", err)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "pve-test.localdomain"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{ip},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("create leaf: %v", err)
	}

	caPEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}))

	return caPEM, tls.Certificate{
		Certificate: [][]byte{leafDER, caDER},
		PrivateKey:  leafKey,
	}
}

// The demo failure this closes: a Proxmox rule must keep tls_policy verify
// (skip_verify is rejected at source-scope resolution AND by
// validatePluginHostAuthorityBinding), so the only way to reach a node behind
// the cluster CA is to pin that CA on the rule.
func TestPinnedRootsVerifyAPrivateCAByIPAndRejectOthers(t *testing.T) {
	loopback := net.ParseIP("127.0.0.1")
	caPEM, leaf := newPrivateCAAndLeaf(t, loopback)

	server := httptest.NewUnstartedServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}),
	)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{leaf}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	defer server.Close()

	// httptest hands back a client trusting its own cert; use a plain one so the
	// only trust in play is what the binding supplies.
	base := &http.Client{Transport: http.DefaultTransport}

	get := func(t *testing.T, client *http.Client) (int, error) {
		t.Helper()

		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
		if err != nil {
			t.Fatalf("build request: %v", err)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Logf("HTTPS request rejected: %v", err)
			return 0, err
		}
		defer func() { _ = resp.Body.Close() }()

		t.Logf("HTTPS response: %s", resp.Status)
		return resp.StatusCode, nil
	}

	t.Run("system roots alone cannot reach it", func(t *testing.T) {
		client := pluginHTTPClient(base, false, 5*time.Second)
		if _, err := get(t, client); err == nil {
			t.Fatal("expected verification to fail against the system trust store")
		}
	})

	t.Run("the pinned cluster CA reaches it", func(t *testing.T) {
		client := pluginHTTPClientWithPinnedRoots(pluginHTTPClient(base, false, 5*time.Second), caPEM)
		status, err := get(t, client)
		if err != nil {
			t.Fatalf("pinned CA should verify the node certificate: %v", err)
		}
		if status != http.StatusOK {
			t.Fatalf("status = %d, want 200", status)
		}
	})

	t.Run("an unrelated CA does not", func(t *testing.T) {
		otherPEM, _ := newPrivateCAAndLeaf(t, loopback)
		client := pluginHTTPClientWithPinnedRoots(
			pluginHTTPClient(base, false, 5*time.Second),
			otherPEM,
		)
		if _, err := get(t, client); err == nil {
			t.Fatal("pinning an unrelated CA must not verify this server")
		}
	})
}

func TestValidPluginHostAuthorityCABundle(t *testing.T) {
	t.Parallel()

	caPEM, _ := newPrivateCAAndLeaf(t, net.ParseIP("192.0.2.10"))

	tests := []struct {
		name   string
		bundle string
		want   bool
	}{
		{name: "absent is allowed", bundle: "", want: true},
		{name: "a real certificate", bundle: caPEM, want: true},
		{name: "not PEM at all", bundle: "definitely not a certificate", want: false},
		{
			name:   "a PEM block that is not a certificate",
			bundle: "-----BEGIN CERTIFICATE REQUEST-----\nMIHnMIGdAgEAMCs=\n-----END CERTIFICATE REQUEST-----\n",
			want:   false,
		},
		{
			name:   "oversized",
			bundle: caPEM + string(make([]byte, maxPluginHostAuthorityCABundleBytes)),
			want:   false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := validPluginHostAuthorityCABundle(tc.bundle); got != tc.want {
				t.Fatalf("validPluginHostAuthorityCABundle() = %v, want %v", got, tc.want)
			}
		})
	}
}

func leafFingerprint(t *testing.T, leaf tls.Certificate) string {
	t.Helper()
	if len(leaf.Certificate) == 0 {
		t.Fatal("leaf has no certificate")
	}
	sum := sha256.Sum256(leaf.Certificate[0])
	return "sha256:" + hex.EncodeToString(sum[:])
}

func TestPinnedFingerprintVerifiesMatchingLeafAndRejectsOthers(t *testing.T) {
	loopback := net.ParseIP("127.0.0.1")
	_, leaf := newPrivateCAAndLeaf(t, loopback)
	_, otherLeaf := newPrivateCAAndLeaf(t, loopback)

	server := httptest.NewUnstartedServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}),
	)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{leaf}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	defer server.Close()

	base := &http.Client{Transport: http.DefaultTransport}
	get := func(t *testing.T, client *http.Client) error {
		t.Helper()
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
		if err != nil {
			t.Fatalf("build request: %v", err)
		}
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		return nil
	}

	t.Run("the pinned leaf fingerprint reaches it", func(t *testing.T) {
		client := pluginHTTPClientWithPinnedFingerprint(
			pluginHTTPClient(base, false, 5*time.Second),
			leafFingerprint(t, leaf),
		)
		if err := get(t, client); err != nil {
			t.Fatalf("pinned fingerprint should verify the node certificate: %v", err)
		}
	})

	t.Run("an unrelated fingerprint does not", func(t *testing.T) {
		client := pluginHTTPClientWithPinnedFingerprint(
			pluginHTTPClient(base, false, 5*time.Second),
			leafFingerprint(t, otherLeaf),
		)
		if err := get(t, client); err == nil {
			t.Fatal("pinning an unrelated fingerprint must not verify this server")
		}
	})
}

func TestValidPluginHostAuthorityFingerprint(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		fingerprint string
		want        bool
	}{
		{name: "absent is allowed", fingerprint: "", want: true},
		{name: "sha256 lowercase hex", fingerprint: "sha256:" + hex.EncodeToString(make([]byte, 32)), want: true},
		{name: "missing prefix", fingerprint: hex.EncodeToString(make([]byte, 32)), want: false},
		{name: "uppercase hex", fingerprint: "sha256:" + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", want: false},
		{name: "too short", fingerprint: "sha256:abcd", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := validPluginHostAuthorityFingerprint(tc.fingerprint); got != tc.want {
				t.Fatalf("validPluginHostAuthorityFingerprint() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPluginHostAuthorityAcceptsFingerprintAlone(t *testing.T) {
	t.Parallel()

	_, leaf := newPrivateCAAndLeaf(t, net.ParseIP("192.0.2.10"))
	opts := testInventoryAuthorityOptions()
	opts.serverCertFingerprint = leafFingerprint(t, leaf)

	assignment := newTestProxmoxHostAuthorityAssignment(t, opts)
	bindings, _ := assignment.pluginHostAuthoritySnapshot()
	if len(bindings) != 1 {
		t.Fatalf("host bindings = %d, want 1", len(bindings))
	}
	if bindings[0].serverCertFingerprint != opts.serverCertFingerprint {
		t.Fatalf("fingerprint = %q, want %q", bindings[0].serverCertFingerprint, opts.serverCertFingerprint)
	}
}

func TestPluginHostAuthorityRejectsCABundleAndFingerprintTogether(t *testing.T) {
	t.Parallel()

	caPEM, leaf := newPrivateCAAndLeaf(t, net.ParseIP("192.0.2.10"))
	opts := testInventoryAuthorityOptions()
	opts.caBundlePEM = caPEM
	opts.serverCertFingerprint = leafFingerprint(t, leaf)

	assignment := newTestProxmoxHostAuthorityAssignment(t, opts)
	bindings, _ := assignment.pluginHostAuthoritySnapshot()
	if len(bindings) != 0 {
		t.Fatalf("host bindings = %d, want 0 when both trust-material forms are set", len(bindings))
	}
}

// pluginHTTPClientForBinding runs once per plugin HTTP request, so a pinning
// path that rebuilds its transport hands every request an empty connection
// pool: a full handshake each time, plus an idle connection stranded in each
// discarded transport until IdleConnTimeout.
func TestPinnedBindingReusesOneConnectionAcrossRequests(t *testing.T) {
	loopback := net.ParseIP("127.0.0.1")
	caPEM, leaf := newPrivateCAAndLeaf(t, loopback)

	for _, tc := range []struct {
		name    string
		binding *pluginHostAuthorityBinding
	}{
		{
			name:    "pinned CA bundle",
			binding: &pluginHostAuthorityBinding{caBundlePEM: caPEM},
		},
		{
			name:    "pinned leaf fingerprint",
			binding: &pluginHostAuthorityBinding{serverCertFingerprint: leafFingerprint(t, leaf)},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var handshakes atomic.Int64

			server := httptest.NewUnstartedServer(
				http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
					w.WriteHeader(http.StatusOK)
				}),
			)
			server.TLS = &tls.Config{
				Certificates: []tls.Certificate{leaf},
				MinVersion:   tls.VersionTLS12,
				GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
					handshakes.Add(1)
					return nil, nil
				},
			}
			server.StartTLS()
			defer server.Close()

			// A base transport of this test's own so the shared pinned-transport
			// cache is keyed away from every other test in the package.
			base := &http.Client{Transport: &http.Transport{}}

			for range 3 {
				client := pluginHTTPClientForBinding(base, false, 5*time.Second, tc.binding)

				req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
				if err != nil {
					t.Fatalf("build request: %v", err)
				}
				resp, err := client.Do(req)
				if err != nil {
					t.Fatalf("pinned request: %v", err)
				}
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
			}

			if got := handshakes.Load(); got != 1 {
				t.Fatalf("TLS handshakes = %d, want 1: the binding must keep one connection pool across requests", got)
			}
		})
	}
}
