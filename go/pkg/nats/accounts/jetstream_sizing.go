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

package accounts

import (
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats-server/v2/conf"
)

// MaxFileStoreEnv names the NATS max_file_store of the selected JetStream
// sizing profile (Docker Compose presets, packaged jetstream-sizes.env), in
// NATS size syntax such as 30G.
const MaxFileStoreEnv = "SERVICERADAR_NATS_MAX_FILE_STORE"

var (
	// ErrInvalidMaxFileStore reports a MaxFileStoreEnv value NATS would not
	// read as a positive byte count.
	ErrInvalidMaxFileStore = errors.New("invalid " + MaxFileStoreEnv)
	// ErrAccountNotIssuedByOperator reports an account JWT signed by another
	// operator, which this operator must not re-issue.
	ErrAccountNotIssuedByOperator = errors.New("account JWT was not issued by this operator")
	// ErrTieredJetStreamLimits reports an account with per-replica tiered
	// limits, which a flat quota cannot express.
	ErrTieredJetStreamLimits = errors.New("account uses tiered JetStream limits")

	natsSizePattern = regexp.MustCompile(`^[0-9]+[A-Za-z]*$`)
)

// JetStreamSizing is the JetStream quota of an account that owns every stream
// on a single NATS server, derived from that server's max_file_store.
//
// DiskStorage equals max_file_store, so the account may reserve what the server
// may hold; the sizing profile keeps the sum of stream sizes within 85% of it.
// There is no per-stream cap (DiskMaxStreamBytes 0): the total is what decides
// placement, and a cap equal to the largest preset stream would reject an
// operator raising one stream within the budget. MaxBytesRequired stays true,
// so every stream must still declare a finite max_bytes.
type JetStreamSizing struct {
	DiskStorage int64
}

// JetStreamSizingFromEnv reads MaxFileStoreEnv through lookup. It returns nil
// when the variable is unset or blank, in which case accounts keep the default
// JetStream limits.
func JetStreamSizingFromEnv(lookup func(string) (string, bool)) (*JetStreamSizing, error) {
	raw, ok := lookup(MaxFileStoreEnv)
	if !ok || strings.TrimSpace(raw) == "" {
		// Unset means "keep the defaults", which is not an error.
		return nil, nil
	}

	bytes, err := ParseNATSSize(strings.TrimSpace(raw))
	if err != nil {
		return nil, err
	}

	return &JetStreamSizing{DiskStorage: bytes}, nil
}

// ParseNATSSize reads a size the way the NATS configuration parser does (so
// 30G is 30*10^9 bytes and 30Gi is 30*2^30), and requires it to be positive.
func ParseNATSSize(value string) (int64, error) {
	if !natsSizePattern.MatchString(value) {
		return 0, fmt.Errorf("%w: %q is not a NATS size", ErrInvalidMaxFileStore, value)
	}

	parsed, err := conf.Parse("size: " + value)
	if err != nil {
		return 0, fmt.Errorf("%w: %q: %w", ErrInvalidMaxFileStore, value, err)
	}

	size, ok := parsed["size"].(int64)
	if !ok || size <= 0 {
		return 0, fmt.Errorf("%w: %q is not a positive byte count", ErrInvalidMaxFileStore, value)
	}

	return size, nil
}

// apply sets the sized quota on claims whose JetStream limits are already the
// defaults, keeping the default memory, stream and consumer limits.
func (s *JetStreamSizing) apply(limits *jwt.JetStreamLimits) {
	limits.DiskStorage = s.DiskStorage
	limits.DiskMaxStreamBytes = 0
	limits.MaxBytesRequired = true
}

// WithJetStreamSizing makes the signer issue accounts with the sized
// JetStream quota instead of the default disk limits. A nil sizing keeps the
// defaults.
func (s *AccountSigner) WithJetStreamSizing(sizing *JetStreamSizing) *AccountSigner {
	s.jetStreamSizing = sizing
	return s
}

// ResizeAccountJetStream re-issues an existing account JWT with the sized
// JetStream quota, keeping every other claim (name, mappings, exports,
// imports, revocations, other limits). Users stay valid because the account
// public key does not change. It returns the input unchanged, and false, when
// the account already carries the sized quota, so repeated runs are no-ops.
func (s *AccountSigner) ResizeAccountJetStream(accountJWT string, sizing JetStreamSizing) (string, bool, error) {
	claims, err := jwt.DecodeAccountClaims(accountJWT)
	if err != nil {
		return "", false, fmt.Errorf("decode account JWT: %w", err)
	}

	if claims.Issuer != s.operator.PublicKey() {
		return "", false, fmt.Errorf("%w: account %s issued by %s", ErrAccountNotIssuedByOperator, claims.Subject, claims.Issuer)
	}

	if len(claims.Limits.JetStreamTieredLimits) > 0 {
		return "", false, fmt.Errorf("%w: account %s", ErrTieredJetStreamLimits, claims.Subject)
	}

	current := claims.Limits.JetStreamLimits
	if current == (jwt.JetStreamLimits{}) {
		ensureJetStreamEnabled(claims)
	}

	desired := claims.Limits.JetStreamLimits
	sizing.apply(&desired)

	if desired == current {
		return accountJWT, false, nil
	}

	claims.Limits.JetStreamLimits = desired

	resigned, err := s.operator.SignAccountClaims(claims)
	if err != nil {
		return "", false, err
	}

	return resigned, true, nil
}
