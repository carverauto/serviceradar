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

package chartacl

import (
	"bytes"
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	logCollectorBinaryEnv = "SERVICERADAR_LOG_COLLECTOR_BINARY"

	// The empty ruleset and the digest rust/zen-normalize and core's publisher
	// both assert for it.
	emptyRulesetDigest = "sha256:11f468c88fd9041ba1b94ae65bbb4b04cf2d8f690b8d1d62f99f4689ccfc961b"
	emptyRuleset       = `{"schema":"serviceradar.zen.ruleset.v1","stream_name":"events","subject":"logs.syslog","rules":[],"digest":"` +
		emptyRulesetDigest + `"}`
)

// TestCollectorProcessUnderChartPermissions runs the log collector binary, with
// its syslog, OTLP and RUM parts enabled as the chart enables them, against the
// broker the chart configures. The JetStream API subjects a client uses are a
// property of that client, so the grants are checked with the Rust client the
// collector ships: the process must create the events stream, deliver syslog
// into it, and pick up a ruleset published after it started, and the broker
// must not have refused it anything on the way.
func TestCollectorProcessUnderChartPermissions(t *testing.T) {
	pki := newTestPKI(t)
	rendered := renderChart(t, pki, nil)
	srv := startServer(t, rendered.conf)

	refused := &refusals{}
	srv.SetLogger(refused, false, false)

	core := jetStreamAs(t, pki, srv, coreSubject)

	rules, err := core.CreateKeyValue(t.Context(), jetstream.KeyValueConfig{
		Bucket:   ruleBucket,
		History:  1,
		MaxBytes: 1 << 20,
		Storage:  jetstream.FileStorage,
	})
	if err != nil {
		t.Fatalf("core creates the rule bucket: %v", err)
	}

	collector := startCollector(t, pki, srv)

	events := waitForStream(t, core, "events", collector)
	received := consume(t, events)

	// No ruleset is published yet, so syslog arrives as the collector read it.
	collector.sendUntil(t, received, func(msg jetstream.Msg) bool { return msg.Subject() == "logs.syslog" })

	if _, err := rules.Put(t.Context(), ruleKey, []byte(emptyRuleset)); err != nil {
		t.Fatalf("core writes a bundle: %v", err)
	}

	// The bundle reaches the running collector through its watch on the bucket.
	collector.sendUntil(t, received, func(msg jetstream.Msg) bool {
		return msg.Subject() == "logs.normalized.syslog" && msg.Headers().Get("Sr-Ruleset-Id") == emptyRulesetDigest
	})

	if lines := refused.all(); len(lines) != 0 {
		t.Fatalf("the broker refused the collector:\n%s\ncollector output:\n%s", strings.Join(lines, "\n"), collector.output())
	}
}

// refusals keeps the permission violations the broker logs.
type refusals struct {
	mu    sync.Mutex
	lines []string
}

func (r *refusals) recordf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	if !strings.Contains(line, "Violation") {
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	r.lines = append(r.lines, line)
}

func (r *refusals) all() []string {
	r.mu.Lock()
	defer r.mu.Unlock()

	return append([]string(nil), r.lines...)
}

func (r *refusals) Noticef(format string, args ...any) { r.recordf(format, args...) }
func (r *refusals) Warnf(format string, args ...any)   { r.recordf(format, args...) }
func (r *refusals) Errorf(format string, args ...any)  { r.recordf(format, args...) }
func (r *refusals) Fatalf(format string, args ...any)  { r.recordf(format, args...) }
func (*refusals) Debugf(string, ...any)                {}
func (*refusals) Tracef(string, ...any)                {}

type collectorProcess struct {
	syslog *net.UDPAddr
	stderr *bytes.Buffer
	mu     *sync.Mutex
}

func (c *collectorProcess) output() string {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.stderr.String()
}

// sendUntil sends syslog lines until a stored message satisfies want. The
// collector binds its listener and activates a ruleset on its own schedule, so
// a line is sent again until the expected message is stored.
func (c *collectorProcess) sendUntil(t *testing.T, received <-chan jetstream.Msg, want func(jetstream.Msg) bool) {
	t.Helper()

	conn, err := net.DialUDP("udp", nil, c.syslog)
	if err != nil {
		t.Fatalf("dial the collector's syslog listener: %v", err)
	}

	defer func() { _ = conn.Close() }()

	deadline := time.After(60 * time.Second)
	tick := time.NewTicker(250 * time.Millisecond)

	defer tick.Stop()

	for sequence := 0; ; sequence++ {
		line := fmt.Sprintf("<134>1 2026-01-01T00:00:00Z host01.example.com synthetic - - - line %d", sequence)
		// A send to a listener that is not bound yet fails; the next one is tried.
		_, _ = conn.Write([]byte(line))

		select {
		case msg := <-received:
			if want(msg) {
				return
			}
		case <-tick.C:
		case <-deadline:
			t.Fatalf("no stored message matched within the deadline; collector output:\n%s", c.output())
		}
	}
}

type lockedWriter struct {
	mu  *sync.Mutex
	buf *bytes.Buffer
}

func (w lockedWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	return w.buf.Write(p)
}

func startCollector(t *testing.T, pki *testPKI, srv *server.Server) *collectorProcess {
	t.Helper()

	dir := t.TempDir()

	cert, key := pki.issue(t, clientSubject(t, logCollectorSubject), x509.ExtKeyUsageClientAuth)
	certFile := filepath.Join(dir, "log-collector.pem")
	keyFile := filepath.Join(dir, "log-collector-key.pem")
	caFile := filepath.Join(pki.dir, "root.pem")

	writeFile(t, certFile, pemBlock("CERTIFICATE", cert.Certificate[0]), 0o644)
	writeFile(t, keyFile, key, 0o600)

	natsURL := "tls://" + srv.Addr().String()
	syslog := freeUDPAddr(t)

	flowggerFile := filepath.Join(dir, "flowgger.toml")
	otelFile := filepath.Join(dir, "otel.toml")
	collectorFile := filepath.Join(dir, "log-collector.toml")

	// The same sections the chart renders for the collector, with local
	// addresses and this test's certificates.
	writeFile(t, flowggerFile, fmt.Appendf(nil, `[input]
rfc3164_timezone = "UTC"
type = "udp"
listen = %q
format = "auto"

[output]
type = "nats"
format = "gelf"
framing = "noop"
partition = "default"
nats_url = %q
nats_subject = "logs.syslog"
nats_stream = "events"
nats_stream_replicas = 1
nats_timeout = 30000
nats_connect_attempts = 10
nats_connect_initial_backoff_ms = 500
nats_connect_max_backoff_ms = 30000
nats_tls_ca_file = %q
nats_tls_cert = %q
nats_tls_key = %q
nats_tls_skip_verify = false
`, syslog.String(), natsURL, caFile, certFile, keyFile), 0o644)

	writeFile(t, otelFile, fmt.Appendf(nil, `[server]
bind_address = "127.0.0.1"
port = %d

[server.http]
enabled = true
bind_address = "127.0.0.1"
port = %d
tls_enabled = false

[nats]
url = %q
subject = "otel"
logs_subject = "logs.otel"
stream = "events"
timeout_secs = 30
max_bytes = 1048576
max_age_secs = 1800
stream_replicas = 1

[nats.tls]
cert_file = %q
key_file = %q
ca_file = %q

[grpc_tls]
cert_file = %q
key_file = %q

[rum]
enabled = true
max_body_bytes = 65536
`, freeTCPPort(t), freeTCPPort(t), natsURL, certFile, keyFile, caFile, certFile, keyFile), 0o644)

	writeFile(t, collectorFile, fmt.Appendf(nil, `[flowgger]
enabled = true
config_file = %q

[otel]
enabled = true
config_file = %q

[health]
listen_addr = "127.0.0.1:%d"

[rules.nats]
url = %q

[rules.nats.tls]
cert_file = %q
key_file = %q
ca_file = %q
`, flowggerFile, otelFile, freeTCPPort(t), natsURL, certFile, keyFile, caFile), 0o644)

	process := &collectorProcess{syslog: syslog, stderr: &bytes.Buffer{}, mu: &sync.Mutex{}}
	out := lockedWriter{mu: process.mu, buf: process.stderr}

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, runfile(t, logCollectorBinaryEnv), "--config", collectorFile)
	cmd.Dir = dir
	cmd.Stdout = out
	cmd.Stderr = out
	cmd.Env = append(os.Environ(),
		"RUST_LOG=info",
		"SERVICERADAR_JS_EVENTS_MAX_BYTES=1048576",
		"SERVICERADAR_JS_EVENTS_REPLICAS=1",
	)

	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("start the log collector: %v", err)
	}

	t.Cleanup(func() {
		cancel()

		_ = cmd.Wait()
	})

	return process
}

func waitForStream(t *testing.T, js jetstream.JetStream, name string, collector *collectorProcess) jetstream.Stream {
	t.Helper()

	deadline := time.Now().Add(60 * time.Second)

	for {
		stream, err := js.Stream(t.Context(), name)
		if err == nil {
			return stream
		}

		if time.Now().After(deadline) {
			t.Fatalf("the collector did not create the %s stream: %v\ncollector output:\n%s", name, err, collector.output())
		}

		time.Sleep(250 * time.Millisecond)
	}
}

func consume(t *testing.T, stream jetstream.Stream) <-chan jetstream.Msg {
	t.Helper()

	consumer, err := stream.OrderedConsumer(t.Context(), jetstream.OrderedConsumerConfig{})
	if err != nil {
		t.Fatalf("read the events stream: %v", err)
	}

	received := make(chan jetstream.Msg, 1024)

	consuming, err := consumer.Consume(func(msg jetstream.Msg) {
		select {
		case received <- msg:
		default:
		}
	})
	if err != nil {
		t.Fatalf("consume the events stream: %v", err)
	}

	t.Cleanup(consuming.Stop)

	return received
}

func freeTCPPort(t *testing.T) int {
	t.Helper()

	listener, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a TCP port: %v", err)
	}

	defer func() { _ = listener.Close() }()

	return listener.Addr().(*net.TCPAddr).Port
}

func freeUDPAddr(t *testing.T) *net.UDPAddr {
	t.Helper()

	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("reserve a UDP port: %v", err)
	}

	defer func() { _ = conn.Close() }()

	return conn.LocalAddr().(*net.UDPAddr)
}
