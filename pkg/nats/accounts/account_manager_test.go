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
	"strings"
	"testing"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

func TestNewAccountSigner(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	if signer == nil {
		t.Fatal("NewAccountSigner() returned nil")
	}

	if signer.operator != op {
		t.Error("NewAccountSigner() operator not set correctly")
	}

	// Verify default subject mappings are set
	if len(signer.defaultSubjectMappings) == 0 {
		t.Error("NewAccountSigner() defaultSubjectMappings is empty")
	}

	// Check for expected default mappings (collectors publish to these, NATS maps to tenant-prefixed)
	expectedMappings := []string{"events.>", "logs.syslog.>", "logs.snmp.>", "netflow.>", "otel.>", "logs.>", "telemetry.>"}
	for _, expected := range expectedMappings {
		found := false
		for _, mapping := range signer.defaultSubjectMappings {
			if mapping.From == expected {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("NewAccountSigner() missing expected mapping for %q", expected)
		}
	}
}

func TestAccountSigner_CreateTenantAccount(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	result, err := signer.CreateTenantAccount("acme-corp", nil, nil)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	// Verify account public key format
	if !nkeys.IsValidPublicAccountKey(result.AccountPublicKey) {
		t.Errorf("CreateTenantAccount() AccountPublicKey = %q is not valid", result.AccountPublicKey)
	}

	// Verify account seed format (starts with SA)
	if len(result.AccountSeed) < 2 || result.AccountSeed[:2] != "SA" {
		t.Errorf("CreateTenantAccount() AccountSeed = %q, want prefix 'SA'", result.AccountSeed[:2])
	}

	// Verify JWT is not empty
	if result.AccountJWT == "" {
		t.Error("CreateTenantAccount() AccountJWT is empty")
	}

	// Decode and verify JWT claims
	claims, err := jwt.DecodeAccountClaims(result.AccountJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	if claims.Name != "acme-corp" {
		t.Errorf("JWT claims.Name = %q, want %q", claims.Name, "acme-corp")
	}

	if claims.Subject != result.AccountPublicKey {
		t.Errorf("JWT claims.Subject = %q, want %q", claims.Subject, result.AccountPublicKey)
	}

	if claims.Issuer != op.PublicKey() {
		t.Errorf("JWT claims.Issuer = %q, want %q", claims.Issuer, op.PublicKey())
	}

	// Verify subject mappings are applied
	if len(claims.Mappings) == 0 {
		t.Error("JWT claims.Mappings is empty, expected default mappings")
	}

	// Check that mappings use the tenant slug
	for from, to := range claims.Mappings {
		if strings.HasPrefix(string(from), "events.") {
			if len(to) == 0 || !strings.HasPrefix(string(to[0].Subject), "acme-corp.events.") {
				t.Errorf("Mapping for %q = %v, want prefix 'acme-corp.events.'", from, to)
			}
		}
	}
}

func TestAccountSigner_CreateTenantAccount_WithLimits(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	limits := &AccountLimits{
		MaxConnections:       100,
		MaxSubscriptions:     1000,
		MaxPayloadBytes:      1024 * 1024, // 1MB
		MaxDataBytes:         1024 * 1024 * 100,
		MaxExports:           10,
		MaxImports:           10,
		AllowWildcardExports: true,
	}

	result, err := signer.CreateTenantAccount("test-tenant", limits, nil)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	// Decode and verify limits in JWT
	claims, err := jwt.DecodeAccountClaims(result.AccountJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	if claims.Limits.Conn != 100 {
		t.Errorf("JWT claims.Limits.Conn = %d, want %d", claims.Limits.Conn, 100)
	}

	if claims.Limits.Subs != 1000 {
		t.Errorf("JWT claims.Limits.Subs = %d, want %d", claims.Limits.Subs, 1000)
	}

	if claims.Limits.Payload != 1024*1024 {
		t.Errorf("JWT claims.Limits.Payload = %d, want %d", claims.Limits.Payload, 1024*1024)
	}

	if !claims.Limits.WildcardExports {
		t.Error("JWT claims.Limits.WildcardExports = false, want true")
	}
}

func TestAccountSigner_CreateTenantAccount_WithCustomMappings(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	customMappings := []SubjectMapping{
		{From: "custom.>", To: "{{tenant}}.custom.>"},
		{From: "metrics.*", To: "{{tenant}}.metrics.*"},
	}

	result, err := signer.CreateTenantAccount("custom-tenant", nil, customMappings)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	claims, err := jwt.DecodeAccountClaims(result.AccountJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	// Verify custom mappings are present
	if _, ok := claims.Mappings["custom.>"]; !ok {
		t.Error("JWT claims.Mappings missing 'custom.>' mapping")
	}

	if _, ok := claims.Mappings["metrics.*"]; !ok {
		t.Error("JWT claims.Mappings missing 'metrics.*' mapping")
	}

	// Verify tenant slug replacement
	if mappings, ok := claims.Mappings["custom.>"]; ok {
		if len(mappings) == 0 || string(mappings[0].Subject) != "custom-tenant.custom.>" {
			t.Errorf("custom.> mapping = %v, want 'custom-tenant.custom.>'", mappings)
		}
	}
}

func TestAccountSigner_SignAccountJWT(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// First create an account
	result, err := signer.CreateTenantAccount("test-tenant", nil, nil)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	// Now re-sign with updated limits
	newLimits := &AccountLimits{
		MaxConnections: 50,
	}

	pubKey, newJWT, err := signer.SignAccountJWT("test-tenant", result.AccountSeed, newLimits, nil, nil)
	if err != nil {
		t.Fatalf("SignAccountJWT() error = %v", err)
	}

	// Verify public key matches
	if pubKey != result.AccountPublicKey {
		t.Errorf("SignAccountJWT() publicKey = %q, want %q", pubKey, result.AccountPublicKey)
	}

	// Verify new JWT has updated limits
	claims, err := jwt.DecodeAccountClaims(newJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	if claims.Limits.Conn != 50 {
		t.Errorf("New JWT claims.Limits.Conn = %d, want %d", claims.Limits.Conn, 50)
	}
}

func TestAccountSigner_SignAccountJWT_WithRevocations(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Create an account
	result, err := signer.CreateTenantAccount("test-tenant", nil, nil)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	// Generate some user keys to revoke
	_, userPubKey1, _ := GenerateUserKey()
	_, userPubKey2, _ := GenerateUserKey()

	revokedKeys := []string{userPubKey1, userPubKey2}

	// Re-sign with revocations
	_, newJWT, err := signer.SignAccountJWT("test-tenant", result.AccountSeed, nil, nil, revokedKeys)
	if err != nil {
		t.Fatalf("SignAccountJWT() error = %v", err)
	}

	// Verify revocations in JWT
	claims, err := jwt.DecodeAccountClaims(newJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	if len(claims.Revocations) != 2 {
		t.Errorf("JWT claims.Revocations has %d entries, want 2", len(claims.Revocations))
	}

	if _, ok := claims.Revocations[userPubKey1]; !ok {
		t.Errorf("JWT claims.Revocations missing %q", userPubKey1)
	}

	if _, ok := claims.Revocations[userPubKey2]; !ok {
		t.Errorf("JWT claims.Revocations missing %q", userPubKey2)
	}
}

func TestAccountSigner_SignAccountJWT_InvalidSeed(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	_, _, err := signer.SignAccountJWT("test-tenant", "invalid-seed", nil, nil, nil)
	if err == nil {
		t.Error("SignAccountJWT() expected error for invalid seed, got nil")
	}
}

func TestAccountSigner_SignAccountJWT_WrongKeyType(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Use a user seed instead of account seed
	userSeed, _, _ := GenerateUserKey()

	_, _, err := signer.SignAccountJWT("test-tenant", userSeed, nil, nil, nil)
	if err == nil {
		t.Error("SignAccountJWT() expected error for wrong key type, got nil")
	}
}

func TestAccountSigner_CanRecreateFromSeed(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Create an account
	result, err := signer.CreateTenantAccount("test-tenant", nil, nil)
	if err != nil {
		t.Fatalf("CreateTenantAccount() error = %v", err)
	}

	// Verify we can derive the same public key from the seed
	kp, err := nkeys.FromSeed([]byte(result.AccountSeed))
	if err != nil {
		t.Fatalf("nkeys.FromSeed() error = %v", err)
	}

	derivedPubKey, err := kp.PublicKey()
	if err != nil {
		t.Fatalf("kp.PublicKey() error = %v", err)
	}

	if derivedPubKey != result.AccountPublicKey {
		t.Errorf("Derived public key = %q, want %q", derivedPubKey, result.AccountPublicKey)
	}
}

func TestAccountSigner_MultipleAccounts(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Create multiple accounts
	tenants := []string{"tenant-a", "tenant-b", "tenant-c"}
	if testing.Short() {
		tenants = tenants[:2]
	}
	results := make(map[string]*TenantAccountResult)

	for _, tenant := range tenants {
		result, err := signer.CreateTenantAccount(tenant, nil, nil)
		if err != nil {
			t.Fatalf("CreateTenantAccount(%q) error = %v", tenant, err)
		}
		results[tenant] = result
	}

	// Verify all accounts have unique keys
	seen := make(map[string]bool)
	for tenant, result := range results {
		if seen[result.AccountPublicKey] {
			t.Errorf("Duplicate public key for tenant %q", tenant)
		}
		seen[result.AccountPublicKey] = true

		if seen[result.AccountSeed] {
			t.Errorf("Duplicate seed for tenant %q", tenant)
		}
		seen[result.AccountSeed] = true
	}
}
