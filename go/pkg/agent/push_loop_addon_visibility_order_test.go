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

package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
)

type recordingAddonManager struct {
	applied []agentaddon.Spec
}

func (m *recordingAddonManager) Apply(_ context.Context, specs []agentaddon.Spec) error {
	m.applied = append([]agentaddon.Spec(nil), specs...)
	return nil
}

func (m *recordingAddonManager) SetCredentialResolver(coreaddon.CredentialResolver) {}

func (m *recordingAddonManager) Status() []agentaddon.Status {
	return nil
}

func (m *recordingAddonManager) RunCommand(context.Context, agentaddon.CommandInvocation) (coreaddon.CommandResult, error) {
	return coreaddon.CommandResult{}, agentaddon.ErrAddonCommandUnavailable
}

func (m *recordingAddonManager) PublishMetricFeed(string, []byte) int {
	return 0
}

func (m *recordingAddonManager) Stop(context.Context) error {
	return nil
}

func TestApplyAddonAssignmentsSkipsKubernetesAgent(t *testing.T) {
	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		config: &ServerConfig{
			AgentID: kubernetesAgentID,
		},
		addonManager: addons,
	}, nil, 30*time.Second, logger.NewTestLogger())

	disposition, err := pl.applyAddonAssignments(context.Background(), []*proto.AddonAssignmentConfig{
		{
			AddonId:     "netprobe",
			Enabled:     true,
			Delivery:    addonDeliveryPushedArtifact,
			Supervision: addonSupervisionAgentSidecar,
		},
	})
	if disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("expected Kubernetes add-on assignments to be acknowledged, got %v (%v)", disposition, err)
	}
	if len(addons.applied) != 0 {
		t.Fatalf("expected no add-on manager apply for Kubernetes agent, got %#v", addons.applied)
	}
}

func TestApplyConfigResponseAppliesLocalAddonsWithVisibilityConfig(t *testing.T) {
	dir := t.TempDir()
	override := `{
	  "addons": [
	    {
	      "addon_id": "powerdns",
	      "version": "0.1.0",
	      "enabled": true,
	      "binary_path": "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon",
	      "delivery": "os_package",
	      "supervision": "agent_sidecar",
	      "capabilities": ["native-telemetry:v1", "dns-activity", "powerdns-rpz"],
	      "config_json": {"listen_addr": "127.0.0.1:6000"}
	    }
	  ]
	}`
	if err := os.WriteFile(filepath.Join(dir, "addons.local.json"), []byte(override), 0o600); err != nil {
		t.Fatalf("write local add-on override: %v", err)
	}

	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	sidecarManager := &recordingSidecarLifecycleManager{started: true, attach: true}

	addons := &recordingAddonManager{}
	pl := NewPushLoop(&Server{
		configDir:       dir,
		addonManager:    addons,
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  sidecarManager,
		sidecarStatus:   sidecarManager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	pl.setConfigVersion("old-version")

	ok := pl.applyConfigResponse(context.Background(), &proto.AgentConfigResponse{
		ConfigVersion:    "new-version",
		VisibilityConfig: &proto.VisibilityConfig{Enabled: true},
	}, "poll")

	if !ok {
		t.Fatal("applyConfigResponse() = false, want true")
	}
	if got := pl.getConfigVersion(); got != "new-version" {
		t.Fatalf("config version = %q, want new-version", got)
	}
	if len(addons.applied) != 1 {
		t.Fatalf("applied add-on specs = %d, want 1", len(addons.applied))
	}
	if !sidecarManager.stopped {
		t.Fatal("expected visibility config without a netprobe assignment to stop the attach manager")
	}
	if got := addons.applied[0].ID; got != "powerdns" {
		t.Fatalf("applied add-on ID = %q, want powerdns", got)
	}
	if got := addons.applied[0].BinaryPath; got != "/usr/local/lib/serviceradar/bin/serviceradar-powerdns-addon" {
		t.Fatalf("applied binary path = %q", got)
	}
}
