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

// Package tlsclient builds the TLS client configuration for connections to
// operator-configured targets: devices, controllers, plugin destinations and
// message brokers. It is the one place that decides whether a server
// certificate is verified, so the rules hold everywhere:
//
//   - a pinned CA or a pinned leaf fingerprint always wins, and certificate
//     verification is never skipped while one is configured;
//   - verification is skipped only when the caller passes an explicit opt-in
//     and nothing is pinned;
//   - every skip, and every opt-in a pin overrode, is logged.
package tlsclient

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

// FingerprintPrefix is the algorithm prefix a pinned leaf fingerprint carries:
// "sha256:" followed by the lowercase hex SHA-256 of the leaf certificate's DER.
const FingerprintPrefix = "sha256:"

var (
	// ErrNoPeerCertificate is returned during the handshake when a fingerprint
	// is pinned and the server presented no certificate.
	ErrNoPeerCertificate = errors.New("server presented no certificate")
	// ErrFingerprintMismatch is returned during the handshake when the server's
	// leaf certificate does not hash to the pinned fingerprint.
	ErrFingerprintMismatch = errors.New("server certificate fingerprint does not match pinned fingerprint")
)

// Warner is the part of a logger the constructor needs. logger.Logger and
// *zerolog.Logger both satisfy it.
type Warner interface {
	Warn() *zerolog.Event
}

// Policy describes how one client verifies its server.
type Policy struct {
	// Base supplies everything except the verification decision: default
	// roots, client certificates, server name, minimum version. It is cloned,
	// never mutated. When nil the config starts from TLS 1.2 minimum.
	// Base.InsecureSkipVerify is ignored; only InsecureSkipVerify below opts in.
	Base *tls.Config
	// ServerName overrides Base.ServerName when non-empty.
	ServerName string
	// PinnedRoots replaces the trust store with the target's own CA bundle.
	// The chain is always verified against it.
	PinnedRoots *x509.CertPool
	// PinnedFingerprint accepts exactly one leaf certificate, written as
	// FingerprintPrefix plus lowercase hex. With PinnedRoots also set, the
	// chain is verified and the leaf must match too. On its own, the
	// fingerprint match is the whole verification: chain building and
	// hostname matching cannot succeed without an anchor.
	PinnedFingerprint string
	// InsecureSkipVerify is the caller's explicit opt-in to skip certificate
	// verification. It is honoured only when nothing is pinned.
	InsecureSkipVerify bool
	// OptIn names the setting or policy that requested the skip, for the log
	// line, for example "mapper.unifi.insecure_skip_verify".
	OptIn string
	// Target identifies the destination in the log line: a host, host:port or
	// operator-facing name. It must not carry credentials or tokens.
	Target string
	// Logger receives the warnings. The process logger is used when nil.
	Logger Warner
}

// Config returns the TLS client configuration that policy describes.
func Config(policy Policy) *tls.Config {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if policy.Base != nil {
		cfg = policy.Base.Clone()
	}
	if policy.ServerName != "" {
		cfg.ServerName = policy.ServerName
	}

	pinned := policy.PinnedRoots != nil || policy.PinnedFingerprint != ""
	if pinned && policy.InsecureSkipVerify {
		warn(policy).Msg("TLS verification opt-in ignored because the target pins its certificate authority or fingerprint")
	}
	if policy.PinnedRoots != nil {
		cfg.RootCAs = policy.PinnedRoots
	}
	if policy.PinnedFingerprint != "" {
		cfg.VerifyPeerCertificate = verifyLeafFingerprint(cfg.VerifyPeerCertificate, policy.PinnedFingerprint)
	}

	// The standard chain check is switched off in exactly two cases: a
	// fingerprint pin with no CA, where VerifyPeerCertificate above is the
	// verification, and the caller's explicit opt-in with nothing pinned,
	// which is logged here every time a config is built.
	fingerprintOnly := policy.PinnedFingerprint != "" && policy.PinnedRoots == nil
	optedIn := policy.InsecureSkipVerify && !pinned
	if optedIn {
		warn(policy).Msg("TLS certificate verification disabled by explicit opt-in")
	}
	// This is the single sanctioned InsecureSkipVerify in the Go tree; every
	// opt-in reaches it through the rules above.
	cfg.InsecureSkipVerify = fingerprintOnly || optedIn //nolint:gosec // G402: pinned-fingerprint verification or a logged explicit opt-in, decided above

	return cfg
}

// Fingerprint returns the pin string for a DER-encoded certificate in the form
// PinnedFingerprint expects.
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return FingerprintPrefix + hex.EncodeToString(sum[:])
}

func verifyLeafFingerprint(
	previous func([][]byte, [][]*x509.Certificate) error,
	expected string,
) func([][]byte, [][]*x509.Certificate) error {
	return func(rawCerts [][]byte, chains [][]*x509.Certificate) error {
		if previous != nil {
			if err := previous(rawCerts, chains); err != nil {
				return err
			}
		}
		if len(rawCerts) == 0 {
			return ErrNoPeerCertificate
		}
		if got := Fingerprint(rawCerts[0]); got != expected {
			return fmt.Errorf("%w: got %s want %s", ErrFingerprintMismatch, got, expected)
		}
		return nil
	}
}

func warn(policy Policy) *zerolog.Event {
	var event *zerolog.Event
	if policy.Logger != nil {
		event = policy.Logger.Warn()
	} else {
		event = log.Warn()
	}

	return event.Str("tls_target", policy.Target).Str("tls_opt_in", policy.OptIn)
}
