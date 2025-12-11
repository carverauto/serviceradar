package core

import (
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
)

func TestNormalizeConfigSetsSRQLDefaults(t *testing.T) {
	cfg := &models.CoreServiceConfig{}

	normalized := normalizeConfig(cfg)

	require.NotNil(t, normalized.SRQL)
	require.True(t, normalized.SRQL.Enabled)
	require.Equal(t, defaultSRQLBaseURL, normalized.SRQL.BaseURL)
	require.Equal(t, defaultSRQLPath, normalized.SRQL.Path)
	require.Equal(t, models.Duration(defaultSRQLTimeout), normalized.SRQL.Timeout)
}
