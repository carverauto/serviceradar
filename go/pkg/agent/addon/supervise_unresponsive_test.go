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

package addon

import (
	"context"
	"errors"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	goplugin "github.com/hashicorp/go-plugin"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

// probeScriptAddon answers Health from a script: the first failFirst probes fail
// the way a live process with a dead gRPC server does, the rest succeed.
type probeScriptAddon struct {
	failFirst int64
	failAll   bool
	probes    atomic.Int64
}

func (a *probeScriptAddon) Info(context.Context) (coreaddon.Info, error) {
	return coreaddon.Info{ID: "sample"}, nil
}

func (a *probeScriptAddon) Configure(context.Context, []byte) (coreaddon.ConfigureResult, error) {
	return coreaddon.ConfigureResult{Accepted: true}, nil
}

func (a *probeScriptAddon) Health(context.Context) (coreaddon.Health, error) {
	n := a.probes.Add(1)
	if a.failAll || n <= a.failFirst {
		return coreaddon.Health{}, status.Error(codes.Unavailable,
			"connection error: error reading server preface: use of closed network connection")
	}
	return coreaddon.Health{Status: coreaddon.HealthHealthy}, nil
}

// neverStartedClient stands in for a plugin process that is still alive: its
// Exited() is false for as long as the test runs.
func neverStartedClient() *goplugin.Client {
	return goplugin.NewClient(&goplugin.ClientConfig{
		HandshakeConfig:  coreaddon.Handshake,
		Plugins:          coreaddon.ClientPluginSet(),
		AllowedProtocols: []goplugin.Protocol{goplugin.ProtocolGRPC},
		Cmd:              exec.CommandContext(context.Background(), "true"),
	})
}

// An add-on whose process is alive but whose RPC server is gone must be given up
// on. supervise only returned when the process exited, so a SIGTERM that shut
// the server down without ending the process left it reported unhealthy
// forever: the runner never restarted it, and a later version change could not
// replace it either because nothing ever tore the runner down.
func TestSuperviseGivesUpOnAnAddonWhoseRPCServerIsGone(t *testing.T) {
	cfg := testConfig(t)
	cfg.HealthInterval = 5 * time.Millisecond
	cfg.UnhealthyThreshold = 3
	cfg.UnresponsiveRestartThreshold = 6
	r := newRunner(Spec{ID: "sample"}, cfg)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	relay := newRelayLifecycle(ctx, "sample", nil, func(context.Context, string, coreaddon.OtlpRelayClient) {})

	addon := &probeScriptAddon{failAll: true}
	err := r.supervise(ctx, neverStartedClient(), addon, 4242, relay)

	if !errors.Is(err, ErrAddonUnresponsive) {
		t.Fatalf("supervise must return ErrAddonUnresponsive for a dead RPC server, got %v after %d probes", err, addon.probes.Load())
	}
	if got := addon.probes.Load(); got != int64(cfg.UnresponsiveRestartThreshold) {
		t.Fatalf("supervise should give up after exactly %d failed probes, took %d", cfg.UnresponsiveRestartThreshold, got)
	}
	if got := r.snapshot().State; got != StateUnhealthy {
		t.Fatalf("the add-on must be reported unhealthy before it is restarted, got %q", got)
	}
}

// A few failed probes followed by a good one are a slow add-on, not a dead one:
// the count resets and supervision carries on.
func TestSuperviseKeepsAnAddonThatRecoversBeforeTheRestartThreshold(t *testing.T) {
	cfg := testConfig(t)
	cfg.HealthInterval = 5 * time.Millisecond
	cfg.UnhealthyThreshold = 3
	cfg.UnresponsiveRestartThreshold = 6
	r := newRunner(Spec{ID: "sample"}, cfg)

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	relay := newRelayLifecycle(ctx, "sample", nil, func(context.Context, string, coreaddon.OtlpRelayClient) {})

	addon := &probeScriptAddon{failFirst: 5}
	if err := r.supervise(ctx, neverStartedClient(), addon, 4242, relay); err != nil {
		t.Fatalf("an add-on that answers again before the threshold must not be restarted, got %v", err)
	}
	if got := r.snapshot().State; got != StateRunning {
		t.Fatalf("a recovered add-on must report running, got %q", got)
	}
}
