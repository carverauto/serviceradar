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
	"os"
	"path/filepath"
	"testing"

	"github.com/nats-io/nkeys"
)

func TestGenerateOperatorKey(t *testing.T) {
	if testing.Short() {
		t.Skip("key generation is covered in long tests")
	}

	seed, publicKey, err := GenerateOperatorKey()
	if err != nil {
		t.Fatalf("GenerateOperatorKey() error = %v", err)
	}

	// Verify seed starts with SO (operator seed prefix)
	if len(seed) < 2 || seed[:2] != "SO" {
		t.Errorf("GenerateOperatorKey() seed = %q, want prefix 'SO'", seed[:2])
	}

	// Verify public key starts with O (operator public key prefix)
	if len(publicKey) < 1 || publicKey[0] != 'O' {
		t.Errorf("GenerateOperatorKey() publicKey = %q, want prefix 'O'", publicKey[:1])
	}

	// Verify the key pair is valid
	if !nkeys.IsValidPublicOperatorKey(publicKey) {
		t.Error("GenerateOperatorKey() publicKey is not a valid operator key")
	}

	// Verify we can recreate the key pair from seed
	kp, err := nkeys.FromSeed([]byte(seed))
	if err != nil {
		t.Fatalf("nkeys.FromSeed() error = %v", err)
	}

	derivedPubKey, err := kp.PublicKey()
	if err != nil {
		t.Fatalf("kp.PublicKey() error = %v", err)
	}

	if derivedPubKey != publicKey {
		t.Errorf("Derived public key = %q, want %q", derivedPubKey, publicKey)
	}
}

func TestGenerateAccountKey(t *testing.T) {
	if testing.Short() {
		t.Skip("key generation is covered in long tests")
	}

	seed, publicKey, err := GenerateAccountKey()
	if err != nil {
		t.Fatalf("GenerateAccountKey() error = %v", err)
	}

	// Verify seed starts with SA (account seed prefix)
	if len(seed) < 2 || seed[:2] != "SA" {
		t.Errorf("GenerateAccountKey() seed = %q, want prefix 'SA'", seed[:2])
	}

	// Verify public key starts with A (account public key prefix)
	if len(publicKey) < 1 || publicKey[0] != 'A' {
		t.Errorf("GenerateAccountKey() publicKey = %q, want prefix 'A'", publicKey[:1])
	}

	// Verify the key pair is valid
	if !nkeys.IsValidPublicAccountKey(publicKey) {
		t.Error("GenerateAccountKey() publicKey is not a valid account key")
	}
}

func TestGenerateUserKey(t *testing.T) {
	if testing.Short() {
		t.Skip("key generation is covered in long tests")
	}

	seed, publicKey, err := GenerateUserKey()
	if err != nil {
		t.Fatalf("GenerateUserKey() error = %v", err)
	}

	// Verify seed starts with SU (user seed prefix)
	if len(seed) < 2 || seed[:2] != "SU" {
		t.Errorf("GenerateUserKey() seed = %q, want prefix 'SU'", seed[:2])
	}

	// Verify public key starts with U (user public key prefix)
	if len(publicKey) < 1 || publicKey[0] != 'U' {
		t.Errorf("GenerateUserKey() publicKey = %q, want prefix 'U'", publicKey[:1])
	}

	// Verify the key pair is valid
	if !nkeys.IsValidPublicUserKey(publicKey) {
		t.Error("GenerateUserKey() publicKey is not a valid user key")
	}
}

func TestNewOperator_DirectSeed(t *testing.T) {
	// Generate a test operator key
	seed := testOperatorSeed
	expectedPubKey := testOperatorPublicKey(t)

	cfg := &OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: seed,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	if op.Name() != "test-operator" {
		t.Errorf("Operator.Name() = %q, want %q", op.Name(), "test-operator")
	}

	if op.PublicKey() != expectedPubKey {
		t.Errorf("Operator.PublicKey() = %q, want %q", op.PublicKey(), expectedPubKey)
	}
}

func TestNewOperator_FromFile(t *testing.T) {
	// Generate a test operator key
	seed := testOperatorSeed
	expectedPubKey := testOperatorPublicKey(t)

	// Write seed to temp file
	tmpDir := t.TempDir()
	seedFile := filepath.Join(tmpDir, "operator.seed")
	if err := os.WriteFile(seedFile, []byte(seed), 0600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	cfg := &OperatorConfig{
		Name:             "test-operator-file",
		OperatorSeedFile: seedFile,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	if op.PublicKey() != expectedPubKey {
		t.Errorf("Operator.PublicKey() = %q, want %q", op.PublicKey(), expectedPubKey)
	}
}

func TestNewOperator_FromEnv(t *testing.T) {
	// Generate a test operator key
	seed := testOperatorSeed
	expectedPubKey := testOperatorPublicKey(t)

	// Set environment variable
	envVar := "TEST_NATS_OPERATOR_SEED"
	t.Setenv(envVar, seed)

	cfg := &OperatorConfig{
		Name:            "test-operator-env",
		OperatorSeedEnv: envVar,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	if op.PublicKey() != expectedPubKey {
		t.Errorf("Operator.PublicKey() = %q, want %q", op.PublicKey(), expectedPubKey)
	}
}

func TestNewOperator_SystemAccountPublicKeyFromEnv(t *testing.T) {
	seed := testOperatorSeed
	systemPubKey := testAccountPublicKey(t)

	envVar := "TEST_NATS_SYSTEM_ACCOUNT_PUBLIC_KEY"
	t.Setenv(envVar, systemPubKey)

	cfg := &OperatorConfig{
		Name:                      "test-operator-system-env",
		OperatorSeed:              seed,
		SystemAccountPublicKeyEnv: envVar,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	if op.SystemAccountPublicKey() != systemPubKey {
		t.Errorf("Operator.SystemAccountPublicKey() = %q, want %q", op.SystemAccountPublicKey(), systemPubKey)
	}
}

func TestNewOperator_SystemAccountPublicKeyFromFile(t *testing.T) {
	seed := testOperatorSeed
	systemPubKey := testAccountPublicKey(t)

	tmpDir := t.TempDir()
	pubKeyFile := filepath.Join(tmpDir, "system_account.pub")
	if err := os.WriteFile(pubKeyFile, []byte(systemPubKey), 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	cfg := &OperatorConfig{
		Name:                       "test-operator-system-file",
		OperatorSeed:               seed,
		SystemAccountPublicKeyFile: pubKeyFile,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	if op.SystemAccountPublicKey() != systemPubKey {
		t.Errorf("Operator.SystemAccountPublicKey() = %q, want %q", op.SystemAccountPublicKey(), systemPubKey)
	}
}

func TestNewOperator_InvalidSeed(t *testing.T) {
	cfg := &OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: "invalid-seed",
	}

	_, err := NewOperator(cfg)
	if err == nil {
		t.Error("NewOperator() expected error for invalid seed, got nil")
	}
}

func TestNewOperator_WrongKeyType(t *testing.T) {
	// Generate an account key (not operator)
	seed := testAccountSeed

	cfg := &OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: seed, // Account seed, not operator seed
	}

	_, err := NewOperator(cfg)
	if err == nil {
		t.Error("NewOperator() expected error for wrong key type, got nil")
	}
}

func TestNewOperator_NoSeed(t *testing.T) {
	cfg := &OperatorConfig{
		Name: "test-operator",
		// No seed provided
	}

	_, err := NewOperator(cfg)
	if err == nil {
		t.Error("NewOperator() expected error for missing seed, got nil")
	}
}

func TestOperator_CreateOperatorJWT(t *testing.T) {
	seed := testOperatorSeed

	cfg := &OperatorConfig{
		Name:         "test-operator",
		OperatorSeed: seed,
	}

	op, err := NewOperator(cfg)
	if err != nil {
		t.Fatalf("NewOperator() error = %v", err)
	}

	jwt, err := op.CreateOperatorJWT()
	if err != nil {
		t.Fatalf("CreateOperatorJWT() error = %v", err)
	}

	// Verify JWT is not empty and has proper structure (3 parts separated by .)
	if jwt == "" {
		t.Error("CreateOperatorJWT() returned empty JWT")
	}

	parts := 0
	for _, c := range jwt {
		if c == '.' {
			parts++
		}
	}
	if parts != 2 {
		t.Errorf("CreateOperatorJWT() JWT has %d dots, want 2", parts)
	}
}

func TestEncodeDecodeKeyForStorage(t *testing.T) {
	seed := testOperatorSeed

	encoded := EncodeKeyForStorage(seed)
	if encoded == seed {
		t.Error("EncodeKeyForStorage() should produce different output")
	}

	decoded, err := DecodeKeyFromStorage(encoded)
	if err != nil {
		t.Fatalf("DecodeKeyFromStorage() error = %v", err)
	}

	if decoded != seed {
		t.Errorf("DecodeKeyFromStorage() = %q, want %q", decoded, seed)
	}
}

func TestDecodeKeyFromStorage_Invalid(t *testing.T) {
	_, err := DecodeKeyFromStorage("not-valid-base64!!!")
	if err == nil {
		t.Error("DecodeKeyFromStorage() expected error for invalid base64, got nil")
	}
}
