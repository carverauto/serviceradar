package edgeonboarding

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var (
	errHostTrustParentNotDirectory = errors.New("host trust parent is not a directory")
	errHostTrustPathNotDirectory   = errors.New("host trust path is not a directory")
	errHostTrustWritableByOthers   = errors.New("host trust path is writable by other users")
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
// where a privileged helper can trust them. The trust directory is made
// private before those bytes are written. Chowning a path afterwards would
// adopt a file another user swapped in. Runtime agent.json and the
// certificate directory stay service-owned so renewal can rewrite them.
func installHostTrust(configDir string, configJSON, caChain []byte) error {
	var parsed hostTrustIdentity
	if err := json.Unmarshal(configJSON, &parsed); err != nil {
		return fmt.Errorf("parse agent identity: %w", err)
	}
	if parsed.AgentID == "" || parsed.Partition == "" || len(caChain) == 0 {
		return nil
	}
	if err := prepareHostTrustDir(configDir); err != nil {
		return err
	}

	identity, err := json.Marshal(hostTrustIdentity{AgentID: parsed.AgentID, Partition: parsed.Partition})
	if err != nil {
		return fmt.Errorf("encode host trust: %w", err)
	}
	dir := filepath.Join(configDir, hostTrustDirName)
	if err := writeFileAtomic(filepath.Join(dir, hostTrustIdentityName), identity, 0o644); err != nil {
		return fmt.Errorf("write host trust identity: %w", err)
	}
	if err := writeFileAtomic(filepath.Join(dir, hostTrustCAName), caChain, 0o644); err != nil {
		return fmt.Errorf("write host trust CA: %w", err)
	}
	return nil
}

func prepareHostTrustDir(configDir string) error {
	if os.Geteuid() == 0 {
		return establishPrivilegedHostTrust(configDir)
	}
	return prepareCallerHostTrustDir(configDir)
}

// prepareCallerHostTrustDir creates a private trust directory for custom
// enrollment. An existing directory other users can write is left untouched
// so its contents cannot be published and later treated as host trust.
func prepareCallerHostTrustDir(configDir string) error {
	parent, err := os.Lstat(configDir)
	if err != nil {
		return fmt.Errorf("stat host trust parent: %w", err)
	}
	if parent.Mode()&os.ModeSymlink != 0 || !parent.IsDir() {
		return fmt.Errorf("%w: %s", errHostTrustParentNotDirectory, configDir)
	}

	dir := filepath.Join(configDir, hostTrustDirName)
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) {
		if mkErr := os.Mkdir(dir, 0o755); mkErr != nil {
			if !os.IsExist(mkErr) {
				return fmt.Errorf("create host trust: %w", mkErr)
			}
		} else if chmodErr := os.Chmod(dir, 0o755); chmodErr != nil {
			return fmt.Errorf("chmod host trust: %w", chmodErr)
		} else {
			return nil
		}
		info, err = os.Lstat(dir)
	}
	if err != nil {
		return fmt.Errorf("stat host trust: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("%w: %s", errHostTrustPathNotDirectory, dir)
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("%w: %s", errHostTrustWritableByOthers, dir)
	}
	return nil
}
