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
	"context"
	"encoding/json"
	"log"
	"os"

	"github.com/carverauto/serviceradar/pkg/config/kvgrpc"
	coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// KVManager handles KV store operations for configuration management
type KVManager struct {
	client *kvgrpc.Client
}

// NewKVManagerFromEnv creates a KV manager from environment variables
func NewKVManagerFromEnv(ctx context.Context, role models.ServiceRole) *KVManager {
	if os.Getenv("CONFIG_SOURCE") != "kv" || os.Getenv("KV_ADDRESS") == "" {
		return nil
	}

	client := createKVClientFromEnv(ctx, role)
	if client == nil {
		return nil
	}

	return &KVManager{client: client}
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

	// Overlay KV on top of file-loaded config if KV configured
	if os.Getenv("KV_ADDRESS") != "" {
		_ = cfgLoader.OverlayFromKV(ctx, configPath, cfg)
	}

	return nil
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

// BootstrapConfig stores default config in KV if it doesn't exist
func (m *KVManager) BootstrapConfig(ctx context.Context, kvKey string, cfg interface{}) {
	if m == nil || m.client == nil {
		return
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		return
	}

	if _, found, _ := m.client.Get(ctx, kvKey); !found {
		_ = m.client.Put(ctx, kvKey, data, 0)
	}
}

// StartWatch sets up KV watching with hot-reload functionality
func (m *KVManager) StartWatch(ctx context.Context, kvKey string, cfg interface{}, logger logger.Logger, onReload func()) {
	if m == nil || m.client == nil {
		return
	}

	prev := cfg
	StartKVWatchOverlay(ctx, m.client, kvKey, cfg, logger, func() {
		triggers := map[string]bool{"reload": true, "rebuild": true}
		changed := FieldsChangedByTag(prev, cfg, "hot", triggers)
		if len(changed) > 0 {
			logger.Info().Strs("changed_fields", changed).Msg("Applying hot-reload")
			if onReload != nil {
				onReload()
			}
			prev = cfg
		}
	})
}

// Close closes the KV client connection
func (m *KVManager) Close() error {
	if m != nil && m.client != nil {
		return m.client.Close()
	}
	return nil
}

// createKVClientFromEnv creates a KV client from environment variables
func createKVClientFromEnv(ctx context.Context, role models.ServiceRole) *kvgrpc.Client {
	addr := os.Getenv("KV_ADDRESS")
	if addr == "" {
		return nil
	}

	secMode := os.Getenv("KV_SEC_MODE")
	cert := os.Getenv("KV_CERT_FILE")
	key := os.Getenv("KV_KEY_FILE")
	ca := os.Getenv("KV_CA_FILE")
	serverName := os.Getenv("KV_SERVER_NAME")

	if secMode != "mtls" || cert == "" || key == "" || ca == "" {
		return nil
	}

	sec := &models.SecurityConfig{
		Mode: "mtls",
		TLS: models.TLSConfig{
			CertFile: cert,
			KeyFile:  key,
			CAFile:   ca,
		},
		ServerName: serverName,
		Role:       role,
	}

	provider, err := coregrpc.NewSecurityProvider(ctx, sec, nil)
	if err != nil {
		return nil
	}

	client, err := coregrpc.NewClient(ctx, coregrpc.ClientConfig{
		Address:          addr,
		SecurityProvider: provider,
	})
	if err != nil {
		_ = provider.Close()
		return nil
	}

	kvClient := proto.NewKVServiceClient(client.GetConnection())
	return kvgrpc.New(kvClient, func() error {
		_ = provider.Close()
		return client.Close()
	})
}