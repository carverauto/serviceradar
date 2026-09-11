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

package verticalslice

import (
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// selfcheckScrubTarget is an invented stand-in for the fixture password
// describe_shard reports. It carries URL-reserved characters so its
// DATABASE_URL rendering differs from its raw form; both must be scrubbed.
const selfcheckScrubTarget = "vslice+scrub/me&x"

// TestPreserveProcessLogsFlattensAndScrubs lays out a harness work directory
// the way newHarness does and checks what preserveProcessLogs leaves in the
// undeclared-outputs directory: every process log under its flattened name,
// nothing else, and no rendering of the shard password.
func TestPreserveProcessLogsFlattensAndScrubs(t *testing.T) {
	dir := t.TempDir()
	h := &harness{
		t:   t,
		dir: dir,
		gatewayEnv: GatewayEnvConfig{
			CNPGHost:     "db.example.com",
			CNPGPort:     5432,
			CNPGDatabase: "sr_core_test_selfcheck_edge_record",
			CNPGUsername: "vslice_app",
			CNPGPassword: selfcheckScrubTarget,
		},
		coreEnv: CoreEnvConfig{CNPGPassword: selfcheckScrubTarget},
	}

	escaped := url.QueryEscape(selfcheckScrubTarget)
	databaseURL := h.gatewayEnv.Env()["DATABASE_URL"]
	if escaped == selfcheckScrubTarget || !strings.Contains(databaseURL, escaped) {
		t.Fatalf("precondition: DATABASE_URL %q should carry the escaped password %q", databaseURL, escaped)
	}

	logs := map[string]string{
		"gateway/serviceradar_agent_gateway.stderr.log": "boot DATABASE_URL=" + databaseURL + "\n",
		"gateway/serviceradar_agent_gateway.stdout.log": "repo password: " + selfcheckScrubTarget + "\n",
		"core/serviceradar_core_elx.stderr.log":         "CNPG_PASSWORD=" + selfcheckScrubTarget + "\n",
		"core/serviceradar_core_elx.stdout.log":         "EventWriter started\n",
		"core-restart/serviceradar_core_elx.stderr.log": "restarted with " + escaped + "\n",
		"agent/agent.stderr.log":                        "edge record sender: dial failed\n",
	}
	notLogs := []string{
		"agent/agent.json",
		"nats-store/jetstream.log",
		"core/serviceradar_core_elx/erl_crash.dump",
	}
	for rel, body := range logs {
		writeSelfcheckFile(t, filepath.Join(dir, rel), body)
	}
	for _, rel := range notLogs {
		writeSelfcheckFile(t, filepath.Join(dir, rel), "password "+selfcheckScrubTarget+"\n")
	}

	out := t.TempDir()
	h.preserveProcessLogs(out)

	entries, err := os.ReadDir(out)
	if err != nil {
		t.Fatalf("read outputs dir: %v", err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.Name())
	}
	var want []string
	for rel := range logs {
		want = append(want, strings.ReplaceAll(rel, "/", "__"))
	}
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("preserved files = %v, want %v", got, want)
	}

	for _, name := range got {
		data, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Fatalf("read preserved %s: %v", name, err)
		}
		if strings.Contains(string(data), selfcheckScrubTarget) || strings.Contains(string(data), escaped) {
			t.Errorf("preserved %s still carries the shard password: %q", name, data)
		}
	}

	gatewayLog, err := os.ReadFile(filepath.Join(out, "gateway__serviceradar_agent_gateway.stderr.log"))
	if err != nil {
		t.Fatalf("read preserved gateway log: %v", err)
	}
	wantGateway := "boot DATABASE_URL=ecto://vslice_app:[REDACTED]@db.example.com:5432/sr_core_test_selfcheck_edge_record\n"
	if string(gatewayLog) != wantGateway {
		t.Errorf("preserved gateway log = %q, want %q", gatewayLog, wantGateway)
	}
	agentLog, err := os.ReadFile(filepath.Join(out, "agent__agent.stderr.log"))
	if err != nil {
		t.Fatalf("read preserved agent log: %v", err)
	}
	if string(agentLog) != logs["agent/agent.stderr.log"] {
		t.Errorf("preserved agent log = %q, want it unchanged", agentLog)
	}

	// Group A's failure message names the preserved files by this mapping.
	if got := h.preservedLogName(filepath.Join(dir, "core", "serviceradar_core_elx.stderr.log")); got != "core__serviceradar_core_elx.stderr.log" {
		t.Errorf("preservedLogName = %q, want core__serviceradar_core_elx.stderr.log", got)
	}
}

// TestDescribeShardParseErrorWithholdsOutput runs describeShard against a
// stand-in binary whose stdout is a truncated credential document, and checks
// that the parse error reports the failure without echoing that stdout.
func TestDescribeShardParseErrorWithholdsOutput(t *testing.T) {
	// Outside `bazel test` the runfiles library has no tree to find, and an
	// absolute rlocation only resolves to itself once it has one. Under Bazel
	// the real tree is already configured and must be left alone.
	if os.Getenv("TEST_SRCDIR") == "" && os.Getenv("RUNFILES_DIR") == "" && os.Getenv("RUNFILES_MANIFEST_FILE") == "" {
		t.Setenv("RUNFILES_DIR", t.TempDir())
	}

	secret := "fixture-" + selfcheckScrubTarget
	stub := filepath.Join(t.TempDir(), "describe_shard")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' '{\"host\":\"db.example.com\",\"password\":\"" + secret + "\",\"admin_password\":\"" + secret + "-admin\"'\n" +
		"echo 'trailing diagnostic'\n"
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil { //nolint:gosec // test stub must be executable
		t.Fatalf("write describe_shard stub: %v", err)
	}

	orig := describeShardRlocation
	describeShardRlocation = stub
	t.Cleanup(func() { describeShardRlocation = orig })

	_, err := describeShard()
	if err == nil {
		t.Fatal("describeShard accepted a truncated document")
	}
	if !strings.Contains(err.Error(), "parse describe_shard output") {
		t.Fatalf("describeShard failed before reaching its parse step: %v", err)
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("parse error echoed the stub's credentials: %v", err)
	}
}

func writeSelfcheckFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
