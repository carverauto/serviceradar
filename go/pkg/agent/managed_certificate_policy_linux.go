package agent

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/natsutil"
)

const managedCertificatePolicyDomain = "serviceradar.certificate-policy.v1\x00"

type managedCertificatePolicySnapshot struct {
	Version             int                                        `json:"version"`
	GeneratedAt         time.Time                                  `json:"generated_at"`
	ValidUntil          time.Time                                  `json:"valid_until"`
	AllowedFingerprints []string                                   `json:"allowed_fingerprints"`
	NATSPermissions     map[string]natsutil.CertificatePermissions `json:"nats_permissions,omitempty"`
}

type managedCertificatePolicyStore struct {
	path string
	key  ed25519.PublicKey
	now  func() time.Time
}

func runManagedCertificatePolicyUpdater(input io.Reader, output io.Writer) error {
	if err := validatePrivilegedAddonRootOwnership(managedCertificateRoot); err != nil {
		return err
	}
	encodedKey, err := readManagedTrustedFile(ManagedCertificatePolicyKeyPath)
	if err != nil {
		return err
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encodedKey)))
	if err != nil {
		return fmt.Errorf("decode pinned certificate policy key: %w", err)
	}
	if len(key) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: invalid pinned certificate policy key size", errManagedCertificates)
	}
	data, err := io.ReadAll(io.LimitReader(input, 4*1024*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 4*1024*1024 {
		return fmt.Errorf("%w: certificate policy envelope exceeds size limit", errManagedCertificates)
	}
	var envelope ManagedCertificatePolicyEnvelope
	if err := decodeManagedCertificateRequest(data, &envelope); err != nil {
		return err
	}
	// Policy refresh cannot queue behind a slow certificate service restart.
	unlock, err := lockManagedCertificatePath(filepath.Join(managedCertificateRoot, ".policy.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	store := managedCertificatePolicyStore{path: ManagedCertificatePolicyPath, key: ed25519.PublicKey(key), now: time.Now}
	result, err := store.install(envelope)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

func (s managedCertificatePolicyStore) install(envelope ManagedCertificatePolicyEnvelope) (*ManagedCertificatePolicyInstallation, error) {
	message := append([]byte(managedCertificatePolicyDomain), envelope.Payload...)
	if !ed25519.Verify(s.key, message, envelope.Signature) {
		return nil, fmt.Errorf("%w: certificate policy signature is invalid", errManagedCertificates)
	}
	var snapshot managedCertificatePolicySnapshot
	if err := decodeManagedCertificateRequest(envelope.Payload, &snapshot); err != nil {
		return nil, err
	}
	if err := snapshot.validate(s.now()); err != nil {
		return nil, err
	}
	previous, err := os.ReadFile(s.path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		var installed managedCertificatePolicySnapshot
		if err := decodeManagedCertificateRequest(previous, &installed); err != nil {
			return nil, fmt.Errorf("read installed certificate policy: %w", err)
		}
		if snapshot.GeneratedAt.Before(installed.GeneratedAt) || (snapshot.GeneratedAt.Equal(installed.GeneratedAt) && !bytes.Equal(previous, envelope.Payload)) {
			return nil, fmt.Errorf("%w: certificate policy would roll back or replace the same timestamp", errManagedCertificates)
		}
		if bytes.Equal(previous, envelope.Payload) {
			return &ManagedCertificatePolicyInstallation{true, snapshot.GeneratedAt, snapshot.ValidUntil}, nil
		}
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".policy-")
	if err != nil {
		return nil, err
	}
	path := tmp.Name()
	defer func() { _ = os.Remove(path) }()
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	if err := writeAndSyncTempFile(path, envelope.Payload, 0644); err != nil {
		return nil, err
	}
	// A restrictive agent umask must not prevent receiver processes reading policy.
	if err := os.Chmod(path, 0644); err != nil {
		return nil, err
	}
	if err := os.Rename(path, s.path); err != nil {
		return nil, err
	}
	if err := syncCertDir(filepath.Dir(s.path)); err != nil {
		return nil, err
	}
	return &ManagedCertificatePolicyInstallation{true, snapshot.GeneratedAt, snapshot.ValidUntil}, nil
}

func (p managedCertificatePolicySnapshot) validate(now time.Time) error {
	_, generatedOffset := p.GeneratedAt.Zone()
	_, validOffset := p.ValidUntil.Zone()
	if p.Version != 1 || generatedOffset != 0 || validOffset != 0 || p.GeneratedAt.IsZero() || p.ValidUntil.IsZero() || !p.ValidUntil.After(p.GeneratedAt) || p.ValidUntil.Sub(p.GeneratedAt) > 30*time.Second || !p.ValidUntil.After(now) || p.GeneratedAt.After(now.Add(5*time.Second)) {
		return fmt.Errorf("%w: certificate policy version or freshness is invalid", errManagedCertificates)
	}
	allowed := make(map[string]struct{}, len(p.AllowedFingerprints))
	for _, fingerprint := range p.AllowedFingerprints {
		if len(fingerprint) != 64 || strings.ToLower(fingerprint) != fingerprint {
			return fmt.Errorf("%w: certificate policy fingerprint is not lowercase DER SHA256", errManagedCertificates)
		}
		if _, err := hex.DecodeString(fingerprint); err != nil {
			return fmt.Errorf("decode certificate policy fingerprint: %w", err)
		}
		allowed[fingerprint] = struct{}{}
	}
	for fingerprint := range p.NATSPermissions {
		if _, ok := allowed[fingerprint]; !ok {
			return fmt.Errorf("%w: NATS permissions reference a certificate outside the allowed set", errManagedCertificates)
		}
	}
	return nil
}
