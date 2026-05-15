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
	"errors"
	"os"
	"path/filepath"
	"testing"
)

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
