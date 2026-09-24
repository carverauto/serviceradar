/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package chartacl exercises the NATS server configuration the Helm chart
// renders, by booting a real nats-server from it.
package chartacl

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io/fs"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"gopkg.in/yaml.v3"
)

const (
	chartYAMLEnv = "SERVICERADAR_CHART_YAML"
	unttEnv      = "SERVICERADAR_HELM_UNITTEST_BINARY"

	coreSubject  = "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
	toolsSubject = "CN=serviceradar-tools,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"

	renderSuite = `suite: render nats server config
templates:
  - templates/nats.yaml
tests:
  - it: server-config
    set:
      nats:
        replicas: 1
    documentSelector:
      path: kind
      value: StatefulSet
    asserts:
      - matchSnapshot:
          path: spec.template.spec.containers[0].args[0]
`

	confStart = "cat >/tmp/nats-server.conf <<EOF\n"
	confEnd   = "\nEOF\n"
)

// TestCoreCanPublishToChartSubjects boots nats-server from the configuration
// the chart renders and checks what the core identity may publish. Publishing
// with a plain NATS publish reports success even when the server denies it, so
// the assertions observe delivery to an independent subscriber and the
// permission violation the server reports back.
func TestCoreCanPublishToChartSubjects(t *testing.T) {
	pki := newTestPKI(t)
	conf := renderServerConf(t, pki)

	opts, err := server.ProcessConfigFile(conf)
	if err != nil {
		t.Fatalf("process rendered config: %v", err)
	}

	opts.Host = "127.0.0.1"
	opts.Port = -1
	opts.HTTPHost = ""
	opts.HTTPPort = 0
	opts.Debug = false
	opts.Trace = false
	opts.NoLog = true
	opts.NoSigs = true

	srv, err := server.NewServer(opts)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	go srv.Start()
	t.Cleanup(srv.Shutdown)

	if !srv.ReadyForConnections(10 * time.Second) {
		t.Fatal("nats-server built from the chart config did not become ready")
	}

	tools := pki.connect(t, srv, toolsSubject, nil)
	core, coreErrs := pki.connectTracked(t, srv, coreSubject)

	const (
		allowedScan  = "scans.results.run01"
		allowedEvent = "events.example"
		denied       = "zz.not.allowed"
	)

	received := make(map[string]chan struct{})
	for _, subject := range []string{allowedScan, allowedEvent, denied} {
		ch := make(chan struct{}, 1)
		received[subject] = ch

		if _, err := tools.Subscribe(subject, func(*nats.Msg) { ch <- struct{}{} }); err != nil {
			t.Fatalf("subscribe %s: %v", subject, err)
		}
	}

	if err := tools.Flush(); err != nil {
		t.Fatalf("flush subscriptions: %v", err)
	}

	for _, subject := range []string{allowedScan, allowedEvent, denied} {
		if err := core.Publish(subject, []byte(`{"synthetic":true}`)); err != nil {
			t.Fatalf("publish %s: %v", subject, err)
		}
	}

	if err := core.Flush(); err != nil {
		t.Fatalf("flush core: %v", err)
	}

	// The server answers publishes on one connection in order, so once the
	// violation for the last subject has arrived every earlier verdict has too.
	if !coreErrs.waitFor(denied, 5*time.Second) {
		t.Fatalf("expected a permissions violation for %s, got %v", denied, coreErrs.all())
	}

	for _, subject := range []string{allowedScan, allowedEvent} {
		select {
		case <-received[subject]:
		case <-time.After(5 * time.Second):
			t.Errorf("core publish to %s was not delivered; violations: %v", subject, coreErrs.all())
		}

		if coreErrs.has(subject) {
			t.Errorf("server denied core publish to %s: %v", subject, coreErrs.all())
		}
	}

	select {
	case <-received[denied]:
		t.Errorf("core publish to %s was delivered but is not in core's allow list", denied)
	default:
	}
}

func runfile(t *testing.T, envVar string) string {
	t.Helper()

	rlocation := os.Getenv(envVar)
	if rlocation == "" {
		t.Fatalf("%s must be set to a runfile location by the Bazel target", envVar)
	}

	path, err := runfiles.Rlocation(rlocation)
	if err != nil {
		t.Fatalf("resolve %s=%s: %v", envVar, rlocation, err)
	}

	return path
}

func renderServerConf(t *testing.T, pki *testPKI) string {
	t.Helper()

	chartYAML := runfile(t, chartYAMLEnv)
	untt := runfile(t, unttEnv)

	work := t.TempDir()
	chartDir := filepath.Join(work, "chart")
	copyChart(t, filepath.Dir(chartYAML), chartDir)

	suitePath := filepath.Join(chartDir, "tests", "render_test.yaml")
	writeFile(t, suitePath, []byte(renderSuite), 0o644)

	cmd := exec.CommandContext(t.Context(), untt, "--update-snapshot", chartDir)
	cmd.Env = append(os.Environ(), "HOME="+work)

	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("render chart with helm-unittest: %v\n%s", err, out)
	}

	snapshot, err := os.ReadFile(filepath.Join(chartDir, "tests", "__snapshot__", "render_test.yaml.snap"))
	if err != nil {
		t.Fatalf("read rendered snapshot: %v", err)
	}

	script := decodeSnapshot(t, snapshot)

	start := strings.Index(script, confStart)
	if start < 0 {
		t.Fatalf("rendered StatefulSet has no nats-server.conf heredoc:\n%s", script)
	}

	body := script[start+len(confStart):]

	end := strings.Index(body, confEnd)
	if end < 0 {
		t.Fatalf("nats-server.conf heredoc is unterminated:\n%s", script)
	}

	// The heredoc is unquoted, so the pod's shell would resolve these before
	// nats-server reads the file.
	conf := strings.NewReplacer(
		`\$`, `$`,
		"${POD_NAME}", "nats-0",
		"/etc/serviceradar/certs", pki.dir,
		"/data/jetstream", filepath.Join(work, "jetstream"),
	).Replace(body[:end])

	confPath := filepath.Join(work, "nats-server.conf")
	writeFile(t, confPath, []byte(conf), 0o600)

	return confPath
}

// decodeSnapshot unwraps helm-unittest's snapshot file: a YAML map of test name
// to numbered snapshots, each holding the asserted value serialised as YAML.
func decodeSnapshot(t *testing.T, raw []byte) string {
	t.Helper()

	var tests map[string]map[string]string
	if err := yaml.Unmarshal(raw, &tests); err != nil {
		t.Fatalf("parse snapshot file: %v", err)
	}

	snapshots := tests["server-config"]
	if len(snapshots) != 1 {
		t.Fatalf("expected exactly one server-config snapshot, got %v", tests)
	}

	for _, serialised := range snapshots {
		var script string
		if err := yaml.Unmarshal([]byte(serialised), &script); err != nil {
			t.Fatalf("parse snapshot value: %v", err)
		}

		return script
	}

	return ""
}

func copyChart(t *testing.T, src, dst string) {
	t.Helper()

	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}

		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}

		if rel == "tests" {
			return filepath.SkipDir
		}

		target := filepath.Join(dst, rel)

		info, err := os.Stat(path)
		if err != nil {
			return err
		}

		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}

		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		t.Fatalf("copy chart: %v", err)
	}

	if err := os.MkdirAll(filepath.Join(dst, "tests"), 0o755); err != nil {
		t.Fatalf("create tests dir: %v", err)
	}
}

func writeFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()

	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

type violations struct {
	mu   sync.Mutex
	errs []string
	wake chan struct{}
}

func (v *violations) record(err error) {
	v.mu.Lock()
	v.errs = append(v.errs, err.Error())
	v.mu.Unlock()

	select {
	case v.wake <- struct{}{}:
	default:
	}
}

func (v *violations) has(subject string) bool {
	v.mu.Lock()
	defer v.mu.Unlock()

	for _, e := range v.errs {
		if strings.Contains(e, `"`+subject+`"`) {
			return true
		}
	}

	return false
}

func (v *violations) all() []string {
	v.mu.Lock()
	defer v.mu.Unlock()

	return append([]string(nil), v.errs...)
}

func (v *violations) waitFor(subject string, within time.Duration) bool {
	deadline := time.After(within)

	for {
		if v.has(subject) {
			return true
		}

		select {
		case <-v.wake:
		case <-deadline:
			return v.has(subject)
		}
	}
}

// testPKI is a throwaway CA that issues the server certificate and the client
// certificates the chart's verify_and_map users are keyed on.
type testPKI struct {
	dir  string
	ca   *x509.Certificate
	key  *ecdsa.PrivateKey
	pool *x509.CertPool
	next int64
}

func newTestPKI(t *testing.T) *testPKI {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}

	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Synthetic Test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA: %v", err)
	}

	ca, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA: %v", err)
	}

	p := &testPKI{dir: t.TempDir(), ca: ca, key: key, pool: x509.NewCertPool(), next: 1}
	p.pool.AddCert(ca)

	writeFile(t, filepath.Join(p.dir, "root.pem"), pemBlock("CERTIFICATE", der), 0o644)

	serverCert, serverKey := p.issue(t, pkix.Name{CommonName: "nats"}, x509.ExtKeyUsageServerAuth)
	writeFile(t, filepath.Join(p.dir, "nats.pem"), pemBlock("CERTIFICATE", serverCert.Certificate[0]), 0o644)
	writeFile(t, filepath.Join(p.dir, "nats-key.pem"), serverKey, 0o600)

	return p
}

func (p *testPKI) issue(t *testing.T, subject pkix.Name, usage x509.ExtKeyUsage) (tls.Certificate, []byte) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	p.next++

	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(p.next),
		Subject:      subject,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{usage},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames:     []string{"localhost"},
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, p.ca, &key.PublicKey, p.key)
	if err != nil {
		t.Fatalf("issue certificate: %v", err)
	}

	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}

	keyPEM := pemBlock("EC PRIVATE KEY", keyDER)

	cert, err := tls.X509KeyPair(pemBlock("CERTIFICATE", der), keyPEM)
	if err != nil {
		t.Fatalf("load key pair: %v", err)
	}

	return cert, keyPEM
}

// clientSubject parses the RFC 2253 style subject the chart uses as a user name
// into the pkix.Name a certificate must carry to be mapped to that user.
func clientSubject(t *testing.T, dn string) pkix.Name {
	t.Helper()

	var name pkix.Name

	for _, part := range strings.Split(dn, ",") {
		key, value, ok := strings.Cut(part, "=")
		if !ok {
			t.Fatalf("malformed subject %q", dn)
		}

		switch key {
		case "CN":
			name.CommonName = value
		case "OU":
			name.OrganizationalUnit = []string{value}
		case "O":
			name.Organization = []string{value}
		case "L":
			name.Locality = []string{value}
		case "ST":
			name.Province = []string{value}
		case "C":
			name.Country = []string{value}
		default:
			t.Fatalf("unsupported subject attribute %q in %q", key, dn)
		}
	}

	return name
}

func (p *testPKI) connect(t *testing.T, srv *server.Server, dn string, extra []nats.Option) *nats.Conn {
	t.Helper()

	cert, _ := p.issue(t, clientSubject(t, dn), x509.ExtKeyUsageClientAuth)

	opts := append([]nats.Option{
		nats.Secure(&tls.Config{
			Certificates: []tls.Certificate{cert},
			RootCAs:      p.pool,
			MinVersion:   tls.VersionTLS12,
		}),
		nats.Timeout(10 * time.Second),
	}, extra...)

	nc, err := nats.Connect(srv.ClientURL(), opts...)
	if err != nil {
		t.Fatalf("connect as %s: %v", dn, err)
	}

	t.Cleanup(nc.Close)

	return nc
}

func (p *testPKI) connectTracked(t *testing.T, srv *server.Server, dn string) (*nats.Conn, *violations) {
	t.Helper()

	v := &violations{wake: make(chan struct{}, 1)}

	nc := p.connect(t, srv, dn, []nats.Option{
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) { v.record(err) }),
	})

	return nc, v
}

func pemBlock(kind string, der []byte) []byte {
	var buf bytes.Buffer

	_ = pem.Encode(&buf, &pem.Block{Type: kind, Bytes: der})

	return buf.Bytes()
}
