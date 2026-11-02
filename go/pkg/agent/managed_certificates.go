package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/updaterflags"
)

var errManagedCertificates = errors.New("managed certificates")

// ManagedCertificateAssignment is a control-plane assignment, not a command or a
// filesystem layout. RequestID is the stable prepare command ID across retries.
type ManagedCertificateAssignment struct {
	RequestID   string   `json:"request_id"`
	ComponentID string   `json:"component_id"`
	HostAgentID string   `json:"host_agent_id"`
	PartitionID string   `json:"partition_id"`
	Generation  uint64   `json:"generation"`
	Service     string   `json:"service"`
	ServerHosts []string `json:"server_hosts,omitempty"`
}

type ManagedCertificateCSR struct {
	CSRDER []byte `json:"csr_der"`
}

type ManagedCertificatePreparation struct {
	RequestID  string                           `json:"request_id"`
	Generation uint64                           `json:"generation"`
	CSRs       map[string]ManagedCertificateCSR `json:"csrs"`
}

type ManagedCertificateIssued struct {
	CertificatePEM string `json:"certificate_pem"`
	CAChainPEM     string `json:"ca_chain_pem"`
}

type ManagedCertificateInstallRequest struct {
	RequestID    string                              `json:"request_id"`
	Generation   uint64                              `json:"generation"`
	Certificates map[string]ManagedCertificateIssued `json:"certificates"`
}

type ManagedCertificateFiles struct {
	CertificatePath string `json:"certificate_path"`
	KeyPath         string `json:"key_path"`
	CAPath          string `json:"ca_path"`
}

// Activated means the fixed service operation and is-active check succeeded.
// It does not prove that a receiver observed the new certificate. The authority
// must wait for that independent observation before retiring a predecessor.
type ManagedCertificateInstallation struct {
	RequestID       string                             `json:"request_id"`
	Generation      uint64                             `json:"generation"`
	Installed       bool                               `json:"installed"`
	Activated       bool                               `json:"activated"`
	RolledBack      bool                               `json:"rolled_back"`
	ActivationError string                             `json:"activation_error,omitempty"`
	RollbackError   string                             `json:"rollback_error,omitempty"`
	Fingerprints    map[string]string                  `json:"fingerprints"`
	Files           map[string]ManagedCertificateFiles `json:"files"`
	// PolicyPath is the fixed policy location; certificate installation does not publish policy.
	PolicyPath string    `json:"policy_path"`
	RenewAfter time.Time `json:"renew_after"`
}

// PrepareManagedCertificates asks the package-owned privileged helper to create
// and retain private keys. Only CSRs cross back into the agent process.
func PrepareManagedCertificates(ctx context.Context, assignment ManagedCertificateAssignment) (*ManagedCertificatePreparation, error) {
	var result ManagedCertificatePreparation
	if err := callManagedCertificateUpdater(ctx, "prepare", assignment, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func InstallManagedCertificates(ctx context.Context, request ManagedCertificateInstallRequest) (*ManagedCertificateInstallation, error) {
	var result ManagedCertificateInstallation
	if err := callManagedCertificateUpdater(ctx, "install", request, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func callManagedCertificateUpdater(ctx context.Context, action string, request, result any) error {
	path, err := ValidatedPrivilegedAgentUpdaterPath(updaterflags.ManagedCertificates)
	if err != nil {
		return err
	}
	input, err := json.Marshal(request)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, path, "--"+updaterflags.ManagedCertificates, action)
	cmd.Stdin = bytes.NewReader(input)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("managed certificate %s: %w: %s", action, err, truncateAgentUpdaterOutput(stderr.String()))
	}
	if err := json.Unmarshal(output, result); err != nil {
		return fmt.Errorf("decode managed certificate result: %w", err)
	}
	return nil
}

func decodeManagedCertificateRequest(data []byte, request any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(request); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err != nil {
			return err
		}
		return fmt.Errorf("%w: trailing request JSON", errManagedCertificates)
	}
	return nil
}
