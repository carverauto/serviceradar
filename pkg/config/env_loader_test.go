package config

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/require"
)

type envLoaderNested struct {
	Value string `json:"value,omitempty"`
}

type envLoaderConfig struct {
	Name   string            `json:"name,omitempty"`
	Nested *envLoaderNested  `json:"nested,omitempty"`
	Labels map[string]string `json:"labels,omitempty"`
}

func TestEnvLoaderDoesNotAllocatePointerWithoutEnv(t *testing.T) {
	t.Setenv("TEST_NAME", "")

	loader := NewEnvConfigLoader(logger.NewTestLogger(), "TEST_")
	cfg := envLoaderConfig{
		Name:   "default",
		Nested: nil,
	}

	require.NoError(t, loader.Load(context.Background(), "", &cfg))
	require.Nil(t, cfg.Nested, "nested pointer should remain nil when no env vars are provided")
	require.Equal(t, "default", cfg.Name, "existing values should remain untouched without env overrides")
}

func TestEnvLoaderOverlaysNestedPointerValues(t *testing.T) {
	t.Setenv("TEST_NESTED_VALUE", "from-env")

	loader := NewEnvConfigLoader(logger.NewTestLogger(), "TEST_")
	cfg := envLoaderConfig{
		Name:   "file",
		Nested: &envLoaderNested{Value: "file"},
	}

	require.NoError(t, loader.Load(context.Background(), "", &cfg))
	require.NotNil(t, cfg.Nested, "nested pointer should be initialized when env overrides exist")
	require.Equal(t, "from-env", cfg.Nested.Value, "env overrides should update nested pointer values")
	require.Equal(t, "file", cfg.Name, "fields without env overrides should remain unchanged")
}

func TestEnvLoaderOverlaysMapField(t *testing.T) {
	t.Setenv("TEST_LABELS", `{"region":"iad","tier":"edge"}`)

	loader := NewEnvConfigLoader(logger.NewTestLogger(), "TEST_")
	cfg := envLoaderConfig{}

	require.NoError(t, loader.Load(context.Background(), "", &cfg))
	require.Equal(t, map[string]string{"region": "iad", "tier": "edge"}, cfg.Labels)
}
