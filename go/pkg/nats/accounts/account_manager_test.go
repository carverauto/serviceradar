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
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

const dockerComposeMaxFileStoreBytes int64 = 10 * 1000 * 1000 * 1000
const dockerComposeDatasvcBucketMaxBytes int64 = 2 * 1024 * 1024 * 1024

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

	// Check for expected default mappings (collectors publish to these, NATS maps to namespace-prefixed)
	expectedMappings := []string{
		"events.>",
		"logs.syslog.>",
		"logs.snmp.>",
		"netflow.>",
		"arancini.updates.>",
		"otel.>",
		"logs.>",
		"telemetry.>",
	}
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

func TestAccountSigner_CreateAccount(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	result, err := signer.CreateAccount("acme-corp", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
	}

	// Verify account public key format
	if !nkeys.IsValidPublicAccountKey(result.AccountPublicKey) {
		t.Errorf("CreateAccount() AccountPublicKey = %q is not valid", result.AccountPublicKey)
	}

	// Verify account seed format (starts with SA)
	if len(result.AccountSeed) < 2 || result.AccountSeed[:2] != "SA" {
		t.Errorf("CreateAccount() AccountSeed = %q, want prefix 'SA'", result.AccountSeed[:2])
	}

	// Verify JWT is not empty
	if result.AccountJWT == "" {
		t.Error("CreateAccount() AccountJWT is empty")
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

	// Check that mappings use the account name as namespace
	for from, to := range claims.Mappings {
		if strings.HasPrefix(string(from), "events.") {
			if len(to) == 0 || !strings.HasPrefix(string(to[0].Subject), "acme-corp.events.") {
				t.Errorf("Mapping for %q = %v, want prefix 'acme-corp.events.'", from, to)
			}
		}
	}
}

func TestAccountSigner_CreateAccount_WithLimits(t *testing.T) {
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

	result, err := signer.CreateAccount("test-ns", limits, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
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

func TestAccountSigner_CreateAccount_DefaultJetStreamLimitsAreFinite(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	result, err := signer.CreateAccount("bounded-ns", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
	}

	claims, err := jwt.DecodeAccountClaims(result.AccountJWT)
	if err != nil {
		t.Fatalf("jwt.DecodeAccountClaims() error = %v", err)
	}

	if claims.Limits.MemoryStorage <= 0 {
		t.Errorf("MemoryStorage = %d, want finite positive limit", claims.Limits.MemoryStorage)
	}
	if claims.Limits.DiskStorage <= 0 {
		t.Errorf("DiskStorage = %d, want finite positive limit", claims.Limits.DiskStorage)
	}
	if claims.Limits.DiskStorage > dockerComposeMaxFileStoreBytes {
		t.Errorf(
			"DiskStorage = %d, exceeds docker compose NATS max_file_store budget %d",
			claims.Limits.DiskStorage,
			dockerComposeMaxFileStoreBytes,
		)
	}
	if claims.Limits.Streams <= 0 {
		t.Errorf("Streams = %d, want finite positive limit", claims.Limits.Streams)
	}
	if claims.Limits.DiskMaxStreamBytes < dockerComposeDatasvcBucketMaxBytes {
		t.Errorf(
			"DiskMaxStreamBytes = %d, want at least compose datasvc bucket limit %d",
			claims.Limits.DiskMaxStreamBytes,
			dockerComposeDatasvcBucketMaxBytes,
		)
	}
	if claims.Limits.Consumer <= 0 {
		t.Errorf("Consumer = %d, want finite positive limit", claims.Limits.Consumer)
	}
	if !claims.Limits.MaxBytesRequired {
		t.Error("MaxBytesRequired = false, want true")
	}
}

func TestAccountSigner_DefaultJetStreamLimitsFitComposeNetworkIngest(t *testing.T) {
	type datasvcBudget struct {
		BucketMaxBytes   int64 `json:"bucket_max_bytes"`
		ObjectStoreBytes int64 `json:"object_store_bytes"`
	}
	type collectorBudget struct {
		StreamMaxBytes int64 `json:"stream_max_bytes"`
	}

	var datasvc datasvcBudget
	readComposeJSON(t, "docker/compose/datasvc.mtls.json", &datasvc)
	if datasvc.BucketMaxBytes <= 0 || datasvc.ObjectStoreBytes <= 0 {
		t.Fatalf(
			"compose datasvc reservations must be explicit and positive: KV=%d object=%d",
			datasvc.BucketMaxBytes,
			datasvc.ObjectStoreBytes,
		)
	}

	var flows collectorBudget
	readComposeJSON(t, "docker/compose/flow-collector.docker.json", &flows)
	var bmp collectorBudget
	readComposeJSON(t, "docker/compose/bmp-collector.docker.json", &bmp)
	events := readIntegerSetting(t, "docker/compose/otel.docker.toml", "max_bytes")
	serverMax := readSizedSetting(t, "docker/compose/nats.docker.conf", "max_file_store")

	reserved := datasvc.BucketMaxBytes + datasvc.ObjectStoreBytes + events +
		flows.StreamMaxBytes + bmp.StreamMaxBytes
	const minimumAccountHeadroom int64 = 512 * 1024 * 1024
	if reserved+minimumAccountHeadroom > defaultJetStreamDiskBytes {
		t.Fatalf(
			"compose network-ingest reservations %d plus headroom %d exceed platform account quota %d",
			reserved,
			minimumAccountHeadroom,
			defaultJetStreamDiskBytes,
		)
	}

	// Keep a full decimal GB outside the generated account for NATS server and
	// system-account overhead. This also guards the binary-GiB/decimal-G unit
	// mismatch in nats.docker.conf.
	const minimumServerHeadroom int64 = 1_000_000_000
	if defaultJetStreamDiskBytes+minimumServerHeadroom > serverMax {
		t.Fatalf(
			"platform account quota %d plus server headroom %d exceed compose max_file_store %d",
			defaultJetStreamDiskBytes,
			minimumServerHeadroom,
			serverMax,
		)
	}
}

func readComposeJSON(t *testing.T, name string, target any) {
	t.Helper()
	data := readRepoFixture(t, name)
	if err := json.Unmarshal(data, target); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
}

func readIntegerSetting(t *testing.T, name, setting string) int64 {
	t.Helper()
	data := readRepoFixture(t, name)
	pattern := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(setting) + `\s*=\s*([0-9]+)\s*(?:#.*)?$`)
	match := pattern.FindSubmatch(data)
	if len(match) != 2 {
		t.Fatalf("%s does not contain integer setting %s", name, setting)
	}
	value, err := strconv.ParseInt(string(match[1]), 10, 64)
	if err != nil {
		t.Fatalf("parse %s %s: %v", name, setting, err)
	}
	return value
}

func readSizedSetting(t *testing.T, name, setting string) int64 {
	t.Helper()
	data := readRepoFixture(t, name)
	pattern := regexp.MustCompile(`(?m)^\s*` + regexp.QuoteMeta(setting) + `\s*:\s*([0-9]+)([KMG]?)\s*(?:#.*)?$`)
	match := pattern.FindSubmatch(data)
	if len(match) != 3 {
		t.Fatalf("%s does not contain sized setting %s", name, setting)
	}
	value, err := strconv.ParseInt(string(match[1]), 10, 64)
	if err != nil {
		t.Fatalf("parse %s %s: %v", name, setting, err)
	}
	multiplier := int64(1)
	switch string(match[2]) {
	case "K":
		multiplier = 1_000
	case "M":
		multiplier = 1_000_000
	case "G":
		multiplier = 1_000_000_000
	}
	return value * multiplier
}

func readRepoFixture(t *testing.T, name string) []byte {
	t.Helper()
	for _, candidate := range repoFixtureCandidates(name) {
		data, err := os.ReadFile(candidate)
		if err == nil {
			return data
		}
	}
	t.Fatalf("cannot locate repository fixture %s", name)
	return nil
}

func repoFixtureCandidates(name string) []string {
	candidates := make([]string, 0, 5)
	if root := strings.TrimSpace(os.Getenv("BUILD_WORKSPACE_DIRECTORY")); root != "" {
		candidates = append(candidates, filepath.Join(root, name))
	}
	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
			if workspace != "" {
				candidates = append(candidates, filepath.Join(testSrcDir, workspace, name))
			}
		}
	}
	if _, thisFile, _, ok := runtime.Caller(0); ok {
		candidates = append(candidates, filepath.Clean(filepath.Join(filepath.Dir(thisFile), "../../../../..", name)))
	}
	if cwd, err := os.Getwd(); err == nil {
		for dir := cwd; ; dir = filepath.Dir(dir) {
			candidates = append(candidates, filepath.Join(dir, name))
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
		}
	}
	return candidates
}

func TestAccountSigner_CreateAccount_WithCustomMappings(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	customMappings := []SubjectMapping{
		{From: "custom.>", To: "{{namespace}}.custom.>"},
		{From: "metrics.*", To: "{{namespace}}.metrics.*"},
	}

	result, err := signer.CreateAccount("custom-ns", nil, customMappings, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
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

	// Verify namespace placeholder replacement
	if mappings, ok := claims.Mappings["custom.>"]; ok {
		if len(mappings) == 0 || string(mappings[0].Subject) != "custom-ns.custom.>" {
			t.Errorf("custom.> mapping = %v, want 'custom-ns.custom.>'", mappings)
		}
	}
}

func TestAccountSigner_CreateAccount_RejectsOutOfScopeExports(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	_, err := signer.CreateAccount("tenant-a", nil, nil, []StreamExport{
		{Subject: "tenant-b.logs.>", Name: "foreign-export"},
	})
	if err == nil {
		t.Fatal("CreateAccount() expected error for out-of-scope export, got nil")
	}
	if !strings.Contains(err.Error(), ErrSubjectOutOfScope.Error()) {
		t.Fatalf("expected ErrSubjectOutOfScope, got %v", err)
	}
}

func TestAccountSigner_SignAccountJWT_RejectsImports(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	result, err := signer.CreateAccount("tenant-a", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
	}

	_, _, err = signer.SignAccountJWT("tenant-a", result.AccountSeed, nil, nil, nil, []StreamImport{
		{
			Subject:          "platform.provisioning.>",
			AccountPublicKey: "ACYXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
		},
	}, nil)
	if err == nil {
		t.Fatal("SignAccountJWT() expected error for stream import, got nil")
	}
	if !strings.Contains(err.Error(), ErrImportNotAllowed.Error()) {
		t.Fatalf("expected ErrImportNotAllowed, got %v", err)
	}
}

func TestAccountSigner_SignAccountJWT(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// First create an account
	result, err := signer.CreateAccount("test-ns", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
	}

	// Now re-sign with updated limits
	newLimits := &AccountLimits{
		MaxConnections: 50,
	}

	pubKey, newJWT, err := signer.SignAccountJWT("test-ns", result.AccountSeed, newLimits, nil, nil, nil, nil)
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
	result, err := signer.CreateAccount("test-ns", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
	}

	// Generate some user keys to revoke
	_, userPubKey1, _ := GenerateUserKey()
	_, userPubKey2, _ := GenerateUserKey()

	revokedKeys := []string{userPubKey1, userPubKey2}

	// Re-sign with revocations
	_, newJWT, err := signer.SignAccountJWT("test-ns", result.AccountSeed, nil, nil, nil, nil, revokedKeys)
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

	_, _, err := signer.SignAccountJWT("test-ns", "invalid-seed", nil, nil, nil, nil, nil)
	if err == nil {
		t.Error("SignAccountJWT() expected error for invalid seed, got nil")
	}
}

func TestAccountSigner_SignAccountJWT_WrongKeyType(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Use a user seed instead of account seed
	userSeed, _, _ := GenerateUserKey()

	_, _, err := signer.SignAccountJWT("test-ns", userSeed, nil, nil, nil, nil, nil)
	if err == nil {
		t.Error("SignAccountJWT() expected error for wrong key type, got nil")
	}
}

func TestAccountSigner_CanRecreateFromSeed(t *testing.T) {
	op := newTestOperator(t)
	signer := NewAccountSigner(op)

	// Create an account
	result, err := signer.CreateAccount("test-ns", nil, nil, nil)
	if err != nil {
		t.Fatalf("CreateAccount() error = %v", err)
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
	accountNames := []string{"account-a", "account-b", "account-c"}
	if testing.Short() {
		accountNames = accountNames[:2]
	}
	results := make(map[string]*AccountResult)

	for _, name := range accountNames {
		result, err := signer.CreateAccount(name, nil, nil, nil)
		if err != nil {
			t.Fatalf("CreateAccount(%q) error = %v", name, err)
		}
		results[name] = result
	}

	// Verify all accounts have unique keys
	seen := make(map[string]bool)
	for name, result := range results {
		if seen[result.AccountPublicKey] {
			t.Errorf("Duplicate public key for account %q", name)
		}
		seen[result.AccountPublicKey] = true

		if seen[result.AccountSeed] {
			t.Errorf("Duplicate seed for account %q", name)
		}
		seen[result.AccountSeed] = true
	}
}
