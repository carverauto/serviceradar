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

// Package sshca signs short-lived OpenSSH user certificates for ServiceRadar
// remote-access sessions.
package sshca

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const (
	DefaultMaxTTL   = 8 * time.Hour
	DefaultBackdate = 30 * time.Second
)

var (
	ErrCAPrivateKeyRequired = errors.New("ssh ca private key is required")
	ErrPublicKeyRequired    = errors.New("ssh public key is required")
	ErrKeyIDRequired        = errors.New("ssh certificate key id is required")
	ErrPrincipalRequired    = errors.New("at least one ssh principal is required")
	ErrTTLRequired          = errors.New("ssh certificate ttl is required")
	ErrTTLExceedsMaximum    = errors.New("ssh certificate ttl exceeds maximum")
	ErrInvalidValidity      = errors.New("ssh certificate validity window is invalid")
	ErrPublicKeyIsCert      = errors.New("ssh public key must not be a certificate")
	ErrUnsupportedSignerKey = errors.New("unsupported ssh ca signer key")
	ErrUnsupportedCritical  = errors.New("unsupported ssh certificate critical option")
	ErrUnsupportedExtension = errors.New("unsupported ssh certificate extension")
)

// CA signs OpenSSH user certificates with one ServiceRadar SSH user CA key.
type CA struct {
	signer   ssh.Signer
	maxTTL   time.Duration
	backdate time.Duration
	now      func() time.Time

	allowedCriticalOptions map[string]struct{}
}

// Option configures a CA.
type Option func(*CA)

// WithMaxTTL sets the maximum allowed user-certificate TTL. A non-positive
// value disables the maximum; callers should use that only for tests.
func WithMaxTTL(ttl time.Duration) Option {
	return func(ca *CA) {
		ca.maxTTL = ttl
	}
}

// WithBackdate sets the validity backdate used to tolerate small target clock
// skews when the caller does not provide ValidAfter.
func WithBackdate(backdate time.Duration) Option {
	return func(ca *CA) {
		ca.backdate = backdate
	}
}

// WithClock sets the clock used for signing. It is primarily for tests.
func WithClock(now func() time.Time) Option {
	return func(ca *CA) {
		if now != nil {
			ca.now = now
		}
	}
}

// WithAllowedCriticalOptions permits explicitly reviewed OpenSSH certificate
// critical options such as source-address. By default, ServiceRadar does not
// allow caller-provided critical options.
func WithAllowedCriticalOptions(names ...string) Option {
	return func(ca *CA) {
		ca.allowedCriticalOptions = make(map[string]struct{}, len(names))
		for _, name := range names {
			name = strings.TrimSpace(name)
			if name != "" {
				ca.allowedCriticalOptions[name] = struct{}{}
			}
		}
	}
}

// New parses an OpenSSH or PEM private key and returns an SSH CA signer.
func New(privateKey, passphrase []byte, opts ...Option) (*CA, error) {
	if len(bytes.TrimSpace(privateKey)) == 0 {
		return nil, ErrCAPrivateKeyRequired
	}

	var (
		signer ssh.Signer
		err    error
	)
	if len(passphrase) > 0 {
		signer, err = ssh.ParsePrivateKeyWithPassphrase(privateKey, passphrase)
	} else {
		signer, err = ssh.ParsePrivateKey(privateKey)
	}
	if err != nil {
		return nil, fmt.Errorf("parse ssh ca private key: %w", err)
	}

	return NewFromSigner(signer, opts...), nil
}

// NewFromSigner returns an SSH CA using an existing signer.
func NewFromSigner(signer ssh.Signer, opts ...Option) *CA {
	ca := &CA{
		signer:   signer,
		maxTTL:   DefaultMaxTTL,
		backdate: DefaultBackdate,
		now:      time.Now,
	}
	for _, opt := range opts {
		opt(ca)
	}
	return ca
}

// PublicKey returns the SSH CA public key.
func (ca *CA) PublicKey() ssh.PublicKey {
	if ca == nil || ca.signer == nil {
		return nil
	}
	return ca.signer.PublicKey()
}

// UserCertificateRequest describes a ServiceRadar remote-access user cert.
type UserCertificateRequest struct {
	PublicKey       []byte
	KeyID           string
	Principals      []string
	TTL             time.Duration
	ValidAfter      time.Time
	Serial          uint64
	CriticalOptions map[string]string
	Extensions      map[string]string
}

// UserCertificate is a signed OpenSSH user certificate and audit metadata.
type UserCertificate struct {
	AuthorizedKey        []byte
	Certificate          *ssh.Certificate
	ExpiresAt            time.Time
	PublicKeyFingerprint string
}

// SignUserCertificate signs a short-lived OpenSSH user certificate.
func (ca *CA) SignUserCertificate(req UserCertificateRequest) (*UserCertificate, error) {
	if ca == nil || ca.signer == nil {
		return nil, ErrCAPrivateKeyRequired
	}
	if len(bytes.TrimSpace(req.PublicKey)) == 0 {
		return nil, ErrPublicKeyRequired
	}

	publicKey, _, _, _, err := ssh.ParseAuthorizedKey(req.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("parse ssh public key: %w", err)
	}
	if _, ok := publicKey.(*ssh.Certificate); ok {
		return nil, ErrPublicKeyIsCert
	}

	keyID := strings.TrimSpace(req.KeyID)
	if keyID == "" {
		return nil, ErrKeyIDRequired
	}

	principals := normalizePrincipals(req.Principals)
	if len(principals) == 0 {
		return nil, ErrPrincipalRequired
	}
	if req.TTL <= 0 {
		return nil, ErrTTLRequired
	}
	if ca.maxTTL > 0 && req.TTL > ca.maxTTL {
		return nil, fmt.Errorf("%w: requested=%s max=%s", ErrTTLExceedsMaximum, req.TTL, ca.maxTTL)
	}
	if err := validateCertificatePermissions(req.CriticalOptions, req.Extensions, ca.allowedCriticalOptions); err != nil {
		return nil, err
	}

	signer, err := hardenedSigner(ca.signer)
	if err != nil {
		return nil, err
	}

	now := ca.now().UTC()
	validAfter := req.ValidAfter.UTC()
	if validAfter.IsZero() {
		validAfter = now.Add(-ca.backdate)
	}
	expiresAt := now.Add(req.TTL)
	if !validAfter.Before(expiresAt) {
		return nil, ErrInvalidValidity
	}

	serial := req.Serial
	if serial == 0 {
		serial, err = randomSerial()
		if err != nil {
			return nil, err
		}
	}

	cert := &ssh.Certificate{
		Key:             publicKey,
		Serial:          serial,
		CertType:        ssh.UserCert,
		KeyId:           keyID,
		ValidPrincipals: principals,
		ValidAfter:      uint64(validAfter.Unix()),
		ValidBefore:     uint64(expiresAt.Unix()),
		Permissions: ssh.Permissions{
			CriticalOptions: copyMap(req.CriticalOptions),
			Extensions:      defaultExtensions(req.Extensions),
		},
	}
	if err := cert.SignCert(rand.Reader, signer); err != nil {
		return nil, fmt.Errorf("sign ssh user certificate: %w", err)
	}

	return &UserCertificate{
		AuthorizedKey:        ssh.MarshalAuthorizedKey(cert),
		Certificate:          cert,
		ExpiresAt:            expiresAt,
		PublicKeyFingerprint: ssh.FingerprintSHA256(publicKey),
	}, nil
}

func normalizePrincipals(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	principals := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		principals = append(principals, value)
	}
	return principals
}

func defaultExtensions(values map[string]string) map[string]string {
	if len(values) == 0 {
		return map[string]string{"permit-pty": ""}
	}
	return copyMap(values)
}

func validateCertificatePermissions(criticalOptions, extensions map[string]string, allowedCriticalOptions map[string]struct{}) error {
	for name := range criticalOptions {
		if _, ok := allowedCriticalOptions[name]; !ok {
			return fmt.Errorf("%w: %s", ErrUnsupportedCritical, name)
		}
	}
	for name := range extensions {
		if name != "permit-pty" {
			return fmt.Errorf("%w: %s", ErrUnsupportedExtension, name)
		}
	}
	return nil
}

func hardenedSigner(signer ssh.Signer) (ssh.Signer, error) {
	if signer == nil || signer.PublicKey() == nil {
		return nil, ErrCAPrivateKeyRequired
	}

	cryptoKey, ok := signer.PublicKey().(ssh.CryptoPublicKey)
	if !ok {
		return signer, validateSignerKeyType(signer.PublicKey().Type())
	}

	switch key := cryptoKey.CryptoPublicKey().(type) {
	case ed25519.PublicKey:
		return signer, nil
	case *ecdsa.PublicKey:
		if key.Curve == nil || key.Curve.Params().BitSize < 256 {
			return nil, ErrUnsupportedSignerKey
		}
		return signer, nil
	case *rsa.PublicKey:
		if key.N == nil || key.N.BitLen() < 4096 {
			return nil, ErrUnsupportedSignerKey
		}
		algorithmSigner, ok := signer.(ssh.AlgorithmSigner)
		if !ok {
			return nil, ErrUnsupportedSignerKey
		}
		return ssh.NewSignerWithAlgorithms(algorithmSigner, []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256})
	default:
		return nil, validateSignerKeyType(signer.PublicKey().Type())
	}
}

func validateSignerKeyType(keyType string) error {
	switch keyType {
	case ssh.KeyAlgoED25519, ssh.KeyAlgoECDSA256, ssh.KeyAlgoECDSA384, ssh.KeyAlgoECDSA521:
		return nil
	default:
		return fmt.Errorf("%w: %s", ErrUnsupportedSignerKey, keyType)
	}
}

func copyMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	copied := make(map[string]string, len(values))
	for key, value := range values {
		copied[key] = value
	}
	return copied
}

func randomSerial() (uint64, error) {
	var data [8]byte
	if _, err := rand.Read(data[:]); err != nil {
		return 0, fmt.Errorf("generate ssh certificate serial: %w", err)
	}
	return binary.BigEndian.Uint64(data[:]), nil
}
