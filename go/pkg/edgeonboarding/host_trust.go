package edgeonboarding

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	// hostTrustDirName is the root-controlled enrollment record. It stays beside
	// the agent config and outside the service-owned certificate directory so
	// agent renewal can keep rewriting runtime certificates.
	hostTrustDirName      = "host-trust"
	hostTrustIdentityName = "identity.json"
	hostTrustCAName       = "ca.pem"
	canonicalAgentConfig  = "/etc/serviceradar"
)

type hostTrustIdentity struct {
	AgentID   string `json:"agent_id"`
	Partition string `json:"partition"`
}

// installHostTrust publishes the enrolled agent id, partition and CA chain
// where a privileged helper can trust them. Runtime agent.json and the
// certificate directory stay service-owned so renewal can rewrite them.
func installHostTrust(configDir string, configJSON, caChain []byte) error {
	var parsed hostTrustIdentity
	if err := json.Unmarshal(configJSON, &parsed); err != nil {
		return fmt.Errorf("parse agent identity: %w", err)
	}
	if parsed.AgentID == "" || parsed.Partition == "" || len(caChain) == 0 {
		return nil
	}

	parent, err := os.Lstat(configDir)
	if err != nil {
		return fmt.Errorf("stat host trust parent: %w", err)
	}
	if parent.Mode()&os.ModeSymlink != 0 || !parent.IsDir() {
		return fmt.Errorf("host trust parent %s is not a directory", configDir)
	}

	dir := filepath.Join(configDir, hostTrustDirName)
	if info, err := os.Lstat(dir); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("host trust path %s is not a directory", dir)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat host trust: %w", err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create host trust: %w", err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		return fmt.Errorf("chmod host trust: %w", err)
	}

	identity, err := json.Marshal(hostTrustIdentity{AgentID: parsed.AgentID, Partition: parsed.Partition})
	if err != nil {
		return fmt.Errorf("encode host trust: %w", err)
	}
	identityPath := filepath.Join(dir, hostTrustIdentityName)
	caPath := filepath.Join(dir, hostTrustCAName)
	if err := writeFileAtomic(identityPath, identity, 0o644); err != nil {
		return fmt.Errorf("write host trust identity: %w", err)
	}
	if err := writeFileAtomic(caPath, caChain, 0o644); err != nil {
		return fmt.Errorf("write host trust CA: %w", err)
	}
	if os.Geteuid() != 0 {
		return nil
	}

	paths := []string{dir, identityPath, caPath}
	if configDir == canonicalAgentConfig {
		paths = append([]string{configDir}, paths...)
	}
	for _, path := range paths {
		if err := os.Chown(path, 0, 0); err != nil {
			return fmt.Errorf("chown %s: %w", path, err)
		}
	}
	return nil
}
