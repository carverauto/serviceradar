/*
 * Copyright 2025 Carver Automation Corporation.
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
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	maxRenewalScheduleJitter = 6 * time.Hour
	unknownCertificateField  = "unknown"
)

var (
	errRenewalResponseEmpty      = errors.New("certificate renewal response is empty")
	errRenewalInvalidCAChain     = errors.New("certificate renewal CA chain is invalid")
	errRenewalCertAlreadyExpired = errors.New("renewed certificate is already expired")
	errRenewalCertRevoked        = errors.New("local mTLS client certificate revoked; re-enroll required")
)

// CertificateRenewalGateway defines the gateway client operations required by CertRenewalManager.
type CertificateRenewalGateway interface {
	RenewCertificate(ctx context.Context, req *proto.CertificateRenewalRequest) (*proto.CertificateRenewalResponse, error)
	MTLSProvider() *srgrpc.MTLSProvider
	ReloadAndReconnect(ctx context.Context) error
}

// CertRenewalWriteHooks allows tests to inject faults at exact points in the atomic persistence sequence.
type CertRenewalWriteHooks struct {
	BeforeBundleRename func(certDir string) error
	AfterBundleRename  func(certDir string) error
	AfterKeyRename     func(certDir string) error
}

// CertRenewalManager schedules and executes proactive mTLS client certificate renewal.
type CertRenewalManager struct {
	gateway         CertificateRenewalGateway
	provider        *srgrpc.MTLSProvider
	onRenewed       func(ctx context.Context)
	nowFunc         func() time.Time
	jitterFunc      func(max time.Duration) time.Duration
	backoffSchedule []time.Duration
	keyGenFunc      func() (crypto.Signer, []byte, error)
	csrBuilderFunc  func(leaf *x509.Certificate, signer crypto.Signer) ([]byte, error)
	writeHooks      CertRenewalWriteHooks
	logger          logger.Logger
}

// NewCertRenewalManager creates a new CertRenewalManager.
func NewCertRenewalManager(gateway CertificateRenewalGateway, log logger.Logger) *CertRenewalManager {
	return &CertRenewalManager{
		gateway:        gateway,
		nowFunc:        time.Now,
		jitterFunc:     cryptoRandomJitter,
		keyGenFunc:     generateECDSAP256Key,
		csrBuilderFunc: buildRenewalCSRFromLeaf,
		logger:         log,
	}
}

// RenewalTargetTime returns the 2/3-lifetime renewal timestamp with bounded jitter.
func RenewalTargetTime(notBefore, notAfter time.Time, jitter func(max time.Duration) time.Duration) time.Time {
	lifetime := notAfter.Sub(notBefore)
	if lifetime <= 0 {
		return notAfter
	}

	target := notBefore.Add((lifetime * 2) / 3)
	maxJitter := min(lifetime/20, maxRenewalScheduleJitter)
	if jitter != nil && maxJitter > 0 {
		j := jitter(maxJitter)
		if j > 0 && target.Add(j).Before(notAfter) {
			target = target.Add(j)
		}
	}

	return target
}

func (m *CertRenewalManager) now() time.Time {
	if m.nowFunc != nil {
		return m.nowFunc()
	}

	return time.Now()
}

func (m *CertRenewalManager) resolveProvider() *srgrpc.MTLSProvider {
	if m.provider != nil {
		return m.provider
	}
	if m.gateway != nil {
		return m.gateway.MTLSProvider()
	}

	return nil
}

// NextRenewalDelay returns the duration until the next scheduled renewal for the currently loaded leaf certificate.
func (m *CertRenewalManager) NextRenewalDelay() (time.Duration, *x509.Certificate, error) {
	provider := m.resolveProvider()
	if provider == nil {
		return 0, nil, nil
	}

	leaf := provider.ClientLeaf()
	if leaf == nil {
		return 0, nil, nil
	}

	now := m.now()
	if !now.Before(leaf.NotAfter) {
		return 0, leaf, provider.CheckClientCertificateExpiry()
	}

	target := RenewalTargetTime(leaf.NotBefore, leaf.NotAfter, m.jitterFunc)
	if !now.Before(target) {
		return 0, leaf, nil
	}

	return target.Sub(now), leaf, nil
}

// Run executes the certificate renewal loop until ctx is cancelled or the local certificate expires without renewal.
func (m *CertRenewalManager) Run(ctx context.Context) error {
	retryAttempt := 0

	for {
		provider := m.resolveProvider()
		if provider == nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
				continue
			}
		}

		delay, leaf, err := m.NextRenewalDelay()
		if err != nil {
			return err
		}
		if leaf == nil {
			return nil
		}

		if retryAttempt > 0 {
			delay = m.backoffDelay(retryAttempt - 1)
			if now := m.now(); !now.Add(delay).Before(leaf.NotAfter) {
				remaining := leaf.NotAfter.Sub(now)
				if remaining <= 0 {
					return provider.CheckClientCertificateExpiry()
				}
				delay = remaining / 2
			}
		}

		if delay > 0 {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}

		if err := m.RenewOnce(ctx); err != nil {
			if errors.Is(err, srgrpc.ErrClientCertificateExpired) || errors.Is(err, errRenewalCertRevoked) {
				return err
			}
			retryAttempt++
			if m.logger != nil {
				m.logger.Warn().
					Err(err).
					Int("attempt", retryAttempt).
					Msg("Agent mTLS certificate renewal attempt failed; will retry with backoff")
			}
			continue
		}

		retryAttempt = 0
	}
}

func (m *CertRenewalManager) backoffDelay(index int) time.Duration {
	schedule := m.backoffSchedule
	if len(schedule) == 0 {
		schedule = []time.Duration{1 * time.Minute, 2 * time.Minute, 5 * time.Minute, 15 * time.Minute, 1 * time.Hour}
	}
	if index < 0 {
		index = 0
	}
	if index >= len(schedule) {
		index = len(schedule) - 1
	}

	return schedule[index]
}

// RenewOnce performs one full certificate renewal cycle: pre-expiry check, key+CSR generation,
// RenewCertificate RPC, response validation, crash-safe atomic disk write, MTLSProvider hot-reload,
// and gateway reconnect with Hello.
func (m *CertRenewalManager) RenewOnce(ctx context.Context) error {
	provider := m.resolveProvider()
	if provider == nil {
		return nil
	}

	leaf := provider.ClientLeaf()
	if leaf == nil {
		return nil
	}

	if err := provider.CheckClientCertificateExpiry(); err != nil {
		return err
	}
	if !m.now().Before(leaf.NotAfter) {
		return m.logExpiredAndWrap(leaf)
	}

	keyGen := m.keyGenFunc
	if keyGen == nil {
		keyGen = generateECDSAP256Key
	}
	signer, keyPEM, err := keyGen()
	if err != nil {
		return fmt.Errorf("failed to generate renewal private key: %w", err)
	}

	csrBuilder := m.csrBuilderFunc
	if csrBuilder == nil {
		csrBuilder = buildRenewalCSRFromLeaf
	}
	csrDER, err := csrBuilder(leaf, signer)
	if err != nil {
		return fmt.Errorf("failed to build renewal CSR: %w", err)
	}

	resp, err := m.gateway.RenewCertificate(ctx, &proto.CertificateRenewalRequest{
		CsrDer: csrDER,
	})
	if err != nil {
		return m.classifyRenewRPCError(err, leaf)
	}

	certPath, keyPath, caPath := provider.CertPaths()
	caChainPEM, err := validateRenewalResponse(resp, keyPEM, caPath, m.now())
	if err != nil {
		return err
	}

	if err := WriteRenewedCertificateAtomically(certPath, keyPath, caChainPEM, resp.CertificatePem, keyPEM, m.writeHooks); err != nil {
		return fmt.Errorf("failed to persist renewed certificate: %w", err)
	}

	if err := m.gateway.ReloadAndReconnect(ctx); err != nil {
		return fmt.Errorf("failed to reload mTLS credentials and reconnect gateway: %w", err)
	}

	if m.onRenewed != nil {
		m.onRenewed(ctx)
	}

	if m.logger != nil {
		m.logger.Info().
			Str("serial", resp.SerialNumber).
			Str("fingerprint", resp.CertificateFingerprint).
			Int64("notAfterUnix", resp.NotAfterUnix).
			Msg("Successfully renewed and hot-reloaded agent mTLS certificate")
	}

	return nil
}

func (m *CertRenewalManager) classifyRenewRPCError(err error, leaf *x509.Certificate) error {
	st, ok := status.FromError(err)
	if !ok {
		st, ok = status.FromError(errors.Unwrap(err))
	}
	if ok && st.Code() == codes.PermissionDenied {
		msg := st.Message()
		switch {
		case strings.Contains(msg, "certificate_expired"):
			return m.logExpiredAndWrap(leaf)
		case strings.Contains(msg, "certificate_revoked"):
			if m.logger != nil {
				m.logger.Error().
					Str("serial", formatLeafSerial(leaf)).
					Msg("local mTLS client certificate revoked; re-enroll required")
			}
			return fmt.Errorf("%w: %w", errRenewalCertRevoked, err)
		}
	}

	return err
}

func (m *CertRenewalManager) logExpiredAndWrap(leaf *x509.Certificate) error {
	notAfterStr := unknownCertificateField
	if leaf != nil {
		notAfterStr = leaf.NotAfter.UTC().Format(time.RFC3339)
	}
	serialStr := formatLeafSerial(leaf)
	msg := fmt.Sprintf("local mTLS client certificate expired (notAfter=%s, serial=%s); re-enroll required", notAfterStr, serialStr)
	if m.logger != nil {
		m.logger.Error().
			Str("notAfter", notAfterStr).
			Str("serial", serialStr).
			Msg(msg)
	}

	return fmt.Errorf("%w: %s", srgrpc.ErrClientCertificateExpired, msg)
}

func formatLeafSerial(leaf *x509.Certificate) string {
	if leaf == nil || leaf.SerialNumber == nil {
		return unknownCertificateField
	}

	return strings.ToLower(hex.EncodeToString(leaf.SerialNumber.Bytes()))
}

func validateRenewalResponse(resp *proto.CertificateRenewalResponse, keyPEM []byte, caPath string, now time.Time) ([]byte, error) {
	if resp == nil || len(resp.CertificatePem) == 0 {
		return nil, errRenewalResponseEmpty
	}

	pair, err := tls.X509KeyPair(resp.CertificatePem, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("renewed certificate does not match generated private key: %w", err)
	}

	if len(pair.Certificate) == 0 {
		return nil, errRenewalResponseEmpty
	}

	newLeaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, fmt.Errorf("failed to parse renewed leaf certificate: %w", err)
	}

	if !newLeaf.NotAfter.After(now) {
		return nil, errRenewalCertAlreadyExpired
	}

	caChainPEM := resp.CaChainPem
	if len(caChainPEM) == 0 && caPath != "" {
		caChainPEM, err = os.ReadFile(caPath)
		if err != nil {
			return nil, fmt.Errorf("failed to read CA chain for renewal verification: %w", err)
		}
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caChainPEM) {
		return nil, errRenewalInvalidCAChain
	}

	verifyTime := now
	if verifyTime.Before(newLeaf.NotBefore) {
		verifyTime = newLeaf.NotBefore
	}

	if _, err := newLeaf.Verify(x509.VerifyOptions{
		Roots:       caPool,
		CurrentTime: verifyTime,
		KeyUsages:   []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("renewed certificate failed CA chain verification: %w", err)
	}

	return caChainPEM, nil
}

// WriteRenewedCertificateAtomically persists the renewed certificate and private key using
// the crash-safe two-phase bundle commit protocol:
//  1. Write and fsync .component-key.pem.tmp (0600), .component.pem.tmp (0644), and .component-bundle.pem.tmp (0600).
//  2. Atomically rename .component-bundle.pem.tmp -> component-bundle.pem and fsync the directory.
//  3. Atomically rename .component-key.pem.tmp -> component-key.pem and .component.pem.tmp -> component.pem, then fsync the directory.
func WriteRenewedCertificateAtomically(
	certPath string,
	keyPath string,
	caChainPEM []byte,
	certPEM []byte,
	keyPEM []byte,
	hooks CertRenewalWriteHooks,
) error {
	certDir := filepath.Dir(certPath)
	bundlePath := filepath.Join(certDir, "component-bundle.pem")

	keyTmp := filepath.Join(filepath.Dir(keyPath), "."+filepath.Base(keyPath)+".tmp")
	certTmp := filepath.Join(certDir, "."+filepath.Base(certPath)+".tmp")
	bundleTmp := filepath.Join(certDir, ".component-bundle.pem.tmp")

	bundlePEM := formatComponentBundlePEM(certPEM, keyPEM, caChainPEM)

	if err := writeAndSyncTempFile(keyTmp, keyPEM, 0o600); err != nil {
		return err
	}
	if err := writeAndSyncTempFile(certTmp, certPEM, 0o644); err != nil {
		_ = os.Remove(keyTmp)
		return err
	}
	if err := writeAndSyncTempFile(bundleTmp, bundlePEM, 0o600); err != nil {
		_ = os.Remove(keyTmp)
		_ = os.Remove(certTmp)
		return err
	}

	if hooks.BeforeBundleRename != nil {
		if err := hooks.BeforeBundleRename(certDir); err != nil {
			return err
		}
	}

	if err := os.Rename(bundleTmp, bundlePath); err != nil {
		return err
	}
	if err := syncCertDir(certDir); err != nil {
		return err
	}

	if hooks.AfterBundleRename != nil {
		if err := hooks.AfterBundleRename(certDir); err != nil {
			return err
		}
	}

	if err := os.Rename(keyTmp, keyPath); err != nil {
		return err
	}

	if hooks.AfterKeyRename != nil {
		if err := hooks.AfterKeyRename(certDir); err != nil {
			return err
		}
	}

	if err := os.Rename(certTmp, certPath); err != nil {
		return err
	}

	return syncCertDir(certDir)
}

func formatComponentBundlePEM(certPEM, keyPEM, caChainPEM []byte) []byte {
	var b strings.Builder
	b.WriteString("# Component Certificate\n")
	b.WriteString(strings.TrimSpace(string(certPEM)))
	b.WriteString("\n# Component Private Key\n")
	b.WriteString(strings.TrimSpace(string(keyPEM)))
	if len(strings.TrimSpace(string(caChainPEM))) > 0 {
		b.WriteString("\n# CA Chain\n")
		b.WriteString(strings.TrimSpace(string(caChainPEM)))
	}
	b.WriteString("\n")
	return []byte(b.String())
}

func writeAndSyncTempFile(tmpPath string, data []byte, perm os.FileMode) error {
	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}

	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return err
	}

	if err := f.Chmod(perm); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return err
	}

	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return err
	}

	if err := f.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}

	return nil
}

func syncCertDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer func() {
		_ = d.Close()
	}()

	return d.Sync()
}

func generateECDSAP256Key() (crypto.Signer, []byte, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	pkcs8Bytes, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: pkcs8Bytes,
	})

	return priv, keyPEM, nil
}

func buildRenewalCSRFromLeaf(leaf *x509.Certificate, signer crypto.Signer) ([]byte, error) {
	tpl := &x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: leaf.Subject.CommonName,
		},
		DNSNames: leaf.DNSNames,
		URIs:     leaf.URIs,
	}

	return x509.CreateCertificateRequest(rand.Reader, tpl, signer)
}

func cryptoRandomJitter(maxDuration time.Duration) time.Duration {
	if maxDuration <= 0 {
		return 0
	}

	n, err := rand.Int(rand.Reader, big.NewInt(int64(maxDuration)))
	if err != nil {
		return 0
	}

	return time.Duration(n.Int64())
}

func (p *PushLoop) certificateRenewalLoop(ctx context.Context) {
	if p == nil || p.gateway == nil {
		return
	}

	mgr := NewCertRenewalManager(p.gateway, p.logger)
	mgr.onRenewed = func(renewCtx context.Context) {
		p.enroll(renewCtx)
	}

	if err := mgr.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		if p.logger != nil {
			p.logger.Warn().Err(err).Msg("Certificate renewal loop stopped")
		}
	}
}
