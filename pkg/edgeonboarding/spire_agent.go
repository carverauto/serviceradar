package edgeonboarding

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultAgentBinaryName = "spire-agent"
)

type embeddedAgentProcess struct {
	cmd        *exec.Cmd
	socketPath string
	logPath    string
}

func (b *Bootstrapper) startEmbeddedSPIREAgent(ctx context.Context, spireDir, workloadSocketPath string) (string, error) {
	if b.downloadResult == nil {
		return "", ErrDownloadResultNotAvailable
	}
	if strings.TrimSpace(b.downloadResult.JoinToken) == "" {
		return "", ErrJoinTokenEmpty
	}

	upstreamAddr, upstreamPort, err := b.getSPIREAddressesForDeployment()
	if err != nil {
		return "", err
	}

	trustDomain := extractTrustDomain(b.pkg.DownstreamSPIFFEID)
	dataDir := filepath.Join(spireDir, "agent-data")
	socketDir := filepath.Dir(workloadSocketPath)
	if err := os.MkdirAll(socketDir, 0755); err != nil {
		return "", fmt.Errorf("create workload socket dir: %w", err)
	}
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return "", fmt.Errorf("create agent data dir: %w", err)
	}

	agentPath := resolveEmbeddedAgentPath()
	if agentPath == "" {
		return "", fmt.Errorf("embedded SPIRE agent binary not found (set SPIRE_AGENT_PATH)")
	}
	if _, err := os.Stat(agentPath); err != nil {
		return "", fmt.Errorf("embedded SPIRE agent binary not found: %w", err)
	}

	configPath := filepath.Join(spireDir, "agent.conf")
	workloadSocket := filepath.Clean(workloadSocketPath)
	config := buildAgentConfig(agentConfigTemplate{
		TrustDomain:     trustDomain,
		UpstreamAddress: upstreamAddr,
		UpstreamPort:    upstreamPort,
		JoinToken:       strings.TrimSpace(b.downloadResult.JoinToken),
		DataDir:         dataDir,
		SocketPath:      workloadSocket,
		TrustBundlePath: filepath.Join(spireDir, "upstream-bundle.pem"),
	})

	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		return "", fmt.Errorf("write embedded agent config: %w", err)
	}

	logPath := filepath.Join(spireDir, "agent.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return "", fmt.Errorf("open agent log: %w", err)
	}

	cmd := exec.CommandContext(ctx, agentPath, "run", "-config", configPath)
	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("start embedded SPIRE agent: %w", err)
	}

	go func() {
		_ = cmd.Wait()
	}()

	if err := waitForSocket(ctx, workloadSocket, 60, time.Second); err != nil {
		return "", fmt.Errorf("wait for workload socket: %w", err)
	}

	b.embeddedAgent = &embeddedAgentProcess{
		cmd:        cmd,
		socketPath: workloadSocket,
		logPath:    logPath,
	}

	return fmt.Sprintf("unix:%s", workloadSocket), nil
}

type agentConfigTemplate struct {
	TrustDomain     string
	UpstreamAddress string
	UpstreamPort    string
	JoinToken       string
	DataDir         string
	SocketPath      string
	TrustBundlePath string
}

func buildAgentConfig(cfg agentConfigTemplate) string {
	return fmt.Sprintf(`# Generated SPIRE agent configuration
agent {
  data_dir = "%s"
  log_level = "INFO"
  server_address = "%s"
  server_port = "%s"
  trust_domain = "%s"
  socket_path = "%s"
  trust_bundle_path = "%s"
  join_token = "%s"
}

plugins {
  KeyManager "disk" {
    plugin_data {
      keys_path = "%s/keys.json"
    }
  }

  NodeAttestor "join_token" {
    plugin_data {}
  }

  WorkloadAttestor "unix" {
    plugin_data {}
  }
}
`, cfg.DataDir, cfg.UpstreamAddress, cfg.UpstreamPort, cfg.TrustDomain, cfg.SocketPath, cfg.TrustBundlePath, cfg.JoinToken, cfg.DataDir)
}

func resolveEmbeddedAgentPath() string {
	if path := strings.TrimSpace(os.Getenv("SPIRE_AGENT_PATH")); path != "" {
		return path
	}
	if path := strings.TrimSpace(os.Getenv("EMBEDDED_SPIRE_AGENT_PATH")); path != "" {
		return path
	}

	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidate := filepath.Join(dir, defaultAgentBinaryName)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}

	// Common install locations
	candidates := []string{
		"/usr/local/bin/spire-agent",
		"/usr/bin/spire-agent",
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}

	return ""
}
