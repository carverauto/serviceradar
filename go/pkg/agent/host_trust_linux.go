//go:build linux

package agent

import (
	"bytes"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const managedHostConfigRoot = "/etc/serviceradar"

// loadManagedHostTrust reads the root-owned enrollment identity and CA.
// The service-owned agent.json and certificate directory are not trust inputs:
// the agent rewrites runtime certificates there during renewal.
func loadManagedHostTrust(root string) (ServerConfig, []byte, error) {
	var binding ServerConfig
	if err := validatePrivilegedAddonRootOwnership(root); err != nil {
		return binding, nil, err
	}
	trustDir := filepath.Join(root, "host-trust")
	if err := validatePrivilegedAddonRootOwnership(trustDir); err != nil {
		return binding, nil, err
	}
	identity, err := readManagedTrustedFile(filepath.Join(trustDir, "identity.json"))
	if err != nil {
		return binding, nil, err
	}
	parsed, err := parseHostTrustIdentity(identity)
	if err != nil {
		return binding, nil, err
	}
	roots, err := readManagedTrustedFile(filepath.Join(trustDir, "ca.pem"))
	if err != nil {
		return binding, nil, err
	}
	if !pemHasCertificate(roots) {
		return binding, nil, fmt.Errorf("%w: installed deployment CA is invalid", errManagedCertificates)
	}
	binding.AgentID = parsed.AgentID
	binding.Partition = parsed.Partition
	// Runtime credentials may renew, but their paths and trust roots are fixed
	// by packaged enrollment rather than the service-writable agent config.
	binding.GatewaySecurity = &models.SecurityConfig{
		Mode: models.SecurityModeMTLS,
		TLS: models.TLSConfig{
			CertFile: filepath.Join(root, "certs", "component.pem"),
			KeyFile:  filepath.Join(root, "certs", "component-key.pem"),
			CAFile:   filepath.Join(trustDir, "ca.pem"),
		},
	}
	return binding, roots, nil
}

func parseHostTrustIdentity(identity []byte) (hostTrustIdentity, error) {
	dec := json.NewDecoder(bytes.NewReader(identity))
	dec.DisallowUnknownFields()
	var parsed hostTrustIdentity
	if err := dec.Decode(&parsed); err != nil {
		return parsed, fmt.Errorf("read installed agent identity: %w", err)
	}
	if dec.More() {
		return parsed, fmt.Errorf("%w: installed agent identity has trailing data", errManagedCertificates)
	}
	if parsed.AgentID == "" || parsed.Partition == "" {
		return parsed, fmt.Errorf("%w: installed agent identity or partition is missing", errManagedCertificates)
	}
	return parsed, nil
}

type hostTrustIdentity struct {
	AgentID   string `json:"agent_id"`
	Partition string `json:"partition"`
}

func pemHasCertificate(encoded []byte) bool {
	rest := encoded
	for len(rest) > 0 {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return false
		}
		if block.Type == "CERTIFICATE" && len(block.Bytes) > 0 {
			return true
		}
	}
	return false
}
