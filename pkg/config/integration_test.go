//go:build integration
// +build integration

package config_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type TestConfig struct {
	LogLevel string `json:"log_level,omitempty"`
	Port     int    `json:"port,omitempty"`
}

func TestKVSeedingAndPrecedence(t *testing.T) {
	// Ensure we are running in an environment with NATS configured
	if !config.ShouldUseKVFromEnv() {
		t.Skip("Skipping integration test: KV environment not configured")
	}

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Unique service name for this test run to avoid collisions
	serviceName := "integration-test-service-" + time.Now().Format("20060102-150405")
	kvKey := "config/" + serviceName + ".json"

	// Helper to clean up KV
	cleanupKV := func() {
		mgr, err := config.NewKVManagerFromEnv(ctx, models.RoleAgent)
		if err == nil && mgr != nil {
			// Note: KVManager doesn't expose Delete directly, but we can overwrite with empty or ignore
			// For a real cleanup, we might need to extend KVManager or use the raw client if accessible.
			// For now, unique service names mitigate collision.
			_ = mgr.Close()
		}
	}
	defer cleanupKV()

	t.Run("Seeding: Empty KV -> Default FS -> KV Populated", func(t *testing.T) {
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, serviceName+".json")

		// Create default config file
		defaultCfg := TestConfig{LogLevel: "info", Port: 8080}
		writeConfig(t, configPath, defaultCfg)

		// Initialize service bootstrap
		opts := bootstrap.ServiceOptions{
			Role:       models.RoleAgent,
			ConfigPath: configPath,
			Logger:     log,
			InstanceID: "test-instance-1",
		}

		desc := config.ServiceDescriptor{
			Name:  serviceName,
			KVKey: kvKey,
		}

		var cfg TestConfig
		res, err := bootstrap.Service(ctx, desc, &cfg, opts)
		require.NoError(t, err)
		defer res.Close()

		// Verify loaded config matches default
		assert.Equal(t, "info", cfg.LogLevel)
		assert.Equal(t, 8080, cfg.Port)

		// Verify KV is seeded
		// We need to read back from KV to confirm.
		mgr := res.Manager()
		require.NotNil(t, mgr)

		// Use a separate manager to verify to ensure we are reading from KV
		// and not just checking the in-memory config we just loaded.
		// Since we can't easily get the client, we'll use NewKVManagerFromEnv again.
		mgr2, err := config.NewKVManagerFromEnv(ctx, models.RoleAgent)
		require.NoError(t, err)
		defer mgr2.Close()

		var kvCfg TestConfig
		// OverlayConfig fetches from KV and applies to the struct
		err = mgr2.OverlayConfig(ctx, kvKey, &kvCfg)
		require.NoError(t, err)

		assert.Equal(t, "info", kvCfg.LogLevel)
		assert.Equal(t, 8080, kvCfg.Port)
	})

	t.Run("Precedence: KV > Default FS", func(t *testing.T) {
		// 1. Seed KV with specific value
		mgr, err := config.NewKVManagerFromEnv(ctx, models.RoleAgent)
		require.NoError(t, err)
		defer mgr.Close()

		kvCfg := TestConfig{LogLevel: "debug", Port: 9090}
		data, err := json.Marshal(kvCfg)
		require.NoError(t, err)
		err = mgr.Put(ctx, kvKey, data, 0)
		require.NoError(t, err)

		// 2. Start service with different default
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, serviceName+".json")
		defaultCfg := TestConfig{LogLevel: "info", Port: 8080}
		writeConfig(t, configPath, defaultCfg)

		opts := bootstrap.ServiceOptions{
			Role:       models.RoleAgent,
			ConfigPath: configPath,
			Logger:     log,
		}
		desc := config.ServiceDescriptor{Name: serviceName, KVKey: kvKey}
		var cfg TestConfig
		res, err := bootstrap.Service(ctx, desc, &cfg, opts)
		require.NoError(t, err)
		defer res.Close()

		// 3. Verify KV value wins
		assert.Equal(t, "debug", cfg.LogLevel)
		assert.Equal(t, 9090, cfg.Port)
	})

	t.Run("Precedence: Pinned > KV", func(t *testing.T) {
		// 1. Seed KV
		mgr, err := config.NewKVManagerFromEnv(ctx, models.RoleAgent)
		require.NoError(t, err)
		defer mgr.Close()

		kvCfg := TestConfig{LogLevel: "debug", Port: 9090}
		data, err := json.Marshal(kvCfg)
		require.NoError(t, err)
		err = mgr.Put(ctx, kvKey, data, 0)
		require.NoError(t, err)

		// 2. Pinned config
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, serviceName+".json")
		pinnedPath := filepath.Join(tmpDir, "pinned.json")

		defaultCfg := TestConfig{LogLevel: "info", Port: 8080}
		writeConfig(t, configPath, defaultCfg)

		pinnedCfg := TestConfig{LogLevel: "warn"} // Port missing, should fall back to KV/Default
		writeConfig(t, pinnedPath, pinnedCfg)

		// Set env var for pinned path
		os.Setenv("PINNED_CONFIG_PATH", pinnedPath)
		defer os.Unsetenv("PINNED_CONFIG_PATH")

		opts := bootstrap.ServiceOptions{
			Role:       models.RoleAgent,
			ConfigPath: configPath,
			Logger:     log,
		}
		desc := config.ServiceDescriptor{Name: serviceName, KVKey: kvKey}
		var cfg TestConfig
		res, err := bootstrap.Service(ctx, desc, &cfg, opts)
		require.NoError(t, err)
		defer res.Close()

		// 3. Verify Pinned wins for LogLevel, KV wins for Port
		assert.Equal(t, "warn", cfg.LogLevel)
		assert.Equal(t, 9090, cfg.Port)
	})
}

func writeConfig(t *testing.T, path string, cfg interface{}) {
	data, err := json.Marshal(cfg)
	require.NoError(t, err)
	err = os.WriteFile(path, data, 0644)
	require.NoError(t, err)
}
