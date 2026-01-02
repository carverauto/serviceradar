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

package accounts

import (
	"fmt"
	"strings"
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

// AccountLimits defines resource constraints for a NATS account.
type AccountLimits struct {
	MaxConnections       int64 `json:"max_connections"`
	MaxSubscriptions     int64 `json:"max_subscriptions"`
	MaxPayloadBytes      int64 `json:"max_payload_bytes"`
	MaxDataBytes         int64 `json:"max_data_bytes"`
	MaxExports           int64 `json:"max_exports"`
	MaxImports           int64 `json:"max_imports"`
	AllowWildcardExports bool  `json:"allow_wildcard_exports"`
}

// SubjectMapping defines how subjects are transformed for tenant isolation.
type SubjectMapping struct {
	From string `json:"from"` // Source subject pattern
	To   string `json:"to"`   // Destination subject pattern with {{tenant}} placeholder
}

// TenantAccountResult contains the generated account credentials.
// The AccountSeed should be stored encrypted by the caller.
type TenantAccountResult struct {
	AccountPublicKey string `json:"account_public_key"`
	AccountSeed      string `json:"account_seed"` // Store encrypted!
	AccountJWT       string `json:"account_jwt"`
}

// AccountSigner provides stateless NATS account signing operations.
// It holds the operator key and signs account/user JWTs.
type AccountSigner struct {
	operator *Operator

	// Default subject mappings applied to all tenant accounts.
	defaultSubjectMappings []SubjectMapping
}

// NewAccountSigner creates a new AccountSigner with the given operator.
func NewAccountSigner(operator *Operator) *AccountSigner {
	return &AccountSigner{
		operator: operator,
		defaultSubjectMappings: []SubjectMapping{
			// Common event subjects
			{From: "events.>", To: "{{tenant}}.events.>"},

			// Flowgger (syslog collector)
			{From: "syslog.>", To: "{{tenant}}.syslog.>"},

			// Trapd (SNMP trap receiver)
			{From: "snmp.>", To: "{{tenant}}.snmp.>"},

			// NetFlow/sFlow/IPFIX collector
			{From: "netflow.>", To: "{{tenant}}.netflow.>"},

			// OpenTelemetry collector
			{From: "otel.>", To: "{{tenant}}.otel.>"},

			// Legacy/generic subjects
			{From: "logs.>", To: "{{tenant}}.logs.>"},
			{From: "telemetry.>", To: "{{tenant}}.telemetry.>"},
		},
	}
}

// CreateTenantAccount generates new account NKeys and a signed account JWT.
// The returned AccountSeed should be stored encrypted by the caller.
func (s *AccountSigner) CreateTenantAccount(
	tenantSlug string,
	limits *AccountLimits,
	customMappings []SubjectMapping,
) (*TenantAccountResult, error) {
	// Generate account key pair
	accountSeed, accountPublicKey, err := GenerateAccountKey()
	if err != nil {
		return nil, fmt.Errorf("failed to generate account key: %w", err)
	}

	// Create and sign account JWT
	accountJWT, err := s.signAccountJWT(tenantSlug, accountPublicKey, limits, customMappings, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to sign account JWT: %w", err)
	}

	return &TenantAccountResult{
		AccountPublicKey: accountPublicKey,
		AccountSeed:      accountSeed,
		AccountJWT:       accountJWT,
	}, nil
}

// SignAccountJWT regenerates an account JWT with updated claims.
// Use this when revocations or limits change.
func (s *AccountSigner) SignAccountJWT(
	tenantSlug string,
	accountSeed string,
	limits *AccountLimits,
	customMappings []SubjectMapping,
	revokedUserKeys []string,
) (string, string, error) {
	// Derive public key from seed
	kp, err := nkeys.FromSeed([]byte(accountSeed))
	if err != nil {
		return "", "", fmt.Errorf("invalid account seed: %w", err)
	}

	accountPublicKey, err := kp.PublicKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to get public key: %w", err)
	}

	// Sign with operator
	accountJWT, err := s.signAccountJWT(tenantSlug, accountPublicKey, limits, customMappings, revokedUserKeys)
	if err != nil {
		return "", "", fmt.Errorf("failed to sign account JWT: %w", err)
	}

	return accountPublicKey, accountJWT, nil
}

// signAccountJWT creates and signs an account JWT with the operator key.
func (s *AccountSigner) signAccountJWT(
	tenantSlug string,
	accountPublicKey string,
	limits *AccountLimits,
	customMappings []SubjectMapping,
	revokedUserKeys []string,
) (string, error) {
	// Create account claims
	claims := jwt.NewAccountClaims(accountPublicKey)
	claims.Name = tenantSlug

	// Apply limits
	if limits != nil {
		applyLimitsToClaims(claims, limits)
	}

	// Apply subject mappings
	mappings := s.defaultSubjectMappings
	if len(customMappings) > 0 {
		mappings = append(mappings, customMappings...)
	}
	applySubjectMappings(claims, tenantSlug, mappings)

	ensureJetStreamEnabled(claims)

	// Apply revocations
	if len(revokedUserKeys) > 0 {
		if claims.Revocations == nil {
			claims.Revocations = make(jwt.RevocationList)
		}
		now := time.Now().Unix()
		for _, key := range revokedUserKeys {
			claims.Revocations[key] = now
		}
	}

	// Sign with operator key
	return s.operator.SignAccountClaims(claims)
}

// Helper functions

func applyLimitsToClaims(claims *jwt.AccountClaims, limits *AccountLimits) {
	if limits.MaxConnections > 0 {
		claims.Limits.Conn = limits.MaxConnections
	}
	if limits.MaxSubscriptions > 0 {
		claims.Limits.Subs = limits.MaxSubscriptions
	}
	if limits.MaxPayloadBytes > 0 {
		claims.Limits.Payload = limits.MaxPayloadBytes
	}
	if limits.MaxDataBytes > 0 {
		claims.Limits.Data = limits.MaxDataBytes
	}
	if limits.MaxExports > 0 {
		claims.Limits.Exports = limits.MaxExports
	}
	if limits.MaxImports > 0 {
		claims.Limits.Imports = limits.MaxImports
	}
	claims.Limits.WildcardExports = limits.AllowWildcardExports
}

func applySubjectMappings(claims *jwt.AccountClaims, tenantSlug string, mappings []SubjectMapping) {
	if claims.Mappings == nil {
		claims.Mappings = make(jwt.Mapping)
	}
	for _, mapping := range mappings {
		// Replace {{tenant}} placeholder with actual tenant slug
		to := strings.ReplaceAll(mapping.To, "{{tenant}}", tenantSlug)

		// Add mapping to claims
		claims.Mappings[jwt.Subject(mapping.From)] = []jwt.WeightedMapping{
			{Subject: jwt.Subject(to), Weight: 100},
		}
	}
}

func ensureJetStreamEnabled(claims *jwt.AccountClaims) {
	if claims == nil {
		return
	}
	if claims.Limits.JetStreamLimits != (jwt.JetStreamLimits{}) || len(claims.Limits.JetStreamTieredLimits) > 0 {
		return
	}

	claims.Limits.JetStreamLimits = jwt.JetStreamLimits{
		MemoryStorage: jwt.NoLimit,
		DiskStorage:   jwt.NoLimit,
		Streams:       jwt.NoLimit,
		Consumer:      jwt.NoLimit,
	}
}
