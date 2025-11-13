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

package config

import (
	"bytes"
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"os"
	"reflect"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/config/kvgrpc"
	coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// KVManager handles KV store operations for configuration management
type KVManager struct {
	client kv.KVStore
}

var (
	errKVClientUnavailable   = errors.New("KV client is unavailable")
	errKVKeyEmpty            = errors.New("KV key is required")
	errDecodePrivateKeyPEM   = errors.New("failed to decode private key PEM")
	errUnsupportedPrivateKey = errors.New("unsupported private key type")
)

const (
	defaultKVConnectTimeout     = 2 * time.Minute
	defaultKVConnectBaseBackoff = 500 * time.Millisecond
	defaultKVConnectMaxBackoff  = 10 * time.Second
)

type kvClientFactoryFunc func(context.Context, models.ServiceRole) (kv.KVStore, error)

type kvClientFactoryContextKey struct{}

// withKVClientFactory injects a custom KV client factory into ctx (primarily for tests).
func withKVClientFactory(ctx context.Context, factory kvClientFactoryFunc) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithValue(ctx, kvClientFactoryContextKey{}, factory)
}

// kvClientFactoryFromContext returns either the injected factory or the default creator.
func kvClientFactoryFromContext(ctx context.Context) kvClientFactoryFunc {
	if ctx == nil {
		return createKVClientFromEnv
	}
	if factory, ok := ctx.Value(kvClientFactoryContextKey{}).(kvClientFactoryFunc); ok && factory != nil {
		return factory
	}
	return createKVClientFromEnv
}

// NewKVManagerFromEnv creates a KV manager from environment variables.
func NewKVManagerFromEnv(ctx context.Context, role models.ServiceRole) (*KVManager, error) {
	if !ShouldUseKVFromEnv() {
		return nil, nil
	}

	client, err := kvClientFactoryFromContext(ctx)(ctx, role)
	if err != nil {
		return nil, err
	}
	if client == nil {
		return nil, nil
	}

	return &KVManager{client: client}, nil
}

// NewKVManagerFromEnvWithRetry blocks until a KV manager can be created or the configured timeout expires.
func NewKVManagerFromEnvWithRetry(ctx context.Context, role models.ServiceRole, log logger.Logger) (*KVManager, error) {
	if !ShouldUseKVFromEnv() {
		return nil, nil
	}

	if log == nil {
		log = logger.NewTestLogger()
	}

	timeout := durationFromEnv("KV_CONNECT_TIMEOUT", defaultKVConnectTimeout)
	baseBackoff := durationFromEnv("KV_CONNECT_RETRY_BASE", defaultKVConnectBaseBackoff)
	maxBackoff := durationFromEnv("KV_CONNECT_RETRY_MAX", defaultKVConnectMaxBackoff)

	if timeout <= 0 {
		timeout = defaultKVConnectTimeout
	}
	if baseBackoff <= 0 {
		baseBackoff = defaultKVConnectBaseBackoff
	}
	if maxBackoff <= 0 {
		maxBackoff = defaultKVConnectMaxBackoff
	}

	deadline := time.Now().Add(timeout)
	attempt := 0
	var lastErr error

	for {
		attempt++
		manager, err := NewKVManagerFromEnv(ctx, role)
		if err == nil && manager != nil {
			if attempt > 1 {
				log.Info().
					Int("attempt", attempt).
					Msg("connected to KV service after retry")
			}
			return manager, nil
		}
		if err == nil && manager == nil {
			// Environment changed while waiting; KV is no longer configured.
			return nil, nil
		}

		lastErr = err
		log.Warn().
			Err(err).
			Int("attempt", attempt).
			Msg("KV connection attempt failed; retrying")

		wait := baseBackoff << (attempt - 1)
		if wait > maxBackoff {
			wait = maxBackoff
		}

		select {
		case <-time.After(wait):
		case <-ctx.Done():
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		}

		if time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for KV connection after %d attempts: %w", attempt, lastErr)
		}
	}
}

// SetupConfigLoader configures a Config instance with KV store if available
func (m *KVManager) SetupConfigLoader(cfgLoader *Config) {
	if m != nil && m.client != nil {
		cfgLoader.SetKVStore(m.client)
	}
}

// LoadAndOverlay loads config from file and overlays KV values
func (m *KVManager) LoadAndOverlay(ctx context.Context, cfgLoader *Config, configPath string, cfg interface{}) error {
	if err := cfgLoader.LoadAndValidate(ctx, configPath, cfg); err != nil {
		return err
	}

	if m != nil && m.client != nil {
		_ = m.OverlayConfig(ctx, defaultKVKeyFromPath(configPath), cfg)
	}

	return nil
}

// OverlayConfig merges the KV entry identified by kvKey onto the provided config struct.
func (m *KVManager) OverlayConfig(ctx context.Context, kvKey string, cfg interface{}) error {
	if m == nil || m.client == nil || kvKey == "" || cfg == nil {
		return nil
	}

	data, found, err := m.client.Get(ctx, kvKey)
	if err != nil || !found || len(data) == 0 {
		return err
	}

	var overlay interface{}
	if err := json.Unmarshal(data, &overlay); err != nil {
		return err
	}

	sanitized, err := json.Marshal(overlay)
	if err != nil {
		return err
	}

	if err := MergeOverlayBytes(cfg, sanitized); err != nil {
		return err
	}

	cfgLoader := NewConfig(nil)
	if err := cfgLoader.normalizeSecurityConfig(cfg); err != nil {
		return err
	}

	return ValidateConfig(cfg)
}

// LoadAndOverlayOrExit loads config and exits with cleanup on error
func LoadAndOverlayOrExit(ctx context.Context, kvMgr *KVManager, cfgLoader *Config, configPath string, cfg interface{}, errorMsg string) {
	var err error
	if kvMgr != nil {
		err = kvMgr.LoadAndOverlay(ctx, cfgLoader, configPath, cfg)
	} else {
		err = cfgLoader.LoadAndValidate(ctx, configPath, cfg)
	}

	if err != nil {
		if kvMgr != nil {
			_ = kvMgr.Close()
		}
		log.Fatalf("%s: %v", errorMsg, err)
	}
}

// BootstrapConfig stores default config in KV if it doesn't exist.
// It prefers reading sanitized defaults from the on-disk config file to keep
// the canonical KV copy aligned with baked manifests.
func (m *KVManager) BootstrapConfig(ctx context.Context, kvKey string, configPath string, cfg interface{}) error {
	if m == nil || m.client == nil || kvKey == "" || cfg == nil {
		return nil
	}

	data, err := sanitizeBootstrapSource(configPath, cfg)
	if err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}

	value, found, err := m.client.Get(ctx, kvKey)
	if err != nil {
		return err
	}
	if found && len(value) > 0 {
		return nil
	}

	return m.client.Put(ctx, kvKey, data, 0)
}

// Put writes arbitrary data to the backing KV store using the manager's credentials.
func (m *KVManager) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	if m == nil || m.client == nil {
		return errKVClientUnavailable
	}
	if key == "" {
		return errKVKeyEmpty
	}
	return m.client.Put(ctx, key, value, ttl)
}

// PutIfAbsent writes the provided value only if the key does not already exist.
// Returns true when the key was created.
func (m *KVManager) PutIfAbsent(ctx context.Context, key string, value []byte, ttl time.Duration) (bool, error) {
	if m == nil || m.client == nil {
		return false, errKVClientUnavailable
	}
	if key == "" {
		return false, errKVKeyEmpty
	}

	err := m.client.Create(ctx, key, value, ttl)
	if err != nil {
		if errors.Is(err, kv.ErrKeyExists) {
			return false, nil
		}
		return false, err
	}

	return true, nil
}

func defaultKVKeyFromPath(configPath string) string {
	if configPath == "" {
		return ""
	}
	idx := strings.LastIndex(configPath, "/")
	if idx >= 0 && idx < len(configPath)-1 {
		return fmt.Sprintf("config/%s", configPath[idx+1:])
	}
	return fmt.Sprintf("config/%s", configPath)
}

// sanitizeBootstrapSource prefers sanitizing the on-disk config file so the KV
// defaults reflect what operators see in manifests. It falls back to the in-
// memory config struct if the file cannot be parsed.
func sanitizeBootstrapSource(configPath string, cfg interface{}) ([]byte, error) {
	ensureJWTPublicKey(cfg)

	if configPath == "" {
		return sanitizeForKV(cfg)
	}

	payload, err := os.ReadFile(configPath)
	if err != nil {
		return sanitizeForKV(cfg)
	}

	clone := cloneConfig(cfg)
	if clone == nil {
		return sanitizeForKV(cfg)
	}

	if err := json.Unmarshal(payload, clone); err != nil {
		return sanitizeForKV(cfg)
	}

	ensureJWTPublicKeyWithFallback(clone, cfg)

	return sanitizeForKV(clone)
}

func cloneConfig(cfg interface{}) interface{} {
	if cfg == nil {
		return nil
	}

	t := reflect.TypeOf(cfg)
	if t.Kind() != reflect.Ptr {
		return nil
	}

	return reflect.New(t.Elem()).Interface()
}

func ensureJWTPublicKey(cfg interface{}) {
	ensureJWTPublicKeyWithFallback(cfg, nil)
}

func ensureJWTPublicKeyWithFallback(cfg interface{}, fallback interface{}) {
	authCfg := extractAuthConfig(cfg)
	if authCfg == nil {
		return
	}

	if strings.ToUpper(authCfg.JWTAlgorithm) != "RS256" {
		return
	}

	if authCfg.JWTPublicKeyPEM != "" {
		return
	}

	priv := authCfg.JWTPrivateKeyPEM
	keyID := authCfg.JWTKeyID

	if priv == "" && fallback != nil {
		if fbAuth := extractAuthConfig(fallback); fbAuth != nil {
			priv = fbAuth.JWTPrivateKeyPEM
			if keyID == "" {
				keyID = fbAuth.JWTKeyID
			}
		}
	}

	if priv == "" {
		return
	}

	if pub, err := derivePublicKeyPEM(priv); err == nil {
		authCfg.JWTPublicKeyPEM = pub

		if authCfg.JWTKeyID == "" && keyID != "" {
			authCfg.JWTKeyID = keyID
		}
	}
}

func extractAuthConfig(cfg interface{}) *models.AuthConfig {
	if cfg == nil {
		return nil
	}
	rv := reflect.ValueOf(cfg)
	if rv.Kind() != reflect.Ptr || rv.IsNil() {
		return nil
	}
	elem := rv.Elem()
	if elem.Kind() != reflect.Struct {
		return nil
	}
	authType := reflect.TypeOf(&models.AuthConfig{})
	for i := 0; i < elem.NumField(); i++ {
		field := elem.Field(i)
		if field.Type() == authType && !field.IsNil() {
			if auth, ok := field.Interface().(*models.AuthConfig); ok {
				return auth
			}
		}
	}
	return nil
}

func derivePublicKeyPEM(privatePEM string) (string, error) {
	block, _ := pem.Decode([]byte(privatePEM))
	if block == nil {
		return "", errDecodePrivateKeyPEM
	}
	if isEncryptedPEMBlock(block) {
		return "", errUnsupportedPrivateKey
	}

	var rsaKey *rsa.PrivateKey

	switch block.Type {
	case "PRIVATE KEY":
		key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return "", err
		}
		if k, ok := key.(*rsa.PrivateKey); ok {
			rsaKey = k
		} else {
			return "", errUnsupportedPrivateKey
		}
	case "RSA PRIVATE KEY":
		key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return "", err
		}
		rsaKey = key
	default:
		return "", errUnsupportedPrivateKey
	}

	pubDER, err := x509.MarshalPKIXPublicKey(&rsaKey.PublicKey)
	if err != nil {
		return "", err
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})), nil
}

func isEncryptedPEMBlock(block *pem.Block) bool {
	if block == nil {
		return false
	}
	procType := block.Headers["Proc-Type"]
	return strings.EqualFold(procType, "4,ENCRYPTED")
}

// StartWatch sets up KV watching with hot-reload functionality
func (m *KVManager) StartWatch(ctx context.Context, kvKey string, cfg interface{}, logger logger.Logger, onReload func()) {
	if m == nil || m.client == nil {
		return
	}

	prevSnapshot, err := newConfigSnapshot(cfg)
	if err != nil && logger != nil {
		logger.Warn().Err(err).Str("key", kvKey).Msg("Failed to snapshot initial config for KV watch")
	}

	StartKVWatchOverlay(ctx, m.client, kvKey, cfg, logger, func() {
		currSnapshot, snapErr := newConfigSnapshot(cfg)
		if snapErr != nil {
			if logger != nil {
				logger.Warn().Err(snapErr).Str("key", kvKey).Msg("Failed to snapshot config after KV overlay")
			}
			return
		}

		if prevSnapshot != nil && bytes.Equal(prevSnapshot.raw, currSnapshot.raw) {
			// No actual change after overlay; skip reload.
			return
		}

		triggers := map[string]bool{"reload": true, "rebuild": true}
		var changed []string
		if prevSnapshot != nil {
			changed = FieldsChangedByTag(prevSnapshot.value, currSnapshot.value, "hot", triggers)
		}
		if len(changed) == 0 {
			changed = []string{"*"}
		}

		if len(changed) > 0 {
			if logger != nil {
				logger.Info().Strs("changed_fields", changed).Msg("Applying hot-reload")
			}
			if onReload != nil {
				onReload()
			}
			prevSnapshot = currSnapshot
		}
	})
}

type configSnapshot struct {
	raw   []byte
	value interface{}
}

func newConfigSnapshot(cfg interface{}) (*configSnapshot, error) {
	if cfg == nil {
		return nil, nil
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}

	cloneTarget, err := cloneConfigValue(cfg)
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(raw, cloneTarget); err != nil {
		return nil, err
	}

	return &configSnapshot{
		raw:   raw,
		value: cloneTarget,
	}, nil
}

func cloneConfigValue(cfg interface{}) (interface{}, error) {
	val := reflect.ValueOf(cfg)
	if !val.IsValid() {
		return nil, nil
	}

	switch val.Kind() {
	case reflect.Ptr:
		if val.IsNil() {
			return nil, nil
		}
		elem := val.Elem()
		clone := reflect.New(elem.Type())
		return clone.Interface(), nil
	case reflect.Struct:
		clone := reflect.New(val.Type())
		return clone.Interface(), nil
	default:
		return nil, fmt.Errorf("unsupported config type %T", cfg)
	}
}

// Close closes the KV client connection
func (m *KVManager) Close() error {
	if m == nil || m.client == nil {
		return nil
	}
	return m.client.Close()
}

// createKVClientFromEnv creates a KV client from environment variables
func createKVClientFromEnv(ctx context.Context, role models.ServiceRole) (kv.KVStore, error) {
	client, closer, err := NewKVServiceClientFromEnv(ctx, role)
	if err != nil {
		if closer != nil {
			_ = closer()
		}
		return nil, err
	}
	if client == nil {
		if closer != nil {
			_ = closer()
		}
		return nil, nil
	}
	return kvgrpc.New(client, closer), nil
}

// NewKVServiceClientFromEnv dials the remote KV service using environment variables suitable for the given role.
// Returns nil without error when the environment is not configured for KV access.
func NewKVServiceClientFromEnv(ctx context.Context, role models.ServiceRole) (proto.KVServiceClient, func() error, error) {
	addr := os.Getenv("KV_ADDRESS")
	if addr == "" {
		return nil, nil, nil
	}

	secMode := strings.ToLower(strings.TrimSpace(os.Getenv("KV_SEC_MODE")))
	var sec *models.SecurityConfig

	switch secMode {
	case "mtls":
		cert := strings.TrimSpace(os.Getenv("KV_CERT_FILE"))
		key := strings.TrimSpace(os.Getenv("KV_KEY_FILE"))
		ca := strings.TrimSpace(os.Getenv("KV_CA_FILE"))
		if cert == "" || key == "" || ca == "" {
			return nil, nil, nil
		}

		sec = &models.SecurityConfig{
			Mode: "mtls",
			TLS: models.TLSConfig{
				CertFile: cert,
				KeyFile:  key,
				CAFile:   ca,
			},
			ServerName: strings.TrimSpace(os.Getenv("KV_SERVER_NAME")),
			Role:       role,
		}
	case "spiffe":
		trustDomain := strings.TrimSpace(os.Getenv("KV_TRUST_DOMAIN"))
		serverID := strings.TrimSpace(os.Getenv("KV_SERVER_SPIFFE_ID"))
		workloadSocket := strings.TrimSpace(os.Getenv("KV_WORKLOAD_SOCKET"))
		if workloadSocket == "" {
			workloadSocket = "unix:/run/spire/sockets/agent.sock"
		}

		sec = &models.SecurityConfig{
			Mode:           "spiffe",
			CertDir:        strings.TrimSpace(os.Getenv("KV_CERT_DIR")),
			Role:           role,
			TrustDomain:    trustDomain,
			ServerSPIFFEID: serverID,
			WorkloadSocket: workloadSocket,
		}
	default:
		return nil, nil, nil
	}

	provider, err := coregrpc.NewSecurityProvider(ctx, sec, logger.NewTestLogger())
	if err != nil {
		return nil, nil, err
	}

	client, err := coregrpc.NewClient(ctx, coregrpc.ClientConfig{
		Address:          addr,
		SecurityProvider: provider,
		DisableTelemetry: true,
	})
	if err != nil {
		_ = provider.Close()
		return nil, nil, err
	}

	kvClient := proto.NewKVServiceClient(client.GetConnection())
	closer := func() error {
		return client.Close()
	}
	return kvClient, closer, nil
}

// ShouldUseKVFromEnv reports whether the current environment is configured for KV-backed configuration.
func ShouldUseKVFromEnv() bool {
	if strings.ToLower(strings.TrimSpace(os.Getenv("CONFIG_SOURCE"))) != "kv" {
		return false
	}
	if strings.TrimSpace(os.Getenv("KV_ADDRESS")) == "" {
		return false
	}

	mode := strings.ToLower(strings.TrimSpace(os.Getenv("KV_SEC_MODE")))
	switch mode {
	case "mtls":
		return allEnvSet("KV_CERT_FILE", "KV_KEY_FILE", "KV_CA_FILE")
	case "spiffe":
		return allEnvSet("KV_TRUST_DOMAIN", "KV_SERVER_SPIFFE_ID")
	default:
		return false
	}
}

func durationFromEnv(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	val, err := time.ParseDuration(raw)
	if err != nil || val <= 0 {
		return fallback
	}
	return val
}

func allEnvSet(keys ...string) bool {
	for _, key := range keys {
		if strings.TrimSpace(os.Getenv(key)) == "" {
			return false
		}
	}
	return true
}
