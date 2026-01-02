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
	"time"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

// createTestAccount creates a test account and returns its seed.
func createTestAccount(t *testing.T) string {
	t.Helper()

	seed, _, err := GenerateAccountKey()
	if err != nil {
		t.Fatalf("GenerateAccountKey() error = %v", err)
	}

	return seed
}

func TestGenerateUserCredentials_Basic(t *testing.T) {
	accountSeed := createTestAccount(t)

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"test-user",
		CredentialTypeCollector,
		nil,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	// Verify user public key format
	if !nkeys.IsValidPublicUserKey(creds.UserPublicKey) {
		t.Errorf("GenerateUserCredentials() UserPublicKey = %q is not valid", creds.UserPublicKey)
	}

	// Verify JWT is not empty
	if creds.UserJWT == "" {
		t.Error("GenerateUserCredentials() UserJWT is empty")
	}

	// Verify creds file content
	if creds.CredsFileContent == "" {
		t.Error("GenerateUserCredentials() CredsFileContent is empty")
	}

	// Verify creds file contains JWT and seed sections
	if !strings.Contains(creds.CredsFileContent, "-----BEGIN NATS USER JWT-----") {
		t.Error("CredsFileContent missing JWT header")
	}
	if !strings.Contains(creds.CredsFileContent, "-----BEGIN USER NKEY SEED-----") {
		t.Error("CredsFileContent missing NKEY SEED header")
	}
	if !strings.Contains(creds.CredsFileContent, creds.UserJWT) {
		t.Error("CredsFileContent does not contain the user JWT")
	}

	// Verify ExpiresAt is zero (no expiration)
	if !creds.ExpiresAt.IsZero() {
		t.Errorf("GenerateUserCredentials() ExpiresAt = %v, want zero", creds.ExpiresAt)
	}
}

func TestGenerateUserCredentials_WithExpiration(t *testing.T) {
	accountSeed := createTestAccount(t)

	expirationSeconds := int64(3600) // 1 hour

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"test-user",
		CredentialTypeCollector,
		nil,
		expirationSeconds,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	// Verify ExpiresAt is set
	if creds.ExpiresAt.IsZero() {
		t.Error("GenerateUserCredentials() ExpiresAt should not be zero")
	}

	// Verify expiration is approximately 1 hour from now
	expectedExpiry := time.Now().Add(time.Hour)
	diff := creds.ExpiresAt.Sub(expectedExpiry)
	if diff < -time.Minute || diff > time.Minute {
		t.Errorf("GenerateUserCredentials() ExpiresAt = %v, want approximately %v", creds.ExpiresAt, expectedExpiry)
	}

	// Verify JWT claims have expiration
	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	if claims.Expires == 0 {
		t.Error("JWT claims.Expires should not be 0")
	}
}

func TestGenerateUserCredentials_CollectorType(t *testing.T) {
	accountSeed := createTestAccount(t)

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"collector-1",
		CredentialTypeCollector,
		nil,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	// Verify collector permissions
	pubAllow := claims.Pub.Allow
	if !contains(pubAllow, "events.>") {
		t.Error("Collector should have 'events.>' publish permission")
	}
	if !contains(pubAllow, "snmp.traps") {
		t.Error("Collector should have 'snmp.traps' publish permission")
	}
	if !contains(pubAllow, "logs.>") {
		t.Error("Collector should have 'logs.>' publish permission")
	}

	subAllow := claims.Sub.Allow
	if !contains(subAllow, "_INBOX.>") {
		t.Error("Collector should have '_INBOX.>' subscribe permission")
	}

	// Verify response permission
	if claims.Resp == nil {
		t.Error("Collector should have response permission")
	} else if claims.Resp.MaxMsgs != 1 {
		t.Errorf("Collector response MaxMsgs = %d, want 1", claims.Resp.MaxMsgs)
	}
}

func TestGenerateUserCredentials_ServiceType(t *testing.T) {
	accountSeed := createTestAccount(t)

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"service-1",
		CredentialTypeService,
		nil,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	// Verify service permissions (broader tenant scope)
	pubAllow := claims.Pub.Allow
	if !contains(pubAllow, "test-tenant.>") {
		t.Error("Service should have 'test-tenant.>' publish permission")
	}

	subAllow := claims.Sub.Allow
	if !contains(subAllow, "test-tenant.>") {
		t.Error("Service should have 'test-tenant.>' subscribe permission")
	}

	// Verify higher response limit for services
	if claims.Resp == nil {
		t.Error("Service should have response permission")
	} else if claims.Resp.MaxMsgs != 100 {
		t.Errorf("Service response MaxMsgs = %d, want 100", claims.Resp.MaxMsgs)
	}
}

func TestGenerateUserCredentials_AdminType(t *testing.T) {
	accountSeed := createTestAccount(t)

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"admin-1",
		CredentialTypeAdmin,
		nil,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	// Verify admin permissions (limited publish, broader subscribe)
	pubAllow := claims.Pub.Allow
	if !contains(pubAllow, "test-tenant.admin.>") {
		t.Error("Admin should have 'test-tenant.admin.>' publish permission")
	}

	subAllow := claims.Sub.Allow
	if !contains(subAllow, "test-tenant.>") {
		t.Error("Admin should have 'test-tenant.>' subscribe permission")
	}
}

func TestGenerateUserCredentials_CustomPermissions(t *testing.T) {
	accountSeed := createTestAccount(t)

	customPerms := &UserPermissions{
		PublishAllow:   []string{"custom.pub.>", "other.pub"},
		PublishDeny:    []string{"custom.pub.secret"},
		SubscribeAllow: []string{"custom.sub.>"},
		SubscribeDeny:  []string{"custom.sub.private"},
		AllowResponses: true,
		MaxResponses:   5,
	}

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"custom-user",
		CredentialTypeCollector, // Base type, will be overridden
		customPerms,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	// Verify custom publish allow (should override defaults)
	pubAllow := claims.Pub.Allow
	if !contains(pubAllow, "custom.pub.>") {
		t.Error("Custom user should have 'custom.pub.>' publish permission")
	}
	if !contains(pubAllow, "other.pub") {
		t.Error("Custom user should have 'other.pub' publish permission")
	}
	// Default collector permissions should be overridden
	if contains(pubAllow, "events.>") {
		t.Error("Custom user should NOT have default 'events.>' permission when custom is specified")
	}

	// Verify custom publish deny
	pubDeny := claims.Pub.Deny
	if !contains(pubDeny, "custom.pub.secret") {
		t.Error("Custom user should have 'custom.pub.secret' in publish deny")
	}

	// Verify custom subscribe allow
	subAllow := claims.Sub.Allow
	if !contains(subAllow, "custom.sub.>") {
		t.Error("Custom user should have 'custom.sub.>' subscribe permission")
	}

	// Verify custom subscribe deny
	subDeny := claims.Sub.Deny
	if !contains(subDeny, "custom.sub.private") {
		t.Error("Custom user should have 'custom.sub.private' in subscribe deny")
	}

	// Verify custom response permission
	if claims.Resp == nil {
		t.Error("Custom user should have response permission")
	} else if claims.Resp.MaxMsgs != 5 {
		t.Errorf("Custom user response MaxMsgs = %d, want 5", claims.Resp.MaxMsgs)
	}
}

func TestGenerateUserCredentials_InvalidAccountSeed(t *testing.T) {
	_, err := GenerateUserCredentials(
		"test-tenant",
		"invalid-seed",
		"test-user",
		CredentialTypeCollector,
		nil,
		0,
	)
	if err == nil {
		t.Error("GenerateUserCredentials() expected error for invalid seed, got nil")
	}
}

func TestGenerateUserCredentials_WrongKeyType(t *testing.T) {
	// Use operator seed instead of account seed
	operatorSeed, _, _ := GenerateOperatorKey()

	_, err := GenerateUserCredentials(
		"test-tenant",
		operatorSeed,
		"test-user",
		CredentialTypeCollector,
		nil,
		0,
	)
	if err == nil {
		t.Error("GenerateUserCredentials() expected error for wrong key type, got nil")
	}
}

func TestGenerateUserCredentials_JWTSignedByAccount(t *testing.T) {
	accountSeed := createTestAccount(t)

	// Get account public key
	kp, _ := nkeys.FromSeed([]byte(accountSeed))
	accountPubKey, _ := kp.PublicKey()

	creds, err := GenerateUserCredentials(
		"test-tenant",
		accountSeed,
		"test-user",
		CredentialTypeCollector,
		nil,
		0,
	)
	if err != nil {
		t.Fatalf("GenerateUserCredentials() error = %v", err)
	}

	claims, err := jwt.DecodeUserClaims(creds.UserJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeUserClaims() error = %v", err)
	}

	// Verify the JWT is signed by the account (IssuerAccount)
	if claims.IssuerAccount != accountPubKey {
		t.Errorf("JWT claims.IssuerAccount = %q, want %q", claims.IssuerAccount, accountPubKey)
	}
}

func TestGenerateUserCredentials_UniqueKeys(t *testing.T) {
	accountSeed := createTestAccount(t)

	// Generate multiple user credentials
	var creds []*UserCredentials
	for i := 0; i < 5; i++ {
		c, err := GenerateUserCredentials(
			"test-tenant",
			accountSeed,
			"test-user",
			CredentialTypeCollector,
			nil,
			0,
		)
		if err != nil {
			t.Fatalf("GenerateUserCredentials() error = %v", err)
		}
		creds = append(creds, c)
	}

	// Verify all have unique public keys
	seen := make(map[string]bool)
	for i, c := range creds {
		if seen[c.UserPublicKey] {
			t.Errorf("Duplicate user public key at index %d", i)
		}
		seen[c.UserPublicKey] = true
	}
}

func TestFormatCredsFile(t *testing.T) {
	testJWT := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test"
	testSeed := []byte("SUAIBDPBAUTWCWBKIO6XHQNINK5FWJW4OHLXC3HQ2KFE4PEJUA44CNHTBQ")

	content := formatCredsFile(testJWT, testSeed)

	// Verify structure
	if !strings.Contains(content, "-----BEGIN NATS USER JWT-----") {
		t.Error("formatCredsFile() missing JWT begin marker")
	}
	if !strings.Contains(content, "------END NATS USER JWT------") {
		t.Error("formatCredsFile() missing JWT end marker")
	}
	if !strings.Contains(content, "-----BEGIN USER NKEY SEED-----") {
		t.Error("formatCredsFile() missing NKEY SEED begin marker")
	}
	if !strings.Contains(content, "------END USER NKEY SEED------") {
		t.Error("formatCredsFile() missing NKEY SEED end marker")
	}
	if !strings.Contains(content, testJWT) {
		t.Error("formatCredsFile() missing JWT content")
	}
	if !strings.Contains(content, string(testSeed)) {
		t.Error("formatCredsFile() missing seed content")
	}
	if !strings.Contains(content, "IMPORTANT") {
		t.Error("formatCredsFile() missing IMPORTANT warning")
	}
}

// Helper function to check if a slice contains a string.
func contains(slice jwt.StringList, s string) bool {
	for _, item := range slice {
		if item == s {
			return true
		}
	}
	return false
}
