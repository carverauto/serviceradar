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
	"slices"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"
	"gopkg.in/yaml.v3"
)

const (
	chartYAMLEnv = "SERVICERADAR_CHART_YAML"
	unttEnv      = "SERVICERADAR_HELM_UNITTEST_BINARY"

	coreSubject  = "CN=serviceradar-core,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
	toolsSubject = "CN=serviceradar-tools,OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"

	// The account the chart binds its built-in users to; a callout grant names it.
	chartAccount = "SERVICERADAR"

	confStart = "cat >/tmp/nats-server.conf <<EOF\n"
	confEnd   = "\nEOF\n"
)

// Subjects core publishes, the edge-record projectors' republish targets among
// them (MetricsBatchProjection's metrics.<family>.<type>.<name>, so a sweep
// summary is metrics.sweep.sweep.<name>; TelemetryBatch; OtlpRelay; the
// edge-record dead letter).
var coreAllowedSubjects = []string{
	"scans.results.run01",
	"mtr.results.ingest",
	"events.example",
	"metrics.event_writer.warehouse",
	"metrics.sysmon.sysmon_cpu.cpu_usage_percent",
	"metrics.snmp.snmp.ifinoctets",
	"metrics.icmp.icmp.response_time_ms",
	"metrics.rperf.throughput.bits_per_second",
	"metrics.mtr.mtr.hop_loss_pct",
	"metrics.sweep.sweep.sweep_total_hosts",
	"metrics.timeseries.custom.synthetic_value",
	"flows.attribution.observations",
	"otel.traces.raw",
	"logs.otel",
	"otel.metrics.raw",
	"otel.metrics.derived",
	"telemetry.edge-record-dlq.v1.bulk.synthetic",
	"vulnerability.assessment.transitions.7",
	"metrics.exposure_transitions",
	"exposure.delivery.recovery.3.synthetic-operation",
	"exposure.snapshots.1.device-3.1",
}

var coreDeniedSubjects = []string{
	"$JS.API.STREAM.PURGE.EXPOSURE_RECOVERY",
	"$JS.API.STREAM.DELETE.EXPOSURE_RECOVERY",
	"$JS.API.STREAM.PURGE.TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
	"zz.not.allowed",
}

// TestCoreCanPublishToChartSubjects boots nats-server from the configuration
// the chart renders and checks what the core identity may publish through the
// static verify_and_map users.
func TestCoreCanPublishToChartSubjects(t *testing.T) {
	pki := newTestPKI(t)
	rendered := renderChart(t, pki, nil)
	srv := startServer(t, rendered.conf)

	assertCorePublishes(t, srv, pki)
}

// TestCalloutGrantsMatchStaticUsers enables certificate authorization, so the
// broker delegates every built-in identity to the callout. The responder grants
// each certificate the block the chart's serviceradar-nats-static-users
// ConfigMap lists for its subject, which is what core's authorizer grants an
// adopted infrastructure certificate (ServiceRadar.NATS.StaticIdentityGrants).
// That list must be the broker's static user configuration exactly, and core's
// projector subjects must still be delivered.
func TestCalloutGrantsMatchStaticUsers(t *testing.T) {
	pki := newTestPKI(t)
	issuer := newKey(t, nkeys.CreateAccount)
	authUser := newKey(t, nkeys.CreateUser)
	systemUser := newKey(t, nkeys.CreateUser)

	rendered := renderChart(t, pki, map[string]any{
		"certificateAuthorization": map[string]any{
			"enabled":               true,
			"infrastructureAdopted": true,
			"issuerPublicKey":       publicKey(t, issuer),
			"authUserPublicKey":     publicKey(t, authUser),
			"systemUserPublicKey":   publicKey(t, systemUser),
		},
	})

	opts, err := server.ProcessConfigFile(rendered.conf)
	if err != nil {
		t.Fatalf("process rendered config: %v", err)
	}

	if opts.AuthCallout == nil {
		t.Fatal("rendered config has no auth callout although certificateAuthorization is enabled")
	}

	assertStaticUsersMatch(t, opts.Users, rendered.staticUsers)

	srv := startServer(t, rendered.conf)
	serveCallout(t, srv, pki, authUser, issuer, rendered.staticUsers)

	assertCorePublishes(t, srv, pki)
}

// assertCorePublishes publishes every core subject and observes the verdict.
// A plain NATS publish reports success even when the server denies it, so the
// assertions observe delivery to an independent subscriber and the permission
// violation the server reports back.
func assertCorePublishes(t *testing.T, srv *server.Server, pki *testPKI) {
	t.Helper()

	tools := pki.connect(t, srv, toolsSubject, nil)
	core, coreErrs := pki.connectTracked(t, srv, coreSubject)

	all := append(append([]string{}, coreAllowedSubjects...), coreDeniedSubjects...)
	received := make(map[string]chan struct{})

	for _, subject := range all {
		ch := make(chan struct{}, 1)
		received[subject] = ch

		if _, err := tools.Subscribe(subject, func(*nats.Msg) { ch <- struct{}{} }); err != nil {
			t.Fatalf("subscribe %s: %v", subject, err)
		}
	}

	if err := tools.Flush(); err != nil {
		t.Fatalf("flush subscriptions: %v", err)
	}

	for _, subject := range all {
		if err := core.Publish(subject, []byte(`{"synthetic":true}`)); err != nil {
			t.Fatalf("publish %s: %v", subject, err)
		}
	}

	if err := core.Flush(); err != nil {
		t.Fatalf("flush core: %v", err)
	}

	// The server answers publishes on one connection in order, so once the
	// violation for the last subject has arrived every earlier verdict has too.
	last := coreDeniedSubjects[len(coreDeniedSubjects)-1]
	if !coreErrs.waitFor(last, 5*time.Second) {
		t.Fatalf("expected a permissions violation for %s, got %v", last, coreErrs.all())
	}

	for _, subject := range coreAllowedSubjects {
		select {
		case <-received[subject]:
		case <-time.After(5 * time.Second):
			t.Errorf("core publish to %s was not delivered; violations: %v", subject, coreErrs.all())
		}

		if coreErrs.has(subject) {
			t.Errorf("server denied core publish to %s: %v", subject, coreErrs.all())
		}
	}

	for _, subject := range coreDeniedSubjects {
		if !coreErrs.has(subject) {
			t.Errorf("expected permission denial for %s", subject)
		}
		select {
		case <-received[subject]:
			t.Errorf("forbidden core publish to %s was delivered", subject)
		default:
		}
	}
}

// staticUser is one entry of the serviceradar-nats-static-users list.
type staticUser struct {
	User      string      `yaml:"user"`
	Publish   staticBlock `yaml:"publish"`
	Subscribe staticBlock `yaml:"subscribe"`
}

type staticBlock struct {
	Allow []string `yaml:"allow"`
	Deny  []string `yaml:"deny"`
}

// assertStaticUsersMatch compares the list with the users nats-server parsed
// from the rendered configuration, permission by permission.
func assertStaticUsersMatch(t *testing.T, users []*server.User, listed []staticUser) {
	t.Helper()

	byName := make(map[string]staticUser, len(listed))
	for _, u := range listed {
		byName[u.User] = u
	}

	if len(users) != len(listed) || len(byName) != len(listed) {
		t.Errorf("broker configures %d users, static users list has %d entries (%d distinct)", len(users), len(listed), len(byName))
	}

	for _, user := range users {
		u, ok := byName[user.Username]
		if !ok {
			t.Errorf("broker user %q is missing from the static users list", user.Username)
			continue
		}

		var publish, subscribe *server.SubjectPermission
		if user.Permissions != nil {
			publish, subscribe = user.Permissions.Publish, user.Permissions.Subscribe
		}

		compareBlock(t, user.Username, "publish", publish, u.Publish)
		compareBlock(t, user.Username, "subscribe", subscribe, u.Subscribe)
	}
}

func compareBlock(t *testing.T, user, direction string, broker *server.SubjectPermission, listed staticBlock) {
	t.Helper()

	var allow, deny []string
	if broker != nil {
		allow, deny = broker.Allow, broker.Deny
	}

	if !sameSubjects(allow, listed.Allow) || !sameSubjects(deny, listed.Deny) {
		t.Errorf("%s %s: broker allow=%v deny=%v, static users list allow=%v deny=%v", user, direction, allow, deny, listed.Allow, listed.Deny)
	}
}

func sameSubjects(a, b []string) bool {
	a, b = slices.Clone(a), slices.Clone(b)
	sort.Strings(a)
	sort.Strings(b)

	return slices.Equal(a, b)
}

// serveCallout answers the broker's authorization requests as the AUTH account
// user. A certificate whose subject is in the static users list gets that block
// with static semantics (an empty allow list is every subject); any other is
// refused.
func serveCallout(t *testing.T, srv *server.Server, pki *testPKI, authUser, issuer nkeys.KeyPair, listed []staticUser) {
	t.Helper()

	seed, err := authUser.Seed()
	if err != nil {
		t.Fatalf("auth user seed: %v", err)
	}

	grants := make(map[string]staticUser, len(listed))
	for _, u := range listed {
		grants[subjectKey(u.User)] = u
	}

	cert, _ := pki.issue(t, pkix.Name{CommonName: "synthetic-authorizer"}, x509.ExtKeyUsageClientAuth)

	nc, err := nats.Connect(srv.ClientURL(),
		nats.Secure(&tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: pki.pool, MinVersion: tls.VersionTLS12}),
		nats.Nkey(publicKey(t, authUser), func(nonce []byte) ([]byte, error) {
			kp, err := nkeys.FromSeed(seed)
			if err != nil {
				return nil, err
			}

			return kp.Sign(nonce)
		}),
		nats.Timeout(10*time.Second),
	)
	if err != nil {
		t.Fatalf("connect authorization callout user: %v", err)
	}

	t.Cleanup(nc.Close)

	_, err = nc.Subscribe(server.AuthCalloutSubject, func(msg *nats.Msg) {
		request, err := jwt.DecodeAuthorizationRequestClaims(string(msg.Data))
		if err != nil {
			t.Errorf("decode authorization request: %v", err)
			return
		}

		response := jwt.NewAuthorizationResponseClaims(request.UserNkey)
		response.Audience = request.Server.ID

		u, ok := grants[requestSubjectKey(request)]
		if !ok {
			response.Error = "certificate not authorized"
		} else {
			user := jwt.NewUserClaims(request.UserNkey)
			user.Audience = chartAccount
			user.Expires = time.Now().Add(time.Hour).Unix()
			user.Pub = staticPermission(u.Publish)
			user.Sub = staticPermission(u.Subscribe)

			if response.Jwt, err = user.Encode(issuer); err != nil {
				t.Errorf("sign user grant: %v", err)
				return
			}
		}

		token, err := response.Encode(issuer)
		if err != nil {
			t.Errorf("sign authorization response: %v", err)
			return
		}

		_ = msg.Respond([]byte(token))
	})
	if err != nil {
		t.Fatalf("subscribe %s: %v", server.AuthCalloutSubject, err)
	}

	if err := nc.Flush(); err != nil {
		t.Fatalf("flush authorization callout subscription: %v", err)
	}
}

// staticPermission projects one static block the way core does: an empty or
// missing allow list becomes every subject, and deny is kept.
func staticPermission(block staticBlock) jwt.Permission {
	allow := block.Allow
	if len(allow) == 0 {
		allow = []string{">"}
	}

	return jwt.Permission{Allow: allow, Deny: block.Deny}
}

func requestSubjectKey(request *jwt.AuthorizationRequestClaims) string {
	if request.TLS == nil || len(request.TLS.VerifiedChains) == 0 || len(request.TLS.VerifiedChains[0]) == 0 {
		return ""
	}

	block, _ := pem.Decode([]byte(request.TLS.VerifiedChains[0][0]))
	if block == nil {
		return ""
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return ""
	}

	return subjectKey(cert.Subject.String())
}

// subjectKey compares subjects as a set of attributes, as the broker's
// distinguished-name match and core's authorizer do.
func subjectKey(dn string) string {
	parts := strings.Split(dn, ",")
	sort.Strings(parts)

	return strings.Join(parts, ",")
}

func newKey(t *testing.T, create func() (nkeys.KeyPair, error)) nkeys.KeyPair {
	t.Helper()

	kp, err := create()
	if err != nil {
		t.Fatalf("create nkey: %v", err)
	}

	return kp
}

func publicKey(t *testing.T, kp nkeys.KeyPair) string {
	t.Helper()

	pub, err := kp.PublicKey()
	if err != nil {
		t.Fatalf("nkey public key: %v", err)
	}

	return pub
}

func startServer(t *testing.T, conf string) *server.Server {
	t.Helper()

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

	return srv
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

type renderedChart struct {
	conf        string
	staticUsers []staticUser
}

// renderChart renders templates/nats.yaml with helm-unittest, which snapshots
// the broker configuration script and the static users ConfigMap.
func renderChart(t *testing.T, pki *testPKI, natsValues map[string]any) renderedChart {
	t.Helper()

	chartYAML := runfile(t, chartYAMLEnv)
	untt := runfile(t, unttEnv)

	work := t.TempDir()
	chartDir := filepath.Join(work, "chart")
	copyChart(t, filepath.Dir(chartYAML), chartDir)

	nats := map[string]any{"replicas": 1}
	for key, value := range natsValues {
		nats[key] = value
	}

	set := map[string]any{"nats": nats}
	selector := func(kind string) map[string]any { return map[string]any{"path": "kind", "value": kind} }

	suite, err := yaml.Marshal(map[string]any{
		"suite":     "render nats server config",
		"templates": []string{"templates/nats.yaml"},
		"tests": []map[string]any{
			{
				"it":               "server-config",
				"set":              set,
				"documentSelector": selector("StatefulSet"),
				"asserts":          []map[string]any{{"matchSnapshot": map[string]any{"path": "spec.template.spec.containers[0].args[0]"}}},
			},
			{
				"it":               "static-users",
				"set":              set,
				"documentSelector": selector("ConfigMap"),
				"asserts":          []map[string]any{{"matchSnapshot": map[string]any{"path": `data["static-users.yaml"]`}}},
			},
		},
	})
	if err != nil {
		t.Fatalf("encode render suite: %v", err)
	}

	writeFile(t, filepath.Join(chartDir, "tests", "render_test.yaml"), suite, 0o644)

	cmd := exec.CommandContext(t.Context(), untt, "--update-snapshot", chartDir)
	cmd.Env = append(os.Environ(), "HOME="+work)

	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("render chart with helm-unittest: %v\n%s", err, out)
	}

	snapshot, err := os.ReadFile(filepath.Join(chartDir, "tests", "__snapshot__", "render_test.yaml.snap"))
	if err != nil {
		t.Fatalf("read rendered snapshot: %v", err)
	}

	script := decodeSnapshot(t, snapshot, "server-config")

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

	var users []staticUser
	if err := yaml.Unmarshal([]byte(decodeSnapshot(t, snapshot, "static-users")), &users); err != nil {
		t.Fatalf("parse static users list: %v", err)
	}

	if len(users) == 0 {
		t.Fatal("static users ConfigMap lists no users")
	}

	return renderedChart{conf: confPath, staticUsers: users}
}

// decodeSnapshot unwraps one test's value from helm-unittest's snapshot file: a
// YAML map of test name to numbered snapshots, each holding the asserted value
// serialised as YAML.
func decodeSnapshot(t *testing.T, raw []byte, test string) string {
	t.Helper()

	var tests map[string]map[string]string
	if err := yaml.Unmarshal(raw, &tests); err != nil {
		t.Fatalf("parse snapshot file: %v", err)
	}

	snapshots := tests[test]
	if len(snapshots) != 1 {
		t.Fatalf("expected exactly one %s snapshot, got %v", test, tests)
	}

	for _, serialised := range snapshots {
		var value string
		if err := yaml.Unmarshal([]byte(serialised), &value); err != nil {
			t.Fatalf("parse snapshot value: %v", err)
		}

		return value
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
