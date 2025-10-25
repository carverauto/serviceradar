package config

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/require"
)

type overlayConfig struct {
	Value string `json:"value"`
}

func TestLoadAndValidateAppliesEnvOverlay(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	require.NoError(t, os.WriteFile(path, []byte(`{"value":"file"}`), 0o600))

	t.Setenv("CONFIG_SOURCE", "")
	t.Setenv("CONFIG_ENV_PREFIX", "TEST_")
	t.Setenv("TEST_VALUE", "env")

	cfg := overlayConfig{}
	loader := NewConfig(logger.NewTestLogger())

	require.NoError(t, loader.LoadAndValidate(context.Background(), path, &cfg))
	require.Equal(t, "env", cfg.Value, "environment overlay should win over file values")
}
