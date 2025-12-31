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

// Package accounts provides NATS account and user management for multi-tenant isolation.
// It uses NATS JWT and NKeys for cryptographic identity and authorization.
package accounts

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
)

var (
	// ErrOperatorKeyNotFound is returned when the operator key cannot be loaded.
	ErrOperatorKeyNotFound = errors.New("operator key not found")
	// ErrOperatorKeyInvalid is returned when the operator key is invalid.
	ErrOperatorKeyInvalid = errors.New("operator key invalid")
	// ErrSystemAccountNotFound is returned when system account is required but not configured.
	ErrSystemAccountNotFound = errors.New("system account not found")
	// ErrOperatorAlreadyInitialized is returned when trying to bootstrap an already initialized operator.
	ErrOperatorAlreadyInitialized = errors.New("operator already initialized")
	// ErrOperatorNotInitialized is returned when operations require an initialized operator.
	ErrOperatorNotInitialized = errors.New("operator not initialized")
)

// OperatorConfig holds the configuration for the NATS operator.
type OperatorConfig struct {
	// Name is the operator name (e.g., "serviceradar").
	Name string `json:"name"`

	// OperatorSeed is the operator's private seed key (starts with "SO").
	// Can be loaded from environment, file, or Vault.
	OperatorSeed string `json:"operator_seed,omitempty"`

	// OperatorSeedFile is the path to a file containing the operator seed.
	OperatorSeedFile string `json:"operator_seed_file,omitempty"`

	// OperatorSeedEnv is the environment variable containing the operator seed.
	OperatorSeedEnv string `json:"operator_seed_env,omitempty"`

	// SystemAccountPublicKey is the public key of the system account (starts with "A").
	// Required for pushing account JWTs to the NATS server.
	SystemAccountPublicKey string `json:"system_account_public_key,omitempty"`
}

// Operator manages NATS operator keys and signing operations.
type Operator struct {
	name                   string
	kp                     nkeys.KeyPair
	publicKey              string
	systemAccountPublicKey string
}

// NewOperator creates a new Operator from the given configuration.
func NewOperator(cfg *OperatorConfig) (*Operator, error) {
	seed, err := loadOperatorSeed(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to load operator seed: %w", err)
	}

	kp, err := nkeys.FromSeed([]byte(seed))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrOperatorKeyInvalid, err)
	}

	// Verify it's an operator key (prefix 'O')
	publicKey, err := kp.PublicKey()
	if err != nil {
		return nil, fmt.Errorf("failed to get operator public key: %w", err)
	}

	if !nkeys.IsValidPublicOperatorKey(publicKey) {
		return nil, fmt.Errorf("%w: not an operator key", ErrOperatorKeyInvalid)
	}

	return &Operator{
		name:                   cfg.Name,
		kp:                     kp,
		publicKey:              publicKey,
		systemAccountPublicKey: cfg.SystemAccountPublicKey,
	}, nil
}

// loadOperatorSeed loads the operator seed from various sources in order of preference.
func loadOperatorSeed(cfg *OperatorConfig) (string, error) {
	// 1. Direct seed value
	if cfg.OperatorSeed != "" {
		return strings.TrimSpace(cfg.OperatorSeed), nil
	}

	// 2. Environment variable
	if cfg.OperatorSeedEnv != "" {
		if seed := os.Getenv(cfg.OperatorSeedEnv); seed != "" {
			return strings.TrimSpace(seed), nil
		}
	}

	// 3. File
	if cfg.OperatorSeedFile != "" {
		data, err := os.ReadFile(cfg.OperatorSeedFile)
		if err != nil {
			return "", fmt.Errorf("failed to read operator seed file: %w", err)
		}
		return strings.TrimSpace(string(data)), nil
	}

	return "", ErrOperatorKeyNotFound
}

// PublicKey returns the operator's public key.
func (o *Operator) PublicKey() string {
	return o.publicKey
}

// Name returns the operator's name.
func (o *Operator) Name() string {
	return o.name
}

// SystemAccountPublicKey returns the system account's public key.
func (o *Operator) SystemAccountPublicKey() string {
	return o.systemAccountPublicKey
}

// SignAccountClaims signs account claims with the operator key and returns a JWT.
func (o *Operator) SignAccountClaims(claims *jwt.AccountClaims) (string, error) {
	// Set the issuer to the operator's public key
	claims.Issuer = o.publicKey

	token, err := claims.Encode(o.kp)
	if err != nil {
		return "", fmt.Errorf("failed to sign account claims: %w", err)
	}

	return token, nil
}

// CreateOperatorJWT creates and signs an operator JWT.
// This is typically only needed during initial bootstrap.
func (o *Operator) CreateOperatorJWT() (string, error) {
	claims := jwt.NewOperatorClaims(o.publicKey)
	claims.Name = o.name

	if o.systemAccountPublicKey != "" {
		claims.SystemAccount = o.systemAccountPublicKey
	}

	token, err := claims.Encode(o.kp)
	if err != nil {
		return "", fmt.Errorf("failed to encode operator JWT: %w", err)
	}

	return token, nil
}

// GenerateOperatorKey generates a new operator key pair and returns the seed.
// This is a utility function for bootstrapping new operators.
func GenerateOperatorKey() (seed string, publicKey string, err error) {
	kp, err := nkeys.CreateOperator()
	if err != nil {
		return "", "", fmt.Errorf("failed to create operator key: %w", err)
	}

	seedBytes, err := kp.Seed()
	if err != nil {
		return "", "", fmt.Errorf("failed to get operator seed: %w", err)
	}

	pubKey, err := kp.PublicKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to get operator public key: %w", err)
	}

	return string(seedBytes), pubKey, nil
}

// GenerateAccountKey generates a new account key pair and returns the seed.
func GenerateAccountKey() (seed string, publicKey string, err error) {
	kp, err := nkeys.CreateAccount()
	if err != nil {
		return "", "", fmt.Errorf("failed to create account key: %w", err)
	}

	seedBytes, err := kp.Seed()
	if err != nil {
		return "", "", fmt.Errorf("failed to get account seed: %w", err)
	}

	pubKey, err := kp.PublicKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to get account public key: %w", err)
	}

	return string(seedBytes), pubKey, nil
}

// GenerateUserKey generates a new user key pair and returns the seed.
func GenerateUserKey() (seed string, publicKey string, err error) {
	kp, err := nkeys.CreateUser()
	if err != nil {
		return "", "", fmt.Errorf("failed to create user key: %w", err)
	}

	seedBytes, err := kp.Seed()
	if err != nil {
		return "", "", fmt.Errorf("failed to get user seed: %w", err)
	}

	pubKey, err := kp.PublicKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to get user public key: %w", err)
	}

	return string(seedBytes), pubKey, nil
}

// EncodeKeyForStorage encodes a key seed for secure storage (base64).
func EncodeKeyForStorage(seed string) string {
	return base64.StdEncoding.EncodeToString([]byte(seed))
}

// DecodeKeyFromStorage decodes a key seed from storage (base64).
func DecodeKeyFromStorage(encoded string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", fmt.Errorf("failed to decode key: %w", err)
	}
	return string(data), nil
}

// BootstrapResult contains the result of bootstrapping an operator.
type BootstrapResult struct {
	// OperatorPublicKey is the operator's public key (starts with 'O').
	OperatorPublicKey string
	// OperatorSeed is the operator's private seed (starts with 'SO').
	// Only set if a new operator was generated (not imported).
	OperatorSeed string
	// OperatorJWT is the signed operator JWT.
	OperatorJWT string
	// SystemAccountPublicKey is the system account's public key (starts with 'A').
	// Only set if generate_system_account was true.
	SystemAccountPublicKey string
	// SystemAccountSeed is the system account's private seed (starts with 'SA').
	// Only set if a new system account was generated.
	SystemAccountSeed string
	// SystemAccountJWT is the signed system account JWT.
	// Only set if generate_system_account was true.
	SystemAccountJWT string
}

// BootstrapOperator initializes a new operator or imports an existing one.
// If existingSeed is provided, it imports that seed instead of generating a new one.
// If generateSystemAccount is true, it also creates the system account.
func BootstrapOperator(name string, existingSeed string, generateSystemAccount bool) (*Operator, *BootstrapResult, error) {
	var operatorSeed, operatorPublicKey string
	var operatorKp nkeys.KeyPair
	var err error
	var seedGenerated bool

	if existingSeed != "" {
		// Import existing operator seed
		operatorSeed = strings.TrimSpace(existingSeed)
		operatorKp, err = nkeys.FromSeed([]byte(operatorSeed))
		if err != nil {
			return nil, nil, fmt.Errorf("%w: failed to parse operator seed: %v", ErrOperatorKeyInvalid, err)
		}
		operatorPublicKey, err = operatorKp.PublicKey()
		if err != nil {
			return nil, nil, fmt.Errorf("failed to get operator public key: %w", err)
		}
		if !nkeys.IsValidPublicOperatorKey(operatorPublicKey) {
			return nil, nil, fmt.Errorf("%w: not an operator key", ErrOperatorKeyInvalid)
		}
		seedGenerated = false
	} else {
		// Generate new operator
		operatorSeed, operatorPublicKey, err = GenerateOperatorKey()
		if err != nil {
			return nil, nil, fmt.Errorf("failed to generate operator key: %w", err)
		}
		operatorKp, err = nkeys.FromSeed([]byte(operatorSeed))
		if err != nil {
			return nil, nil, fmt.Errorf("failed to parse generated operator seed: %w", err)
		}
		seedGenerated = true
	}

	result := &BootstrapResult{
		OperatorPublicKey: operatorPublicKey,
	}

	// Only return seed if we generated it
	if seedGenerated {
		result.OperatorSeed = operatorSeed
	}

	var systemAccountPublicKey string

	// Generate system account if requested
	if generateSystemAccount {
		sysAccountSeed, sysAccountPubKey, err := GenerateAccountKey()
		if err != nil {
			return nil, nil, fmt.Errorf("failed to generate system account key: %w", err)
		}

		systemAccountPublicKey = sysAccountPubKey
		result.SystemAccountPublicKey = sysAccountPubKey
		result.SystemAccountSeed = sysAccountSeed

		// Sign the system account JWT
		sysAccountKp, err := nkeys.FromSeed([]byte(sysAccountSeed))
		if err != nil {
			return nil, nil, fmt.Errorf("failed to parse system account seed: %w", err)
		}

		sysAccountClaims := jwt.NewAccountClaims(sysAccountPubKey)
		sysAccountClaims.Name = "SYS"
		sysAccountClaims.Issuer = operatorPublicKey

		// System account needs specific exports for monitoring
		sysAccountClaims.Exports = jwt.Exports{
			&jwt.Export{
				Name:    "account-monitoring-services",
				Subject: "$SYS.REQ.ACCOUNT.*.*",
				Type:    jwt.Service,
			},
			&jwt.Export{
				Name:    "account-monitoring-streams",
				Subject: "$SYS.ACCOUNT.*.>",
				Type:    jwt.Stream,
			},
		}

		sysAccountJWT, err := sysAccountClaims.Encode(operatorKp)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to sign system account JWT: %w", err)
		}
		result.SystemAccountJWT = sysAccountJWT

		// We don't need the account key pair anymore, but verify it's valid
		_ = sysAccountKp
	}

	// Create the operator
	op := &Operator{
		name:                   name,
		kp:                     operatorKp,
		publicKey:              operatorPublicKey,
		systemAccountPublicKey: systemAccountPublicKey,
	}

	// Sign the operator JWT
	operatorJWT, err := op.CreateOperatorJWT()
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create operator JWT: %w", err)
	}
	result.OperatorJWT = operatorJWT

	return op, result, nil
}

// IsInitialized returns true if the operator has been properly initialized.
func (o *Operator) IsInitialized() bool {
	return o != nil && o.kp != nil && o.publicKey != ""
}
