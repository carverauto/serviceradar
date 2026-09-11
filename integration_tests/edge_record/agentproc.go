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
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// agentConfigDocument mirrors the subset of go/pkg/agent's ServerConfig
// (types.go) and go/pkg/models' SecurityConfig/TLSConfig (grpc.go) this
// harness needs. Field tags match those structs exactly -- json.Unmarshal
// into the real types silently zero-values a mismatched key instead of
// failing, so these MUST stay byte-for-byte identical to the production
// struct tags.
type agentConfigDocument struct {
	AgentID          string                    `json:"agent_id"`
	CheckersDir      string                    `json:"checkers_dir"`
	GatewayAddr      string                    `json:"gateway_addr,omitempty"`
	GatewaySecurity  *agentSecurityDocument    `json:"gateway_security,omitempty"`
	EdgeRecordSender *edgeRecordSenderDocument `json:"edge_record_sender,omitempty"`
}

// agentSecurityDocument mirrors go/pkg/models.SecurityConfig.
type agentSecurityDocument struct {
	Mode       string           `json:"mode"`
	CertDir    string           `json:"cert_dir"`
	ServerName string           `json:"server_name,omitempty"`
	Role       string           `json:"role"`
	TLS        agentTLSDocument `json:"tls"`
}

// agentTLSDocument mirrors go/pkg/models.TLSConfig.
type agentTLSDocument struct {
	CertFile string `json:"cert_file"`
	KeyFile  string `json:"key_file"`
	CAFile   string `json:"ca_file"`
}

// edgeRecordSenderDocument mirrors go/pkg/agent.EdgeRecordSenderConfig.
type edgeRecordSenderDocument struct {
	Enabled      bool                   `json:"enabled"`
	SpoolDir     string                 `json:"spool_dir"`
	GatewayAddr  string                 `json:"gateway_addr,omitempty"`
	Security     *agentSecurityDocument `json:"security,omitempty"`
	PollInterval string                 `json:"poll_interval,omitempty"`
}

// AgentProcess is one running go/cmd/agent process, started in the real
// production push-mode entry point (go/cmd/agent/main.go's run() always
// calls runPushMode; there is no separate "test mode").
type AgentProcess struct {
	SpoolDir   string
	ConfigPath string

	cmd        *exec.Cmd
	stdoutPath string
	stderrPath string
}

// StartAgent writes a JSON config file for go/cmd/agent under workDir with
// EdgeRecordSender enabled, then execs agentBinaryPath --config <path> as a
// background process. gatewayGRPCAddr is "host:port" for the gateway's real
// gRPC listener; gatewayServerName is the TLS ServerName to verify against
// (must match a SAN on the gateway's server certificate); caCertPath/
// agentCertPath/agentKeyPath identify the agent's mTLS client identity
// (component_type=agent -- see certs.go).
//
// The caller is responsible for separately opening the SAME spool directory
// with go/pkg/edge/spool.Open and Append-ing fixture records -- independent
// of this process's lifecycle, since the real sender (go/pkg/edge/sender,
// wired in from go/cmd/agent/edge_record_sender.go) polls the spool
// directory on its own PollInterval cadence rather than being told about new
// entries directly.
func StartAgent(
	agentBinaryPath, workDir, gatewayGRPCAddr, gatewayServerName string,
	caCertPath, agentCertPath, agentKeyPath string,
	pollInterval time.Duration,
) (*AgentProcess, error) {
	spoolDir := filepath.Join(workDir, "spool")
	checkersDir := filepath.Join(workDir, "checkers")
	for _, d := range []string{spoolDir, checkersDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("verticalslice: mkdir %s: %w", d, err)
		}
	}

	security := &agentSecurityDocument{
		Mode:       "mtls",
		CertDir:    "",
		ServerName: gatewayServerName,
		Role:       "agent",
		TLS: agentTLSDocument{
			CertFile: agentCertPath,
			KeyFile:  agentKeyPath,
			CAFile:   caCertPath,
		},
	}

	doc := agentConfigDocument{
		AgentID:         "vslice-agent",
		CheckersDir:     checkersDir,
		GatewayAddr:     gatewayGRPCAddr,
		GatewaySecurity: security,
		EdgeRecordSender: &edgeRecordSenderDocument{
			Enabled:      true,
			SpoolDir:     spoolDir,
			GatewayAddr:  gatewayGRPCAddr,
			Security:     security,
			PollInterval: pollInterval.String(),
		},
	}

	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("verticalslice: marshal agent config: %w", err)
	}

	configPath := filepath.Join(workDir, "agent.json")
	if err := os.WriteFile(configPath, data, 0o600); err != nil {
		return nil, fmt.Errorf("verticalslice: write agent config: %w", err)
	}

	stdoutPath := filepath.Join(workDir, "agent.stdout.log")
	stderrPath := filepath.Join(workDir, "agent.stderr.log")
	stdoutFile, err := os.Create(stdoutPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create agent stdout log: %w", err)
	}
	stderrFile, err := os.Create(stderrPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: create agent stderr log: %w", err)
	}

	cmd := exec.Command(agentBinaryPath, "--config", configPath)
	cmd.Stdout = stdoutFile
	cmd.Stderr = stderrFile
	cmd.Dir = workDir

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("verticalslice: start agent: %w", err)
	}

	return &AgentProcess{
		SpoolDir:   spoolDir,
		ConfigPath: configPath,
		cmd:        cmd,
		stdoutPath: stdoutPath,
		stderrPath: stderrPath,
	}, nil
}

// Stop kills the agent process. go/cmd/agent's push-mode loop has no
// documented graceful RPC shutdown reachable from outside the process (it
// runs until its context is canceled by an OS signal); sending SIGTERM lets
// its normal signal handling (if any) run before a hard kill.
func (p *AgentProcess) Stop() {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return
	}

	_ = p.cmd.Process.Signal(os.Interrupt)

	done := make(chan struct{})
	go func() {
		_ = p.cmd.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = p.cmd.Process.Kill()
	}
}
