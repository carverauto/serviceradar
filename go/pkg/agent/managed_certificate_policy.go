package agent

import (
	"context"
	"time"
)

const (
	managedCertificateRoot          = "/etc/serviceradar/managed-components"
	ManagedCertificatePolicyPath    = managedCertificateRoot + "/policy.json"
	ManagedCertificatePolicyKeyPath = managedCertificateRoot + "/policy.pub"
)

// ManagedCertificatePolicyEnvelope preserves the exact bytes the authority signed.
// JSON encodes these byte slices as base64 for the privileged helper protocol.
type ManagedCertificatePolicyEnvelope struct {
	Payload   []byte `json:"payload"`
	Signature []byte `json:"signature"`
}

// ManagedCertificatePolicyInstallation reports file publication, not receiver enforcement.
type ManagedCertificatePolicyInstallation struct {
	Installed   bool      `json:"installed"`
	GeneratedAt time.Time `json:"generated_at"`
	ValidUntil  time.Time `json:"valid_until"`
}

func InstallManagedCertificatePolicy(ctx context.Context, envelope ManagedCertificatePolicyEnvelope) (*ManagedCertificatePolicyInstallation, error) {
	var result ManagedCertificatePolicyInstallation
	if err := callManagedCertificateUpdater(ctx, "policy", envelope, &result); err != nil {
		return nil, err
	}
	return &result, nil
}
