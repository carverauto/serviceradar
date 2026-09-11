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

// Package verticalslice hosts the harness for
// //integration_tests/edge_record:vertical_slice_test (unify-sweep-results-proto
// task 0.12). This file manages the lifecycle of the two real Elixir Mix
// releases the harness starts as literal OS subprocesses -- mirroring how
// docker-compose.yml actually deploys serviceradar-agent-gateway and
// serviceradar-core-elx as separate services, rather than starting both
// OTP apps in one BEAM VM -- so the target satisfies task 0.12's "starts the
// production supervision and configuration" requirement literally.
package verticalslice

import (
	"archive/tar"
	"compress/gzip"
	cryptorand "crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ReleaseProcess is one running Elixir Mix release, started as a real
// `bin/<name> start` subprocess against a scratch environment.
type ReleaseProcess struct {
	Name      string
	NodeName  string
	Cookie    string
	HealthURL string
	RootDir   string // the extracted release directory (contains bin/<name>)

	cmd        *exec.Cmd
	stdoutPath string
	stderrPath string
	secrets    []string
}

// ReleaseEnv is what StartRelease needs from a release's configuration: the
// environment to boot it with, and which of those values must never reach a
// log that leaves this test.
type ReleaseEnv interface {
	Env() map[string]string
	Secrets() []string
}

// GatewayEnvConfig documents and builds every environment variable this
// harness needs to boot elixir/serviceradar_agent_gateway's release for the
// vertical-slice test, confirmed by reading
// elixir/serviceradar_agent_gateway/config/runtime.exs and
// elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex's
// edge_server_ssl_opts!/0.
//
// CRITICAL: the gateway release includes elixir/serviceradar_core as a
// normal (not runtime: false) mix dependency, so `mix release` bundles and
// AUTO-STARTS :serviceradar_core alongside :serviceradar_agent_gateway in
// the SAME OS process -- core's own config/runtime.exs runs too, and it
// unconditionally raises at boot if DATABASE_URL is unset (line ~663) or
// CLOAK_KEY is unset (line ~501), regardless of EVENT_WRITER_ENABLED. Unlike
// serviceradar_core_elx's OWN runtime.exs (which builds a repo URL from
// piecewise CNPG_HOST/PORT/DATABASE/USERNAME/PASSWORD when DATABASE_URL is
// absent), serviceradar_core's own runtime.exs has NO such piecewise
// fallback -- it reads DATABASE_URL directly. So the gateway release needs
// DATABASE_URL and CLOAK_KEY set explicitly, or it crashes at boot before
// ever reaching its own gRPC listener.
type GatewayEnvConfig struct {
	GRPCPort    int
	MetricsPort int
	// CertDir MUST contain files named exactly "gateway.pem", "gateway-key.pem"
	// and "root.pem" (application.ex:254-276, edge_server_ssl_opts!/0) -- the
	// gateway's gRPC TLS listener refuses to start ("No mTLS certs available
	// for agent gateway edge listeners") if any is missing. The caller is
	// responsible for staging a directory with those exact names (copy or
	// symlink from whatever certs.go produced).
	CertDir       string
	NATSURL       string
	NATSCredsFile string
	PartitionID   string
	GatewayID     string
	Domain        string
	// CNPGHost/Port/Database/Username/Password build the DATABASE_URL
	// serviceradar_core's own runtime.exs requires (see the type doc comment).
	// Use the SAME values passed to the paired CoreEnvConfig for this test run.
	CNPGHost     string
	CNPGPort     int
	CNPGDatabase string
	CNPGUsername string
	CNPGPassword string
	// CNPGSSLMode only selects verify_none-vs-disabled TLS on this release
	// (serviceradar_core's own runtime.exs has no CA-file/hostname-verification
	// support, unlike core_elx's wrapper) -- "disable" or any other value both
	// produce a working, if less strictly verified, connection.
	CNPGSSLMode string
	// CloakKey MUST be the SAME value passed to the paired CoreEnvConfig --
	// it does not need to match any real secret, but both releases connecting
	// to the SAME database with a mismatched key would be a needless
	// divergence from how these two processes are actually deployed together.
	CloakKey string
}

// Env returns the environment variables StartRelease should merge in to boot
// the gateway release for this test. AGENT_GATEWAY_NATS_TLS is deliberately
// "false": the embedded test NATS harness (natsjwt.go) authenticates via
// NKEY/JWT creds only, with no TLS listener. POOL_SIZE/CONTROL_REPO_POOL_SIZE
// are kept small (2) because this release's bundled serviceradar_core also
// opens its own Postgres connection pool purely to satisfy Application.start
// -- CNPG capacity for the required BazelCI check is a finite, preflighted
// budget (build/integration_shards.bzl), and this process does no
// database-heavy work of its own.
func (c GatewayEnvConfig) Env() map[string]string {
	sslMode := c.CNPGSSLMode
	if sslMode == "" {
		sslMode = "disable"
	}

	databaseURL := fmt.Sprintf(
		"ecto://%s:%s@%s:%d/%s",
		url.QueryEscape(c.CNPGUsername), url.QueryEscape(c.CNPGPassword), c.CNPGHost, c.CNPGPort, c.CNPGDatabase,
	)

	return map[string]string{
		"CLUSTER_ENABLED":                    "false",
		"AGENT_GATEWAY_EDGE_RECORDS_ENABLED": "true",
		"GATEWAY_GRPC_PORT":                  fmt.Sprintf("%d", c.GRPCPort),
		"GATEWAY_METRICS_PORT":               fmt.Sprintf("%d", c.MetricsPort),
		"GATEWAY_CERT_DIR":                   c.CertDir,
		"AGENT_GATEWAY_NATS_URL":             c.NATSURL,
		"NATS_URL":                           c.NATSURL,
		"AGENT_GATEWAY_NATS_TLS":             "false",
		"AGENT_GATEWAY_NATS_CREDS_FILE":      c.NATSCredsFile,
		"GATEWAY_PARTITION_ID":               c.PartitionID,
		"GATEWAY_ID":                         c.GatewayID,
		"GATEWAY_DOMAIN":                     c.Domain,
		"DATABASE_URL":                       databaseURL,
		"CNPG_SSL_MODE":                      sslMode,
		"CLOAK_KEY":                          c.CloakKey,
		"POOL_SIZE":                          "2",
		"CONTROL_REPO_POOL_SIZE":             "2",
	}
}

// Secrets returns every rendering of the shard password Env places in the
// gateway's environment: URL-escaped inside DATABASE_URL, and the raw form
// its bundled serviceradar_core holds once it has parsed that URL.
func (c GatewayEnvConfig) Secrets() []string {
	return cnpgPasswordForms(c.CNPGPassword)
}

// CoreEnvConfig documents and builds every environment variable this harness
// needs to boot elixir/serviceradar_core_elx's release with
// ServiceRadar.EventWriter.Pipeline actually running, confirmed by reading
// elixir/serviceradar_core_elx/config/runtime.exs.
//
// CNPGHost/Port/Database/Username/Password below come from ShardCNPGConfig:
// this test's own sr_core_test_<run>_edge_record clone of the schema
// generation, created and described by //rust/integration-db binaries the
// harness executes (vertical_slice_test.go's provisionAndDescribeShard).
type CoreEnvConfig struct {
	MetricsPort   int
	CNPGHost      string
	CNPGPort      int
	CNPGDatabase  string
	CNPGUsername  string
	CNPGPassword  string
	NATSURL       string
	NATSCredsFile string
	// CloakKey is a base64-encoded 32-byte key; CLOAK_KEY (or CLOAK_KEY_FILE)
	// is a hard `raise` in runtime.exs:551 when config_env() == :prod (which
	// a real `mix release` always is) -- generate one fresh per test run with
	// GenerateCloakKey below, it never needs to decrypt anything real.
	CloakKey string
	// CNPGSSLMode is CNPG_SSL_MODE (elixir/serviceradar_core_elx/config/runtime.exs:651,
	// default "disable"). The shard database is password+TLS-verified (see
	// ShardCNPGConfig and vertical_slice_test.go's provisionAndDescribeShard), so the
	// harness sets this to the value describe_shard reported ("require"/"verify-ca"/"verify-full").
	CNPGSSLMode string
	// CNPGCAFile is CNPG_CA_FILE (runtime.exs:656-660) -- the CA the connection verifies
	// the server certificate against. Empty omits the env var (falls back to
	// runtime.exs's own CNPG_CERT_DIR-derived default, which is also empty here since no
	// CNPG_CERT_DIR is set).
	CNPGCAFile string
	// CNPGTLSServerName is CNPG_TLS_SERVER_NAME (runtime.exs:653), read only when
	// CNPGSSLMode is "verify-full". Empty omits the env var.
	CNPGTLSServerName string
}

// GenerateCloakKey returns a fresh base64-encoded 32-byte key suitable for
// CLOAK_KEY, matching the generation instructions in
// elixir/serviceradar_core_elx/config/runtime.exs:551-554.
func GenerateCloakKey() (string, error) {
	b := make([]byte, 32)
	if _, err := cryptorand.Read(b); err != nil {
		return "", fmt.Errorf("verticalslice: generate cloak key: %w", err)
	}
	return base64.StdEncoding.EncodeToString(b), nil
}

// Env returns the environment variables StartRelease should merge in to boot
// the core_elx release with EventWriter enabled for this test.
func (c CoreEnvConfig) Env() map[string]string {
	sslMode := c.CNPGSSLMode
	if sslMode == "" {
		sslMode = "disable"
	}

	env := map[string]string{
		"CLUSTER_ENABLED":                "false",
		"SERVICERADAR_CORE_METRICS_PORT": fmt.Sprintf("%d", c.MetricsPort),
		"CNPG_HOST":                      c.CNPGHost,
		"CNPG_PORT":                      fmt.Sprintf("%d", c.CNPGPort),
		"CNPG_DATABASE":                  c.CNPGDatabase,
		"CNPG_USERNAME":                  c.CNPGUsername,
		"CNPG_PASSWORD":                  c.CNPGPassword,
		"CNPG_SSL_MODE":                  sslMode,
		"EVENT_WRITER_ENABLED":           "true",
		"EVENT_WRITER_NATS_URL":          c.NATSURL,
		"EVENT_WRITER_NATS_TLS":          "false",
		"EVENT_WRITER_NATS_CREDS_FILE":   c.NATSCredsFile,
		"CLOAK_KEY":                      c.CloakKey,
		"POOL_SIZE":                      "2",
		"CONTROL_REPO_POOL_SIZE":         "2",
	}
	if c.CNPGCAFile != "" {
		env["CNPG_CA_FILE"] = c.CNPGCAFile
	}
	if c.CNPGTLSServerName != "" {
		env["CNPG_TLS_SERVER_NAME"] = c.CNPGTLSServerName
	}
	return env
}

// Secrets returns every rendering of the shard password Env places in the
// core release's environment: raw as CNPG_PASSWORD, and URL-escaped inside
// the DATABASE_URL runtime.exs assembles from it.
func (c CoreEnvConfig) Secrets() []string {
	return cnpgPasswordForms(c.CNPGPassword)
}

// cnpgPasswordForms returns password in every rendering the release
// environments carry it, URL-escaped first because that form can contain the
// raw one as a substring.
func cnpgPasswordForms(password string) []string {
	if password == "" {
		return nil
	}
	if escaped := url.QueryEscape(password); escaped != password {
		return []string{escaped, password}
	}
	return []string{password}
}

// ShardCNPGConfig is the JSON shape
// //rust/integration-db:describe_shard prints to stdout: this test's already-cloned
// sr_core_test_<run>_<shard> database's real connection identity, resolved from the typed SERVICERADAR_ENV=ci
// fixture (see that binary's moduledoc for why a Rust binary does this resolution
// instead of this package reimplementing it).
type ShardCNPGConfig struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	Database      string `json:"database"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	SSLMode       string `json:"sslmode"`
	TLSServerName string `json:"tls_server_name,omitempty"`
	CAPEMBase64   string `json:"ca_pem_base64,omitempty"`
	// AdminUsername/AdminPassword are the CREATEDB/DDL-capable role, distinct from
	// Username (which deliberately lacks it). Group D's forced-CNPG-rollback probe
	// uses these to transiently REVOKE/GRANT table privileges on the app role.
	AdminUsername string `json:"admin_username"`
	AdminPassword string `json:"admin_password"`
}

// WriteCAPEMFile decodes cfg.CAPEMBase64 (when present) and writes it to
// <dir>/cnpg-ca.pem, returning the path. Returns "" (no error) when there is no CA
// PEM to write.
func (cfg *ShardCNPGConfig) WriteCAPEMFile(dir string) (string, error) {
	if cfg == nil || cfg.CAPEMBase64 == "" {
		return "", nil
	}

	pem, err := base64.StdEncoding.DecodeString(cfg.CAPEMBase64)
	if err != nil {
		return "", fmt.Errorf("verticalslice: decode ca_pem_base64: %w", err)
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("verticalslice: mkdir %s: %w", dir, err)
	}

	path := filepath.Join(dir, "cnpg-ca.pem")
	if err := os.WriteFile(path, pem, 0o644); err != nil { //nolint:gosec // a CA cert is public
		return "", fmt.Errorf("verticalslice: write %s: %w", path, err)
	}
	return path, nil
}

// StartRelease extracts releaseTarPath (a gzipped tar produced by Bazel's
// elixir_release rule) into workDir/<releaseName>, then execs
// "<extracted>/bin/<releaseName> start" as a background process with env
// merged from a minimal host passthrough (PATH, HOME, LANG) plus cfg.Env()
// plus RELEASE_NODE/RELEASE_COOKIE, and polls healthURL (a plain HTTP GET
// expected to return 200) until ready or timeout elapses. stdout/stderr are
// captured raw to files under workDir for postmortem debugging; every reader
// that carries them out of workDir (the tails in a startup-failure error, the
// harness's preserved test outputs) scrubs cfg.Secrets() first.
func StartRelease(
	releaseTarPath, releaseName, workDir string,
	cfg ReleaseEnv,
	healthURL string,
	timeout time.Duration,
) (*ReleaseProcess, error) {
	extractDir := filepath.Join(workDir, releaseName)
	if err := os.MkdirAll(extractDir, 0o755); err != nil {
		return nil, fmt.Errorf("verticalslice: mkdir %s: %w", extractDir, err)
	}
	if err := extractTarGz(releaseTarPath, extractDir); err != nil {
		return nil, fmt.Errorf("verticalslice: extract %s: %w", releaseTarPath, err)
	}

	binPath, err := findReleaseBin(extractDir, releaseName)
	if err != nil {
		return nil, err
	}

	nodeName := fmt.Sprintf("%s_vslice_%d@127.0.0.1", releaseName, time.Now().UnixNano())
	cookie := randomCookie()

	env := mergedEnv(cfg.Env(), map[string]string{
		"RELEASE_NODE":         nodeName,
		"RELEASE_COOKIE":       cookie,
		"RELEASE_DISTRIBUTION": "name",
	})

	stdoutPath := filepath.Join(workDir, releaseName+".stdout.log")
	stderrPath := filepath.Join(workDir, releaseName+".stderr.log")
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create stdout log: %w", err)
	}
	stderrFile, err := os.Create(stderrPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create stderr log: %w", err)
	}

	cmd := exec.Command(binPath, "start")
	cmd.Env = env
	cmd.Stdout = stdoutFile
	cmd.Stderr = stderrFile
	cmd.Dir = extractDir

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("verticalslice: start %s: %w", binPath, err)
	}

	p := &ReleaseProcess{
		Name:       releaseName,
		NodeName:   nodeName,
		Cookie:     cookie,
		HealthURL:  healthURL,
		RootDir:    extractDir,
		cmd:        cmd,
		stdoutPath: stdoutPath,
		stderrPath: stderrPath,
		secrets:    cfg.Secrets(),
	}

	if err := p.waitHealthy(timeout); err != nil {
		p.Stop()
		return nil, err
	}

	return p, nil
}

func (p *ReleaseProcess) waitHealthy(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 2 * time.Second}

	for time.Now().Before(deadline) {
		if p.cmd.ProcessState != nil {
			return fmt.Errorf(
				"verticalslice: %s exited early: %s\n--- stdout tail ---\n%s\n--- stderr tail ---\n%s",
				p.Name, p.cmd.ProcessState, tailFile(p.stdoutPath, 4000, p.secrets), tailFile(p.stderrPath, 4000, p.secrets),
			)
		}

		resp, err := client.Get(p.HealthURL)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}

	return fmt.Errorf(
		"verticalslice: %s did not become healthy at %s within timeout\n--- stdout tail ---\n%s\n--- stderr tail ---\n%s",
		p.Name, p.HealthURL, tailFile(p.stdoutPath, 4000, p.secrets), tailFile(p.stderrPath, 4000, p.secrets),
	)
}

// RPC runs "bin/<releaseName> rpc <expr>" against the already-running
// release (same RELEASE_NODE/RELEASE_COOKIE it was started with) and returns
// trimmed stdout. Use for CNPG assertions via the release's own configured
// Ecto.Repo, and for task 0.12 groups E/F's lane-transport
// introspection/kill (Process.whereis/Process.exit against the names
// elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/lane_supervisor.ex's
// via/1 registers) -- there is no other black-box admin surface for either.
func (p *ReleaseProcess) RPC(expr string, timeout time.Duration) (string, error) {
	binPath, err := findReleaseBin(p.RootDir, p.Name)
	if err != nil {
		return "", err
	}

	cmd := exec.Command(binPath, "rpc", expr)
	cmd.Env = mergedEnv(nil, map[string]string{
		"RELEASE_NODE":         p.NodeName,
		"RELEASE_COOKIE":       p.Cookie,
		"RELEASE_DISTRIBUTION": "name",
	})

	done := make(chan struct{})
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("verticalslice: rpc start: %w", err)
	}

	var waitErr error
	go func() {
		waitErr = cmd.Wait()
		close(done)
	}()

	select {
	case <-done:
		if waitErr != nil {
			return "", fmt.Errorf("verticalslice: rpc %q failed: %w\nstderr: %s", expr, waitErr, errOut.String())
		}
		return strings.TrimSpace(out.String()), nil
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("verticalslice: rpc %q timed out after %s", expr, timeout)
	}
}

// Stop sends the release's own graceful "bin/<releaseName> stop", then kills
// the process if it has not exited within a short grace period.
func (p *ReleaseProcess) Stop() {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return
	}

	binPath, err := findReleaseBin(p.RootDir, p.Name)
	if err == nil {
		stopCmd := exec.Command(binPath, "stop")
		stopCmd.Env = mergedEnv(nil, map[string]string{
			"RELEASE_NODE":         p.NodeName,
			"RELEASE_COOKIE":       p.Cookie,
			"RELEASE_DISTRIBUTION": "name",
		})
		_ = stopCmd.Run()
	}

	done := make(chan struct{})
	go func() {
		_ = p.cmd.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = p.cmd.Process.Kill()
	}
}

func findReleaseBin(extractDir, releaseName string) (string, error) {
	candidate := filepath.Join(extractDir, "bin", releaseName)
	if _, err := os.Stat(candidate); err == nil {
		return candidate, nil
	}

	// elixir_release output sometimes nests one extra directory level
	// (e.g. the tar's top-level entry is the release name itself); search
	// one level down before giving up.
	entries, err := os.ReadDir(extractDir)
	if err != nil {
		return "", fmt.Errorf("verticalslice: read %s: %w", extractDir, err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		nested := filepath.Join(extractDir, e.Name(), "bin", releaseName)
		if _, err := os.Stat(nested); err == nil {
			return nested, nil
		}
	}

	return "", fmt.Errorf("verticalslice: could not find bin/%s under %s", releaseName, extractDir)
}

func extractTarGz(tarGzPath, destDir string) error {
	f, err := os.Open(tarGzPath)
	if err != nil {
		return err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("gzip reader: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar next: %w", err)
		}

		target := filepath.Join(destDir, hdr.Name) //nolint:gosec // trusted, Bazel-built artifact

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode))
			if err != nil {
				return err
			}
			if _, err := io.Copy(out, tr); err != nil { //nolint:gosec // trusted, Bazel-built artifact
				_ = out.Close()
				return err
			}
			_ = out.Close()
		case tar.TypeSymlink:
			_ = os.Remove(target)
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			if err := os.Symlink(hdr.Linkname, target); err != nil {
				return err
			}
		}
	}
	return nil
}

func tailFile(path string, maxBytes int, secrets []string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("(could not read %s: %v)", path, err)
	}
	if len(data) > maxBytes {
		data = data[len(data)-maxBytes:]
	}
	return redactSecrets(string(data), secrets)
}

// redactSecrets replaces every occurrence of each non-empty secret in s with
// a placeholder.
func redactSecrets(s string, secrets []string) string {
	for _, secret := range secrets {
		if secret == "" {
			continue
		}
		s = strings.ReplaceAll(s, secret, "[REDACTED]")
	}
	return s
}

func mergedEnv(base map[string]string, overrides map[string]string) []string {
	m := map[string]string{}
	for _, k := range []string{"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"} {
		if v := os.Getenv(k); v != "" {
			m[k] = v
		}
	}
	for k, v := range base {
		m[k] = v
	}
	for k, v := range overrides {
		m[k] = v
	}

	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	return out
}

// randomCookie returns a fresh random Erlang distribution cookie, unique per
// test run so concurrent test runs on the same host never collide.
func randomCookie() string {
	b := make([]byte, 16)
	if _, err := cryptorand.Read(b); err != nil {
		// Extremely unlikely; fall back to a fixed value rather than panic --
		// a cookie collision only matters if two releases from DIFFERENT test
		// runs somehow share a host and node name, which they won't (node
		// names are also time-based and process-scoped).
		return "verticalslice-fallback-cookie"
	}
	return hex.EncodeToString(b)
}
