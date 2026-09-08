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

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAgentVersionCLI(t *testing.T) {
	t.Parallel()

	binary := os.Getenv("SERVICERADAR_TEST_AGENT_BINARY")
	if binary == "" {
		if os.Getenv("TEST_SRCDIR") != "" {
			t.Fatal("Bazel did not supply the declared agent executable")
		}
		t.Skip("the executable is supplied by the Bazel agent_test target")
	}
	if !filepath.IsAbs(binary) {
		binary = filepath.Join(os.Getenv("TEST_SRCDIR"), os.Getenv("TEST_WORKSPACE"), binary)
	}
	version := os.Getenv("SERVICERADAR_TEST_AGENT_VERSION")
	if version == "" {
		t.Fatal("expected embedded version is missing")
	}
	configPath := writeAgentConfig(t, "{")

	for _, args := range [][]string{{"--version"}, {"--config", configPath, "--version"}} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			t.Parallel()

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, args...)
			cmd.Dir = t.TempDir()
			cmd.Env = []string{"SR_ALLOW_EMBEDDED_DEFAULT_CONFIG=false"}
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			if err := cmd.Run(); err != nil {
				t.Fatalf("version command failed: %v; stderr=%q", err, stderr.String())
			}
			if got := stdout.String(); got != version+"\n" {
				t.Fatalf("stdout = %q, want exact embedded version %q", got, version+"\n")
			}
			if got := stderr.String(); got != "" {
				t.Fatalf("unexpected startup output: %q", got)
			}
		})
	}

	t.Run("normal startup still validates configuration", func(t *testing.T) {
		t.Parallel()

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, binary, "--config", configPath)
		cmd.Dir = t.TempDir()
		cmd.Env = []string{"SR_ALLOW_EMBEDDED_DEFAULT_CONFIG=false"}
		output, err := cmd.CombinedOutput()
		if err == nil || ctx.Err() != nil || !strings.Contains(string(output), "failed to parse config") {
			t.Fatalf("normal startup should reject invalid configuration promptly: err=%v output=%q", err, output)
		}
	})
}

func TestLoadConfigRejectsTrailingData(t *testing.T) {
	t.Parallel()

	path := writeAgentConfig(t, `{"agent_id":"agent-test","checkers_dir":"/tmp/checkers"} {}`)

	_, err := loadConfig(path)
	if !errors.Is(err, errConfigTrailingData) {
		t.Fatalf("error = %v, want %v", err, errConfigTrailingData)
	}
}

func TestLoadConfigAcceptsDeprecatedRemoteAccessKnownHostsFile(t *testing.T) {
	t.Parallel()

	path := writeAgentConfig(t, `{
		"agent_id": "k8s-agent",
		"checkers_dir": "/var/lib/serviceradar/checkers",
		"gateway_addr": "serviceradar-agent-gateway:50052",
		"remote_access_known_hosts_file": "/var/lib/serviceradar/known_hosts"
	}`)

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig rejected deprecated remote access key: %v", err)
	}

	if cfg.AgentID != "k8s-agent" {
		t.Fatalf("AgentID = %q, want k8s-agent", cfg.AgentID)
	}
}

func TestLoadConfigIgnoresFutureUnknownFields(t *testing.T) {
	t.Parallel()

	path := writeAgentConfig(t, `{
		"agent_id": "k8s-agent",
		"checkers_dir": "/var/lib/serviceradar/checkers",
		"future_chart_field": true
	}`)

	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatalf("loadConfig rejected future unknown field: %v", err)
	}

	if cfg.AgentID != "k8s-agent" {
		t.Fatalf("AgentID = %q, want k8s-agent", cfg.AgentID)
	}
}

func writeAgentConfig(t *testing.T, content string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "agent.json")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	return path
}
